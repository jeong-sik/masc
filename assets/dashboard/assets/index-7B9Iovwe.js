var Ur=Object.defineProperty;var Br=(t,e,n)=>e in t?Ur(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var xe=(t,e,n)=>Br(t,typeof e!="symbol"?e+"":e,n);import{e as Wr,_ as Gr,c as f,b as Ct,y as rt,d as Ha,A as xo,G as Jr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))a(i);new MutationObserver(i=>{for(const o of i)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(i){const o={};return i.integrity&&(o.integrity=i.integrity),i.referrerPolicy&&(o.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?o.credentials="include":i.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(i){if(i.ep)return;i.ep=!0;const o=n(i);fetch(i.href,o)}})();var s=Wr.bind(Gr);const Vr=["command","overview","board","goals","agents","ops","trpg"],So={tab:"overview",params:{},postId:null},Qr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Di(t){return!!t&&Vr.includes(t)}function Ei(t){if(t)return Qr[t]??t}function Qn(t){try{return decodeURIComponent(t)}catch{return t}}function Ts(t){const e={};return t&&new URLSearchParams(t).forEach((a,i)=>{e[i]=a}),e}function Yr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ao(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=Qn(t[2])),{tab:"command",params:r,postId:null}}const n=Ei(t[0]),a=Ei(e.tab),i=Di(n)?n:Di(a)?a:"overview";let o=null;return i==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=Qn(t[2]):t[0]==="post"&&t[1]&&(o=Qn(t[1]))),{tab:i,params:e,postId:o}}function la(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return So;const n=Qn(e);let a=n,i;if(n.startsWith("?"))a="",i=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),i=n.slice(l+1))}!i&&a.includes("=")&&!a.includes("/")&&(i=a,a="");const o=Ts(i),r=Yr(a);return Ao(r,o)}function Xr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...So,params:Ts(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const i=Ts(e.replace(/^\?/,""));return Ao(a,i)}function Co(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([i])=>i!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const nt=f(la(window.location.hash));window.addEventListener("hashchange",()=>{nt.value=la(window.location.hash)});function Rt(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=Co(n)}function Zr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function tl(){if(window.location.hash&&window.location.hash!=="#"){nt.value=la(window.location.hash);return}const t=Xr(window.location.pathname,window.location.search);if(t){nt.value=t;const e=Co(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",nt.value=la(window.location.hash)}const Ii="masc_dashboard_sse_session_id",el=1e3,nl=15e3,Ft=f(!1),In=f(0),wo=f(null),ca=f([]);function al(){let t=sessionStorage.getItem(Ii);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ii,t)),t}const sl=200;function il(t,e,n="system",a={}){const i={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ca.value=[i,...ca.value].slice(0,sl)}function Ns(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Mi(t,e){const n=Ns(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function wt(t,e,n,a,i={}){il(t,e,n,{eventType:a,...i})}let Ot=null,Ee=null,Rs=0;function To(){Ee&&(clearTimeout(Ee),Ee=null)}function ol(){if(Ee)return;Rs++;const t=Math.min(Rs,5),e=Math.min(nl,el*Math.pow(2,t));Ee=setTimeout(()=>{Ee=null,No()},e)}function No(){To(),Ot&&(Ot.close(),Ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",al());const i=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(i);Ot=o,o.onopen=()=>{Ot===o&&(Rs=0,Ft.value=!0)},o.onerror=()=>{Ot===o&&(Ft.value=!1,o.close(),Ot=null,ol())},o.onmessage=r=>{try{const l=JSON.parse(r.data);In.value++,wo.value=l,rl(l)}catch{}}}function rl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":wt(n,"Joined","system","agent_joined");break;case"agent_left":wt(n,"Left","system","agent_left");break;case"broadcast":wt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":wt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":wt(n,Mi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":wt(n,Mi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":wt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":wt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":wt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":wt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:wt(n,e,"system","unknown")}}function ll(){To(),Ot&&(Ot.close(),Ot=null),Ft.value=!1}function Ro(){return new URLSearchParams(window.location.search)}function Lo(){const t=Ro(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Po(){return{...Lo(),"Content-Type":"application/json"}}const cl=15e3,vi=3e4,dl=6e4,Oi=new Set([408,425,429,500,502,503,504]);class Mn extends Error{constructor(n){const a=n.method.toUpperCase(),i=n.timeout===!0,o=i?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);xe(this,"method");xe(this,"path");xe(this,"status");xe(this,"statusText");xe(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=i}}async function fi(t,e,n){const a=new AbortController,i=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Mn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(i)}}function ul(){var e,n;const t=Ro();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function et(t){const e=await fi(t,{headers:Lo()},cl);if(!e.ok)throw new Mn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function pl(t){return new Promise(e=>setTimeout(e,t))}function ml(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function vl(t){if(t instanceof Mn)return t.timeout||typeof t.status=="number"&&Oi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ml(t.message);return e!==null&&Oi.has(e)}async function Ue(t,e,n=2){let a=0;for(;;)try{return await e()}catch(i){if(!vl(i)||a>=n)throw i;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,i),await pl(o),a+=1}}async function Kt(t,e,n,a=vi){const i=await fi(t,{method:"POST",headers:{...Po(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.json()}async function fl(t,e,n,a=vi){const i=await fi(t,{method:"POST",headers:{...Po(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Mn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.text()}function gl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function _l(t){var e,n,a,i,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((i=(a=t.result.content)==null?void 0:a[0])==null?void 0:i.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function bt(t,e){const n=await fl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},dl),a=gl(n);return _l(a)}function $l(t="compact"){return et(`/api/v1/dashboard?mode=${t}`)}function hl(){return et("/api/v1/agents?limit=100")}function yl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),et(`/api/v1/tasks?${e}`)}function bl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),et(`/api/v1/messages?${e}`)}function kl(t={}){return Ue("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return et(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function xl(){return et("/api/v1/operator")}function Sl(){return et("/api/v1/command-plane")}function Al(){return et("/api/v1/command-plane/summary")}function Cl(){return et("/api/v1/chains/summary")}function wl(t){return et(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Tl(){return et("/api/v1/command-plane/help")}function Nl(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return et(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function Rl(t,e){return Kt(t,e)}function Ll(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return vi}}function On(t){return Kt("/api/v1/operator/action",t,void 0,Ll(t))}function Pl(t,e){return Kt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Dl=new Set(["lodge-system","team-session"]);function ze(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function El(t){return Dl.has(t.trim().toLowerCase())}function Il(t){return t.filter(e=>!El(e.author))}function Ml(t){var i;const e=t.trim(),a=((i=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:i.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Do(t){if(!O(t))return null;const e=$(t.id,"").trim(),n=$(t.author,"").trim(),a=$(t.content,"").trim();if(!e||!n)return null;const i=q(t.score,0),o=q(t.votes_up,0),r=q(t.votes_down,0),l=q(t.votes,i||o-r),p=q(t.comment_count,q(t.reply_count,0)),_=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const T=$(y.name,"").trim();if(T)return T}return $(t.flair_name,"").trim()||void 0})(),m=$(t.created_at_iso,"").trim()||ze(t.created_at),d=$(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ze(t.updated_at):m),g=$(t.title,"").trim()||Ml(a);return{id:e,author:n,title:g,content:a,tags:[],votes:l,vote_balance:i,comment_count:p,created_at:m,updated_at:d,flair:_,hearth_count:q(t.hearth_count,0)}}function Ol(t){if(!O(t))return null;const e=$(t.id,"").trim(),n=$(t.post_id,"").trim(),a=$(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:$(t.content,""),created_at:ze(t.created_at)}}async function zl(t,e){return Ue("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),i=await et(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(i.posts)?i.posts.map(Do).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Il(o):o}})}async function ql(t){return Ue("fetchBoardPost",async()=>{const e=await et(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Do(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Ol).filter(r=>r!==null);return{...a,comments:o}})}function Eo(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:ul()})}function jl(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Fl(t){const e=$(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function lt(...t){for(const e of t){const n=$(e,"");if(n.trim())return n.trim()}return""}function zi(t){const e=Fl(lt(t.outcome,t.result,t.result_code));if(!e)return;const n=lt(t.reason,t.reason_code,t.description,t.detail),a=lt(t.summary,t.summary_ko,t.summary_en,t.note),i=lt(t.details,t.details_text,t.text,t.note),o=lt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=lt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=lt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(c=>{if(typeof c=="string")return c.trim();if(O(c)){const g=$(c.summary,"").trim();if(g)return g;const y=$(c.text,"").trim();if(y)return y;const S=$(c.type,"").trim();return S||$(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),_=(()=>{const d=q(t.turn,Number.NaN);if(Number.isFinite(d))return d;const c=q(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const g=q(t.current_turn,Number.NaN);if(Number.isFinite(g))return g;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=lt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:i||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:_,phase:m||void 0}}function Kl(t,e){const n=O(t.state)?t.state:{};if($(n.status,"active").toLowerCase()!=="ended")return;const i=[...e].reverse().find(r=>O(r)?$(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=zi(o);if(r)return r}if(O(i))return zi(O(i.payload)?i.payload:{})}function O(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Hl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ls(t,e=!1){return typeof t=="boolean"?t:e}function Qe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=$(e.name,"").trim(),a=$(e.id,"").trim(),i=$(e.skill,"").trim();return n||a||i}return""}).filter(e=>e.length>0):[]}function Ul(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const i=n.trim(),o=$(a,"").trim();!i||!o||(e[i]=o)}),e;for(const n of t){if(!O(n))continue;const a=lt(n.to,n.target,n.actor_id,n.name,n.id),i=lt(n.relationship,n.relation,n.type,n.kind);!a||!i||(e[a]=i)}return e}function Bl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function xt(t,e,n,a=0){const i=t[e];if(typeof i=="number"&&Number.isFinite(i))return i;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Wl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Gl(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,i])=>{const o=a.trim();o&&(Wl.has(o.toLowerCase())||typeof i=="number"&&Number.isFinite(i)&&(n[o]=i))}),n}function Jl(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),i=q(e.bonus,0),o=$(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:i}}function Vl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Ql(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Yl(t,e,n,a){const i=n||e||$(a.actor_id,"")||$(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=$(a.proposed_action,$(a.reply,""));return o?`${i||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=$(a.reply,$(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return $(a.reply,$(a.content,$(a.text,"Narration")));case"dice.rolled":{const o=$(a.action,"roll"),r=q(a.total,0),l=q(a.dc,0),p=$(a.label,""),_=i||"actor",m=l>0?` vs DC ${l}`:"",d=p?` (${p})`:"";return`${_} ${o}: ${r}${m}${d}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${$(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(a.name,O(a.actor)?$(a.actor.name,i||"unknown"):i||"unknown")}`;case"actor.claimed":return`${$(a.keeper_name,$(a.keeper,"keeper"))} claimed ${i||"actor"}`;case"actor.released":return`${$(a.keeper_name,$(a.keeper,"keeper"))} released ${i||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${i||$(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${i||$(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=$(o.requested_tier,""),l=$(o.effective_tier,""),p=Ls(o.guardrail_applied,!1),_=$(a.summary_en,$(a.summary_ko,"Memory signal"));if(!r&&!l)return _;const m=r&&l?`${r}->${l}`:l||r;return`${_} [${m}${p?" (guardrail)":""}]`}case"world.event":{if($(a.event_type,"")==="canon.check"){const r=$(a.status,"unknown"),l=$(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return $(a.description,$(a.summary,"World event"))}case"combat.attack":return $(a.summary,$(a.result,"Attack resolved"));case"combat.defense":return $(a.summary,$(a.result,"Defense resolved"));case"session.outcome":return $(a.summary,$(a.outcome,"Session ended"));default:{const o=Vl(a);return o?`${t}: ${o}`:t}}}function Xl(t,e){const n=O(t)?t:{},a=$(n.type,"event"),i=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=$(n.actor_name,"").trim()||e[i]||$(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=$(n.ts,$(n.timestamp,new Date().toISOString())),p=$(n.phase,$(r.phase,"")),_=$(n.category,"");return{type:a,actor:o||i||$(r.actor_name,""),actor_id:i||$(r.actor_id,""),actor_name:o,seq:n.seq,room_id:$(n.room_id,""),phase:p||void 0,category:_||Ql(a),visibility:$(n.visibility,$(r.visibility,"public")),event_id:$(n.event_id,""),content:Yl(a,i,o,r),dice_roll:Jl(a,r),timestamp:l}}function Zl(t,e,n){var mt,vt;const a=$(t.room_id,"")||n||"default",i=O(t.state)?t.state:{},o=O(i.party)?i.party:{},r=O(i.actor_control)?i.actor_control:{},l=O(i.join_gate)?i.join_gate:{},p=O(i.contribution_ledger)?i.contribution_ledger:{},_=Object.entries(o).map(([B,M])=>{const k=O(M)?M:{},Dt=xt(k,"max_hp",void 0,10),Vt=xt(k,"hp",void 0,Dt),oe=xt(k,"max_mp",void 0,0),re=xt(k,"mp",void 0,0),E=xt(k,"level",void 0,1),Et=xt(k,"xp",void 0,0),le=Ls(k.alive,Vt>0),Je=r[B],Ve=typeof Je=="string"?Je:void 0,v=Bl(k.role,B,Ve),L=Hl(k.generation),j=lt(k.joined_at,k.joinedAt,k.started_at,k.startedAt),at=lt(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),z=lt(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),ft=lt(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),Q=lt(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:B,name:$(k.name,B),role:v,keeper:Ve,archetype:$(k.archetype,""),persona:$(k.persona,""),portrait:$(k.portrait,"")||void 0,background:$(k.background,"")||void 0,traits:Qe(k.traits),skills:Qe(k.skills),stats_raw:Gl(k),status:le?"active":"dead",generation:L,joined_at:j||void 0,claimed_at:at||void 0,last_seen:z||void 0,scene:ft||void 0,location:Q||void 0,inventory:Qe(k.inventory),notes:Qe(k.notes),relationships:Ul(k.relationships),stats:{hp:Vt,max_hp:Dt,mp:re,max_mp:oe,level:E,xp:Et,strength:xt(k,"strength","str",10),dexterity:xt(k,"dexterity","dex",10),constitution:xt(k,"constitution","con",10),intelligence:xt(k,"intelligence","int",10),wisdom:xt(k,"wisdom","wis",10),charisma:xt(k,"charisma","cha",10)}}}),m=_.filter(B=>B.status!=="dead"),d=Kl(t,e),c={phase_open:Ls(l.phase_open,!0),min_points:q(l.min_points,3),window:$(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},g=Object.entries(p).map(([B,M])=>{const k=O(M)?M:{};return{actor_id:B,score:q(k.score,0),last_reason:$(k.last_reason,"")||null,reasons:Qe(k.reasons)}}),y=_.reduce((B,M)=>(B[M.id]=M.name,B),{}),S=e.map(B=>Xl(B,y)),T=q(i.turn,1),P=$(i.phase,"round"),K=$(i.map,""),I=O(i.world)?i.world:{},N=K||$(I.ascii_map,$(I.map,"")),R=S.filter((B,M)=>{const k=e[M];if(!O(k))return!1;const Dt=O(k.payload)?k.payload:{};return q(Dt.turn,-1)===T}),X=(R.length>0?R:S).slice(-12),H=$(i.status,"active");return{session:{id:a,room:a,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:T,actors:m,created_at:((mt=S[0])==null?void 0:mt.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:P,events:X,timestamp:((vt=S[S.length-1])==null?void 0:vt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:c,contribution_ledger:g,outcome:d,party:m,story_log:S,history:[]}}async function tc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await et(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function ec(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([et(`/api/v1/trpg/state${e}`),tc(t)]);return Zl(n,a,t)}function nc(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function ac(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function sc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function ic(t,e){const n=ac();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function oc(t,e){var i;const n=(i=e.idempotencyKey)==null?void 0:i.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Kt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function rc(t,e,n){return Kt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function lc(t,e,n){const a=await bt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function cc(t){const e=await bt("trpg.mid_join.request",t);return JSON.parse(e)}async function Io(t,e){await bt("masc_broadcast",{agent_name:t,message:e})}async function dc(t,e,n=1){await bt("masc_add_task",{title:t,description:e,priority:n})}async function uc(t){return bt("masc_join",{agent_name:t})}async function Mo(t){await bt("masc_leave",{agent_name:t})}async function pc(t){await bt("masc_heartbeat",{agent_name:t})}async function mc(t=40){return(await bt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function vc(t,e=20){return bt("masc_task_history",{task_id:t,limit:e})}async function fc(){return Ue("fetchDebates",async()=>{const t=await et("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:$(e.status,"open"),argument_count:q(e.argument_count,0),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function gc(){return Ue("fetchCouncilSessions",async()=>{const t=await et("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:$(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:$(e.state,"open"),created_at:ze(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function _c(t){const e=await bt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function $c(t){return Ue("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await et(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=$(n.id,"").trim();return a?{id:a,topic:$(n.topic,""),status:$(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:ze(n.created_at_iso??n.created_at),summary_text:$(n.summary_text,"")}:null})}function hc(t,e,n){return bt("masc_keeper_msg",{name:t,message:e})}async function yc(){try{const t=await bt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const sn=f(""),Bt=f({}),dt=f({}),Ps=f({}),Ds=f({}),Es=f({}),Is=f({}),Wt=f({});function ot(t,e,n){t.value={...t.value,[e]:n}}function Gt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Nt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Re(t){return typeof t=="boolean"?t:void 0}function Ms(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Os(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function bc(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function kc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ya(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Gt(a))continue;const i=U(a.name);if(!i)continue;const o=U(a[e]);e==="summary"?n.push({name:i,summary:o}):n.push({name:i,reason:o})}return n}function xc(t){if(!Gt(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function Sc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Ac(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Oo(t,e,n){return U(t)??Ac(e,n)}function zo(t,e){return typeof t=="boolean"?t:e==="recover"}function da(t){if(!Gt(t))return null;const e=U(t.health_state),n=U(t.next_action_path),a=U(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Ms(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:Nt(t.next_eligible_at_s)??null,recoverable:zo(t.recoverable,n),summary:Oo(t.summary,e,U(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function gi(t){return Gt(t)?{hour:Nt(t.hour),checked:Nt(t.checked)??0,acted:Nt(t.acted)??0,acted_names:Os(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:Re(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:Ya(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Ya(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Ya(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(xc).filter(e=>e!==null):[]}:null}function Cc(t){return Gt(t)?{enabled:Re(t.enabled)??!1,interval_s:Nt(t.interval_s)??0,quiet_start:Nt(t.quiet_start),quiet_end:Nt(t.quiet_end),quiet_active:Re(t.quiet_active),use_planner:Re(t.use_planner),delegate_llm:Re(t.delegate_llm),agent_count:Nt(t.agent_count),agents:Os(t.agents),last_tick_ago_s:Nt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:Nt(t.total_ticks),total_checkins:Nt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:gi(t.last_tick_result),active_self_heartbeats:Os(t.active_self_heartbeats)}:null}function wc(t){return Gt(t)?{status:t.status,diagnostic:da(t.diagnostic)}:null}function Tc(t){return Gt(t)?{recovered:Re(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:da(t.before),after:da(t.after),down:t.down,up:t.up}:null}function Nc(t,e){var K,I;if(!(t!=null&&t.name))return null;const n=U((K=t.agent)==null?void 0:K.status)??U(t.status)??"unknown",a=U((I=t.agent)==null?void 0:I.error)??null,i=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,d=p&&m!=null?Math.max(0,_-m):null,c=r<=0||l==null?"never":l>900?"stale":"fresh",g=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(i&&!o?"keeper keepalive is not running":null),S=n==="offline"||n==="inactive"?"offline":y?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",T=y?Sc(y):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":i&&!o?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",P=S==="offline"||S==="degraded"||S==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:S,quiet_reason:T,next_action_path:P,last_reply_status:c,last_reply_at:g,last_reply_preview:null,last_error:y,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:zo(void 0,P),summary:Oo(void 0,S,T),keepalive_running:o}}function Rc(t,e){if(!Gt(t))return null;const n=bc(t.role),a=U(t.content)??U(t.preview);if(!a)return null;const i=Ms(t.ts_unix)??Ms(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:kc(n),text:a,timestamp:i,delivery:"history"}}function Lc(t,e,n){const a=Gt(n)?n:null,i=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>Rc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:da(a==null?void 0:a.diagnostic),history:i,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function qi(t,e){const n=dt.value[t]??[];dt.value={...dt.value,[t]:[...n,e].slice(-50)}}function Pc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Dc(t,e){const a=(dt.value[t]??[]).filter(i=>i.delivery!=="history"&&!e.some(o=>Pc(i,o)));dt.value={...dt.value,[t]:[...e,...a].slice(-50)}}function Ua(t,e){Bt.value={...Bt.value,[t]:e},Dc(t,e.history)}function ji(t,e){const n=Bt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ua(t,{...n,diagnostic:{...a,...e}})}async function _i(){qe();try{await ne()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Yn(t){sn.value=t.trim()}async function qo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Bt.value[n])return Bt.value[n];ot(Ps,n,!0),ot(Wt,n,null);try{const a=await bt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let i=null;try{i=JSON.parse(a)}catch{i=null}const o=Lc(n,a,i);return Ua(n,o),o}catch(a){const i=a instanceof Error?a.message:`Failed to inspect ${n}`;return ot(Wt,n,i),null}finally{ot(Ps,n,!1)}}async function Ec(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const i=`local-${Date.now()}`;qi(n,{id:i,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),ot(Ds,n,!0),ot(Wt,n,null);try{const o=await hc(n,a);dt.value={...dt.value,[n]:(dt.value[n]??[]).map(r=>r.id===i?{...r,delivery:"delivered"}:r)},qi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ji(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await _i()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw dt.value={...dt.value,[n]:(dt.value[n]??[]).map(l=>l.id===i?{...l,delivery:"error",error:r}:l)},ji(n,{last_reply_status:"error",last_error:r}),ot(Wt,n,r),o}finally{ot(Ds,n,!1)}}async function Ic(t,e){const n=t.trim();if(!n)return null;ot(Es,n,!0),ot(Wt,n,null);try{const a=await On({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),i=wc(a.result),o=(i==null?void 0:i.diagnostic)??null;if(o){const r=Bt.value[n];Ua(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await _i(),o}catch(a){const i=a instanceof Error?a.message:`Failed to probe ${n}`;throw ot(Wt,n,i),a}finally{ot(Es,n,!1)}}async function Mc(t,e){const n=t.trim();if(!n)return null;ot(Is,n,!0),ot(Wt,n,null);try{const a=await On({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),i=Tc(a.result),o=(i==null?void 0:i.after)??null;if(o){const r=Bt.value[n];Ua(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??dt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await _i(),o}catch(a){const i=a instanceof Error?a.message:`Failed to recover ${n}`;throw ot(Wt,n,i),a}finally{ot(Is,n,!1)}}function ce(t){return(t??"").trim().toLowerCase()}function gt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Xn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ye(t){return t.last_heartbeat??jn(t.last_turn_ago_s)??jn(t.last_proactive_ago_s)??jn(t.last_handoff_ago_s)??jn(t.last_compaction_ago_s)}function Oc(t){const e=t.title.trim();return e||Xn(t.content)}function zc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function qc(t,e,n,a,i={}){var I;const o=ce(t),r=e.filter(N=>ce(N.assignee)===o&&(N.status==="claimed"||N.status==="in_progress")).length,l=n.filter(N=>ce(N.from)===o).sort((N,R)=>gt(R.timestamp)-gt(N.timestamp))[0],p=a.filter(N=>ce(N.agent)===o||ce(N.author)===o).sort((N,R)=>gt(R.timestamp)-gt(N.timestamp))[0],_=(i.boardPosts??[]).filter(N=>ce(N.author)===o).sort((N,R)=>gt(R.updated_at||R.created_at)-gt(N.updated_at||N.created_at))[0],m=(i.keepers??[]).filter(N=>ce(N.name)===o&&Ye(N)!==null).sort((N,R)=>gt(Ye(R)??0)-gt(Ye(N)??0))[0],d=l?gt(l.timestamp):0,c=p?gt(p.timestamp):0,g=_?gt(_.updated_at||_.created_at):0,y=m?gt(Ye(m)??0):0,S=i.lastSeen?gt(i.lastSeen):0,T=((I=i.currentTask)==null?void 0:I.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&c===0&&g===0&&y===0&&S===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const K=[l?{timestamp:l.timestamp,ts:d,text:Xn(l.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:g,text:`Post: ${Xn(Oc(_))}`}:null,m?{timestamp:Ye(m),ts:y,text:zc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:c,text:Xn(p.text)}:null].filter(N=>N!==null).sort((N,R)=>R.ts-N.ts)[0];return K&&K.ts>=S?{activeAssignedCount:r,lastActivityAt:K.timestamp,lastActivityText:K.text}:{activeAssignedCount:r,lastActivityAt:i.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const At=f([]),yt=f([]),Sn=f([]),Jt=f([]),se=f(null),en=f(null),zs=f(new Map),Be=f([]),An=f("hot"),ue=f(!0),jo=f(null),Ut=f(""),Cn=f([]),Le=f(!1),Fo=f(new Map),qs=f("unknown"),js=f(null),Fs=f(!1),wn=f(!1),Ks=f(!1),Pe=f(!1),jc=f(null),Hs=f(null),Ko=f(null),Ho=f(null),Fc=Ct(()=>At.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Uo=Ct(()=>{const t=yt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ba=Ct(()=>{const t=new Map,e=yt.value,n=Sn.value,a=ca.value,i=Be.value,o=Jt.value;for(const r of At.value)t.set(r.name.trim().toLowerCase(),qc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:i,keepers:o}));return t});function Kc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const i=a.context_ratio;return i>.85?"handoff-imminent":i>.7?"preparing":i>.5?"compacting":"active"}const Bo=Ct(()=>{const t=new Map;for(const e of Jt.value)t.set(e.name,Kc(e));return t}),Hc=12e4;function Uc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const i=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof i=="number"?Date.now()-i*1e3:null}const Wo=Ct(()=>{const t=Date.now(),e=new Set,n=zs.value;for(const a of Jt.value){const i=Uc(a,n);i!=null&&t-i>Hc&&e.add(a.name)}return e}),ua={},Bc=5e3;let Xa=null;function Wc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function qe(){delete ua.compact,delete ua.full}function ut(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function _e(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Us(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Go(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Gc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Jo(t){if(!ut(t))return null;const e=b(t.name);return e?{name:e,status:Go(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:_e(t.traits),interests:_e(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Vo(t){if(!ut(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Gc(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Qo(t){if(!ut(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function Jc(t){return Array.isArray(t)?t.map(e=>{if(!ut(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=ut(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Fi(t){if(!ut(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const i=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":i==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":i==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":i==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:i,next_action_path:n,last_reply_status:a,last_reply_at:Us(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Vc(t,e){return(Array.isArray(t)?t:ut(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ut(a))return null;const i=ut(a.agent)?a.agent:null,o=ut(a.context)?a.context:null,r=ut(a.metrics_window)?a.metrics_window:void 0,l=b(a.name);if(!l)return null;const p=A(a.context_ratio)??A(o==null?void 0:o.context_ratio),_=b(a.status)??b(i==null?void 0:i.status)??"offline",m=Go(_),d=b(a.model)??b(a.active_model)??b(a.primary_model),c=_e(a.skill_secondary),g=o?{source:b(o.source),context_ratio:A(o.context_ratio),context_tokens:A(o.context_tokens),context_max:A(o.context_max),message_count:A(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=i?{name:b(i.name),exists:typeof i.exists=="boolean"?i.exists:void 0,error:b(i.error),status:b(i.status),current_task:b(i.current_task)??null,last_seen:b(i.last_seen),last_seen_ago_s:A(i.last_seen_ago_s),is_zombie:typeof i.is_zombie=="boolean"?i.is_zombie:void 0}:void 0,S=Jc(a.metrics_series),T={name:l,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:d,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(i==null?void 0:i.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:p,context_tokens:A(a.context_tokens)??A(o==null?void 0:o.context_tokens),context_max:A(a.context_max)??A(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:g,traits:_e(a.traits),interests:_e(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:Fi(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:c,skill_reason:b(a.skill_reason)??null,metrics_series:S.length>0?S:void 0,metrics_window:r,agent:y};return T.diagnostic=Fi(a.diagnostic)??Nc(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function Qc(t){return ut(t)?{...t,lodge:Cc(t.lodge)??void 0}:null}function Yc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Xc(t){if(!ut(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,i=ut(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:i?{worker_engine:(i.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(i.worker_model)??"",tool_call_count:A(i.tool_call_count)??0,tool_names:_e(i.tool_names)??[],session_id:b(i.session_id)??"",evidence_status:i.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Zc(t){var o,r;if(!ut(t))return null;const e=b(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Xc).filter(l=>l!==null):[],i=A(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Yc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:i,target:b(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:Us(t.updated_at)??null,stopped_at:Us(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:_e(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ne(t="full"){var a,i,o;const e=Date.now(),n=ua[t];if(!(n&&e-n.time<Bc)){Fs.value=!0;try{const r=await $l(t);ua[t]={data:r,time:e},At.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Jo).filter(p=>p!==null),yt.value=(Array.isArray((i=r.tasks)==null?void 0:i.tasks)?r.tasks.tasks:[]).map(Vo).filter(p=>p!==null),Sn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Qo).filter(p=>p!==null);const l=Qc(r.status);se.value=l,Jt.value=Vc(r.keepers,l),en.value=r.perpetual??null,jc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Fs.value=!1}}}async function td(){try{const t=await hl(),e=(Array.isArray(t.agents)?t.agents:[]).map(Jo).filter(i=>i!==null),n=At.value,a=new Map(n.map(i=>[i.name,i]));At.value=e.map(i=>{const o=a.get(i.name);return o?{...o,status:i.status,current_task:i.current_task}:i})}catch(t){console.error("Agents selective fetch error:",t)}}async function ed(){try{const t=await yl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Vo).filter(i=>i!==null),n=yt.value,a=new Map(n.map(i=>[i.id,i]));yt.value=e.map(i=>{const o=a.get(i.id);return o?{...o,status:i.status,priority:i.priority??o.priority,assignee:i.assignee??o.assignee}:i})}catch(t){console.error("Tasks selective fetch error:",t)}}async function nd(){try{const t=Sn.value,e=t.reduce((l,p)=>Math.max(l,p.seq??0),0),n=await bl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(Qo).filter(l=>l!==null);if(a.length===0)return;const i=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!i.has(l.seq);const p=`${l.timestamp}|${l.from}`;return o.has(p)?!1:(o.add(p),!0)});if(r.length>0){const l=[...t,...r];Sn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function qt(){wn.value=!0;try{const t=await zl(An.value,{excludeSystem:ue.value});Be.value=t.posts??[],Hs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{wn.value=!1}}async function jt(){var t;Ks.value=!0;try{const e=Ut.value||((t=se.value)==null?void 0:t.room)||"default";Ut.value||(Ut.value=e);const n=await ec(e);jo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ks.value=!1}}async function Tn(){Le.value=!0;try{const t=await yc();Cn.value=Array.isArray(t)?t:[],Ko.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Le.value=!1}}async function je(){Pe.value=!0;try{const t=await kl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const i=Zc(a);i&&n.set(i.loop_id,i)}Fo.value=n,Ho.value=new Date().toISOString(),js.value=null,qs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),qs.value="error",js.value=t instanceof Error?t.message:String(t)}finally{Pe.value=!1}}let Zn=null;function ad(t){Zn=t}let ta=null;function sd(t){ta=t}const pe={};function de(t,e,n=500){pe[t]&&clearTimeout(pe[t]),pe[t]=setTimeout(()=>{e(),delete pe[t]},n)}function id(){const t=wo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(zs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),zs.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&de("agents",td),Wc(e.type)&&(qe(),Xa||(Xa=setTimeout(()=>{ne(),ta==null||ta(),Xa=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&de("tasks",ed),e.type==="broadcast"&&de("messages",nd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&de("dashboard",()=>{qe(),ne()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&de("board",qt),e.type.startsWith("decision_")&&de("council",()=>Zn==null?void 0:Zn()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&de("mdal",je,350)}});return()=>{t();for(const e of Object.keys(pe))clearTimeout(pe[e]),delete pe[e]}}let on=null;function od(){on||(on=setInterval(()=>{Ft.value||qe(),ne()},1e4))}function rd(){on&&(clearInterval(on),on=null)}function w({title:t,class:e,children:n}){return s`
    <div class="card ${e??""}">
      ${t?s`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Lt({status:t,label:e}){return s`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ld(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const i=Math.floor(a/60);if(i<60)return`${i}m ago`;const o=Math.floor(i/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function F({timestamp:t}){const e=ld(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function Y(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function st(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function me(t){return(t??"").trim().toLowerCase()}function ct(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function zt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function $i(t){const e=zt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let cd=0;const ve=f([]);function C(t,e="success",n=4e3){const a=++cd;ve.value=[...ve.value,{id:a,message:t,type:e}],setTimeout(()=>{ve.value=ve.value.filter(i=>i.id!==a)},n)}function dd(t){ve.value=ve.value.filter(e=>e.id!==t)}function ud(){const t=ve.value;return t.length===0?null:s`
    <div class="toast-container">
      ${t.map(e=>s`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>dd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const pd="masc_dashboard_agent_name",We=f(null),pa=f(!1),Nn=f(""),ma=f([]),Rn=f([]),Ie=f(""),rn=f(!1);function Me(t){We.value=t,hi()}function Ki(){We.value=null,Nn.value="",ma.value=[],Rn.value=[],Ie.value=""}function md(){const t=We.value;return t?At.value.find(e=>e.name===t)??null:null}function Yo(t){return t?yt.value.filter(e=>e.assignee===t):[]}async function hi(){const t=We.value;if(t){pa.value=!0,Nn.value="",ma.value=[],Rn.value=[];try{const e=await mc(80);ma.value=e.filter(i=>i.includes(t)).slice(0,20);const n=Yo(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async i=>{try{const o=await vc(i.id,25);return{taskId:i.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:i.id,text:`Failed to load history: ${r}`}}}));Rn.value=a}catch(e){Nn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{pa.value=!1}}}async function Hi(){var a;const t=We.value,e=Ie.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(pd))==null?void 0:a.trim())||"dashboard";rn.value=!0;try{await Io(n,`@${t} ${e}`),Ie.value="",C(`Mention sent to ${t}`,"success"),hi()}catch(i){const o=i instanceof Error?i.message:"Failed to send mention";C(o,"error")}finally{rn.value=!1}}function vd({task:t}){return s`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Lt} status=${t.status} />
    </div>
  `}function fd({row:t}){return s`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function gd(){var i,o,r,l;const t=We.value;if(!t)return null;const e=md(),n=Yo(t),a=ma.value;return s`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&Ki()}}
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
            <button class="control-btn ghost" onClick=${()=>{hi()}} disabled=${pa.value}>
              ${pa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ki}>Close</button>
          </div>
        </div>

        ${Nn.value?s`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(p=>s`<${vd} key=${p.id} task=${p} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((p,_)=>s`<div key=${_} class="agent-activity-line">${p}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${Rn.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${Rn.value.map(p=>s`<${fd} key=${p.taskId} row=${p} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ie.value}
              onInput=${p=>{Ie.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&Hi()}}
              disabled=${rn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Hi()}}
              disabled=${rn.value||Ie.value.trim()===""}
            >
              ${rn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const va=600*1e3,ea=1200*1e3;function Xo(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Zo(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function _d(t){return t.updated_at??t.created_at??null}function Ui(t,e,n){var T,P;const a=me(t.assignee),i=a?e.get(a)??null:null,o=i?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(i==null?void 0:i.last_seen)??null,l=r?Math.max(0,Date.now()-Y(r)):Number.POSITIVE_INFINITY,p=ct(t.description),_=ct(i==null?void 0:i.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let d="ok",c="Fresh owner coverage",g=_??p??t.id,y=!1,S=!1;return t.status==="todo"?t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",c="Assigned owner is offline",g="Queue item is blocked until ownership changes."):l>va?(d="warn",c="Owner exists but live signal is quiet",g=_??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=i.current_task)!=null&&T.trim()?(d="warn",c="Owner is already carrying active work",g=_??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",g=_??p??"This can be picked up immediately."):(y=!0,d="bad",c="Assigned owner is not present in the room",g="Reassign or bring the owner back online."):(y=!0,d=zt(t.priority)<=2?"bad":"warn",c=zt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",g="Assign an agent before this queue item slips."):m&&(t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,d="bad",c="Assigned owner is offline",g=_??"Execution has no live operator right now."):l>ea?(S=!0,d="bad",c="Assigned owner has gone quiet",g=_??"Fresh operator signal is missing."):l>va?(S=!0,d="warn",c="Execution has been quiet for too long",g=_??"Check whether this work is blocked."):(P=i.current_task)!=null&&P.trim()?(c="Execution has fresh owner coverage",g=_??p??t.id):(d="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",g=_??"Task state and agent focus are drifting apart."):(y=!0,d="bad",c="Assigned owner is not active in the room",g="Execution is orphaned until ownership is restored."):(y=!0,d="bad",c="Active work has no assignee",g="Claim or reassign this task immediately.")),{task:t,assigneeAgent:i,motion:o,tone:d,note:c,focus:g,lastSignalAt:r,lastTouchedAt:_d(t),ownerGap:y,quiet:S}}function $d(t,e){var c;const n=e.get(me(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,i=a?Math.max(0,Date.now()-Y(a)):Number.POSITIVE_INFINITY,o=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,l=o||r>0;let p="loaded",_="ok",m="Healthy active load",d=ct(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",_="bad",m="Agent is unavailable"):l&&i>ea?(p="quiet",_="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",_="warn",m="Claimed work exists but current_task is empty",d=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",_="warn",m="current_task has no matching claimed work",d=ct(t.current_task)??"Task metadata and operator state drifted."):!l&&i<=va?(p="dispatchable",_="ok",m="Fresh signal and no active load",d=n.lastActivityText??"Ready for assignment."):l?i>va&&(p="loaded",_="warn",m="Execution load is healthy but slightly quiet",d=ct(t.current_task)??`${r} active tasks in flight.`):(p="quiet",_=i>ea?"bad":"warn",m=i>ea?"No fresh signal while idle":"Reachable, but not freshly active",d=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:_,state:p,note:m,focus:d,lastSignalAt:a,activeTaskCount:r}}function Xe({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function hd({item:t}){return s`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?$i(t.taskRow.task.priority):Zo(t.agentRow.state)}
        </span>
        ${t.kind==="task"?s`<span>${Xo(t.taskRow.task.status)}</span>`:s`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?s`<span><${F} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </div>
  `}function Bi({row:t}){var e;return s`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${$i(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?s`<${Lt} status=${t.assigneeAgent.status} />`:s`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${Xo(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?s`<span>Owner ${t.task.assignee}</span>`:s`<span>Unassigned</span>`}
        ${t.lastTouchedAt?s`<span>Touched <${F} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ct(t.assigneeAgent.current_task)!==t.focus?s`<div class="monitor-footnote">Owner focus: ${ct(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function yd({row:t}){const{agent:e}=t;return s`
    <button class="monitor-row ${t.tone}" onClick=${()=>Me(e.name)}>
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
        <span class="monitor-pill ${t.tone}">${Zo(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function bd(){const t=At.value,e=yt.value,n=new Map(t.map(d=>[me(d.name),d])),a=Ba.value,i=e.filter(d=>d.status==="claimed"||d.status==="in_progress").map(d=>Ui(d,n,a)).sort((d,c)=>{const g=st(c.tone)-st(d.tone);return g!==0?g:Y(c.lastSignalAt??c.lastTouchedAt)-Y(d.lastSignalAt??d.lastTouchedAt)}),o=e.filter(d=>d.status==="todo").map(d=>Ui(d,n,a)).sort((d,c)=>{const g=st(c.tone)-st(d.tone);if(g!==0)return g;const y=zt(d.task.priority)-zt(c.task.priority);return y!==0?y:Y(d.lastTouchedAt)-Y(c.lastTouchedAt)}),r=t.map(d=>$d(d,a)).filter(d=>d.state==="dispatchable"||d.state==="drift"||d.state==="quiet").sort((d,c)=>{if(d.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&d.state!=="dispatchable")return 1;const g=st(c.tone)-st(d.tone);return g!==0?g:Y(c.lastSignalAt)-Y(d.lastSignalAt)}),l=[...i.filter(d=>d.tone!=="ok").map(d=>({kind:"task",key:`active-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt??d.lastTouchedAt,taskRow:d})),...o.filter(d=>d.tone==="bad").map(d=>({kind:"task",key:`ready-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastTouchedAt,taskRow:d})),...r.filter(d=>d.state==="drift"||d.tone==="bad").map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agentRow:d}))].sort((d,c)=>{const g=st(c.tone)-st(d.tone);return g!==0?g:Y(c.timestamp)-Y(d.timestamp)}).slice(0,8),p=r.filter(d=>d.state==="dispatchable"),_=[...i,...o].filter(d=>d.ownerGap),m=i.filter(d=>d.quiet);return s`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Xe} label="Active work" value=${i.length} color="#fbbf24" caption="claimed + in progress" />
        <${Xe} label="Needs intervention" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Xe} label="Ownership gaps" value=${_.length} color=${_.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Xe} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Xe} label="Quiet execution" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?s`<div class="empty-state">No active execution risks right now</div>`:l.map(d=>s`<${hd} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?s`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(d=>s`<${Bi} key=${d.task.id} row=${d} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?s`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(d=>s`<${yd} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${i.length===0?s`<div class="empty-state">No active execution tasks</div>`:i.map(d=>s`<${Bi} key=${d.task.id} row=${d} />`)}
        </div>
      <//>
    </div>
  `}function kd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function xd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Sd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Wi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function tr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Ad(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function er(t){if(!t)return null;const e=Bt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function nr({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&qo(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Bt.value[t.name],a=er(t),i=Ps.value[t.name];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${kd(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${xd((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${i?s`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?s` · ${tr(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?s` · next eligible ${Ad(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?s`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?s`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function ar({keeperName:t,placeholder:e}){const[n,a]=Ha("");rt(()=>{t&&qo(t)},[t]);const i=dt.value[t]??[],o=Ds.value[t]??!1,r=Wt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Ec(t,p)}catch(_){const m=_ instanceof Error?_.message:`Failed to message ${t}`;C(m,"error")}}};return s`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${i.length===0?s`<div class="control-status-copy">No direct keeper conversation yet.</div>`:i.map(p=>s`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Wi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Wi(p)}`}>${Sd(p)}</span>
                  ${p.timestamp?s`<span class="keeper-conversation-time">${tr(p.timestamp)}</span>`:null}
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
  `}function sr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=er(e),i=Es.value[e.name]??!1,o=Is.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",l=(a==null?void 0:a.recoverable)??r==="recover";return s`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Ic(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;C(_,"error")})}}
        disabled=${i||!t.trim()}
      >
        ${i?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Mc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;C(_,"error")})}}
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
  `}const yi=f(null);function fa(t){yi.value=t,Yn(t.name)}function Gi(){yi.value=null}const we=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Cd(t){if(!t)return 0;const e=we.findIndex(n=>n.level===t);return e>=0?e:0}function wd({keeper:t}){const e=Cd(t.autonomy_level),n=we[e]??we[0];if(!n)return null;const a=(e+1)/we.length*100;return s`
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
  `}function na(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Td({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",i=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return s`
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
  `}function Nd({keeper:t}){var m,d;const e=t.metrics_series??[];if(e.length<2){const c=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,g=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return s`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${g}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,i=2,o=e.length,r=e.map((c,g)=>{const y=i+g/(o-1)*(n-2*i),S=a-i-(c.context_ratio??0)*(a-2*i);return{x:y,y:S,p:c}}),l=r.map(({x:c,y:g})=>`${c.toFixed(1)},${g.toFixed(1)}`).join(" "),p=(((d=e[e.length-1])==null?void 0:d.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return s`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${i}" y1="${(a-i-.5*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.5*(a-2*i)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${i}" y1="${(a-i-.7*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.7*(a-2*i)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${i}" y1="${(a-i-.85*(a-2*i)).toFixed(1)}" x2="${n-i}" y2="${(a-i-.85*(a-2*i)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:c})=>c.is_handoff).map(({x:c})=>s`
          <line x1="${c.toFixed(1)}" y1="${i}" x2="${c.toFixed(1)}" y2="${a-i}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${r.filter(({p:c})=>c.is_compaction).map(({x:c,y:g})=>s`
          <circle cx="${c.toFixed(1)}" cy="${g.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Za=f("");function Rd({keeper:t}){var i,o,r,l;const e=Za.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((i=t.traits)==null?void 0:i.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return s`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Za.value}
        onInput=${p=>{Za.value=p.target.value}}
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
  `}function Ld({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return s`
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
  `}function Pd({items:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No equipment</div>`:s`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>s`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Dd({rels:t}){const e=Object.entries(t);return e.length===0?s`<div class="empty-state" style="font-size:13px">No relationships</div>`:s`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>s`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ji({traits:t,label:e}){return t.length===0?null:s`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>s`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ts(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Ed({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ts(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ts(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ts(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return s`
    <div class="keeper-signal-list">
      ${n.map(a=>s`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function ir(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Id(){try{const t=await On({actor:ir(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=gi(t.result);qe(),await ne(),e!=null&&e.skipped_reason?C(e.skipped_reason,"warning"):C(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";C(e,"error")}}function Md({keeper:t}){return s`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${nr} keeper=${t} />
          <${sr}
            actor=${ir()}
            keeper=${t}
            onPokeLodge=${()=>{Id()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${ar}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Od(){var e,n,a;const t=yi.value;return t?s`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${i=>{i.target.classList.contains("keeper-detail-overlay")&&Gi()}}
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
            onClick=${()=>Gi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Td} keeper=${t} />

        ${""}
        <${Nd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${Rd} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${Ji} traits=${t.traits??[]} label="Traits" />
            <${Ji} traits=${t.interests??[]} label="Interests" />
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
              <${w} title="Autonomy">
                <${wd} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?s`
              <${w} title="TRPG Stats">
                <${Ld} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?s`
              <${w} title="Equipment (${t.inventory.length})">
                <${Pd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?s`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${Dd} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${Ed} keeper=${t} />
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
        <${Md} keeper=${t} />
      </div>
    </div>
  `:null}const Fe=f(!1);function zd(){Fe.value=!0}function Vi(){Fe.value=!1}function qd(){Fe.value=!Fe.value}const es=600*1e3,ns=1200*1e3,Qi=.8,as=f("triage");function Se(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Fn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function Yi(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Xi(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function jd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ss(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Fd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Kd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Hd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Ud(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Yi(t.quiet_start)}-${Yi(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Xi(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${Xi(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function Zi(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function Ae({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Bd({item:t}){return s`
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
  `}function is({tone:t,title:e,subtitle:n,meta:a,focus:i,onClick:o}){return s`
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
  `}function to(){var X,H,Pt,mt,vt,B,M,k,Dt,Vt,oe,re,E,Et,le,Je,Ve;const t=se.value,e=At.value,n=yt.value,a=Jt.value,i=Uo.value,o=(X=t==null?void 0:t.monitoring)==null?void 0:X.board,r=(H=t==null?void 0:t.monitoring)==null?void 0:H.council,l=Ft.value,p=new Map(e.map(v=>[me(v.name),v])),_=Ba.value,m=e.map(v=>{var Pi;const L=_.get(me(v.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},j=L.lastActivityAt??v.last_seen??null,at=j?Math.max(0,Date.now()-Y(j)):Number.POSITIVE_INFINITY,z=L.activeAssignedCount,ft=!!((Pi=v.current_task)!=null&&Pi.trim()),Q=ft||z>0;let Z="ok",kt="Fresh and ready",be=!1,ke=!1;return v.status==="offline"||v.status==="inactive"?(Z=Q?"bad":"warn",kt=Q?"Load without an available owner":"Offline"):Q&&at>ns?(Z="bad",kt="Execution is stale"):z>0&&!ft?(Z="warn",kt="Claimed work has no current_task",ke=!0):ft&&z===0?(Z="warn",kt="current_task has no claimed work",ke=!0):!Q&&at<=es?(Z="ok",kt="Dispatchable now",be=!0):!Q&&at>ns?(Z="warn",kt="Idle but not freshly active"):Q&&at>es&&(Z="warn",kt="Execution is getting quiet"),{agent:v,lastSignalAt:j,activeTaskCount:z,tone:Z,note:kt,focus:ct(v.current_task)??L.lastActivityText??(be?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:be,drift:ke}}).sort((v,L)=>{const j=st(L.tone)-st(v.tone);return j!==0?j:Y(L.lastSignalAt)-Y(v.lastSignalAt)}),d=a.map(v=>{var Z;const L=Bo.value.get(v.name)??"idle",j=Wo.value.has(v.name),at=v.context_ratio??0,z=v.diagnostic??null;let ft="ok",Q="Healthy keeper";return j||v.status==="offline"||L==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(ft="bad",Q=ct(z==null?void 0:z.summary,56)??(j?"Heartbeat stale":L==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||at>=Qi||L==="preparing"||L==="compacting")&&(ft="warn",Q=ct(z==null?void 0:z.summary,56)??(at>=Qi?"High context pressure":`Lifecycle ${L}`)),{keeper:v,tone:ft,note:Q,focus:ct(z==null?void 0:z.summary,120)??ct((Z=v.agent)==null?void 0:Z.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,L)=>{const j=st(L.tone)-st(v.tone);return j!==0?j:Y(L.timestamp)-Y(v.timestamp)}),c=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var be,ke;const L=v.assignee?p.get(me(v.assignee))??null:null,j=L?_.get(me(L.name))??null:null,at=(j==null?void 0:j.lastActivityAt)??(L==null?void 0:L.last_seen)??null,z=at?Math.max(0,Date.now()-Y(at)):Number.POSITIVE_INFINITY,ft=v.status==="claimed"||v.status==="in_progress";let Q="ok",Z="Covered",kt=!1;return v.assignee?!L||L.status==="offline"||L.status==="inactive"?(Q="bad",Z="Assigned owner is unavailable",kt=!0):ft&&z>ns?(Q="bad",Z="Execution has lost a fresh signal"):ft&&z>es?(Q="warn",Z="Execution is drifting quiet"):v.status==="todo"&&zt(v.priority)<=2&&!((be=L.current_task)!=null&&be.trim())&&((j==null?void 0:j.activeAssignedCount)??0)===0?(Q="ok",Z="Ready for dispatch"):ft&&!((ke=L.current_task)!=null&&ke.trim())&&(Q="warn",Z="Owner focus is not explicit"):(Q=zt(v.priority)<=2?"bad":"warn",Z=ft?"Active work has no owner":"Ready work has no owner",kt=!0),{task:v,owner:L,lastSignalAt:at,tone:Q,note:Z,focus:ct(L==null?void 0:L.current_task)??(j==null?void 0:j.lastActivityText)??ct(v.description)??"Needs operator attention.",ownerGap:kt}}).sort((v,L)=>{const j=st(L.tone)-st(v.tone);if(j!==0)return j;const at=zt(v.task.priority)-zt(L.task.priority);return at!==0?at:Y(L.lastSignalAt??L.task.updated_at??L.task.created_at)-Y(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),g=c.filter(v=>v.task.status==="todo"&&zt(v.task.priority)<=2),y=c.filter(v=>v.ownerGap).length,S=m.filter(v=>v.dispatchable),T=m.filter(v=>v.drift||v.tone!=="ok"),P=d.filter(v=>v.tone!=="ok"),K=t!=null&&t.paused?"bad":((Pt=t==null?void 0:t.data_quality)==null?void 0:Pt.board_contract_ok)===!1||((mt=t==null?void 0:t.data_quality)==null?void 0:mt.council_feed_ok)===!1?"warn":l?"ok":"warn",I=[];t!=null&&t.paused&&I.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((vt=t.data_quality)==null?void 0:vt.last_sync_at)??null,action:()=>Rt("ops")}),l||I.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:zd}),Se(o==null?void 0:o.alert_level)!=="ok"&&I.push({key:"board-monitor",tone:Se(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${ss(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Rt("board")}),Se(r==null?void 0:r.alert_level)!=="ok"&&I.push({key:"council-monitor",tone:Se(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${ss(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Rt("board")}),(((B=t==null?void 0:t.data_quality)==null?void 0:B.board_contract_ok)===!1||((M=t==null?void 0:t.data_quality)==null?void 0:M.council_feed_ok)===!1)&&I.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((k=t.data_quality)==null?void 0:k.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Dt=t.data_quality)==null?void 0:Dt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Vt=t.data_quality)==null?void 0:Vt.last_sync_at)??null,action:()=>Rt("ops")});const N=[...I,...c.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>Rt("overview")})),...P.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>fa(v.keeper)})),...T.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Me(v.agent.name)}))].sort((v,L)=>{const j=st(L.tone)-st(v.tone);return j!==0?j:Y(L.timestamp)-Y(v.timestamp)}).slice(0,8),R=as.value;return s`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${R==="triage"?"active":""}"
        onClick=${()=>{as.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${R==="dispatch"?"active":""}"
        onClick=${()=>{as.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${R==="dispatch"?s`<${bd} />`:s`<div class="stats-grid">
      <${Ae}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Fn(K)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${Ae}
        label="Urgent Queue"
        value=${g.length}
        color=${g.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${Ae}
        label="Active Work"
        value=${i.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${Ae}
        label="Dispatchable"
        value=${S.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${Ae}
        label="Keeper Pressure"
        value=${P.length}
        color=${P.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${Ae}
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
          <div class="stat-value" style=${`color:${Fn(Se(o==null?void 0:o.alert_level))}`}>${Zi(o==null?void 0:o.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${ss(o==null?void 0:o.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Fn(Se(r==null?void 0:r.alert_level))}`}>${Zi(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Fn(K)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${jd((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(oe=t==null?void 0:t.data_quality)!=null&&oe.last_sync_at?s`Last sync <${F} timestamp=${t.data_quality.last_sync_at} />`:s`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Ud(t==null?void 0:t.lodge)}</div>
        ${(re=t==null?void 0:t.lodge)!=null&&re.last_skip_reason?s`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

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
    </div>

    <div class="grid-2col">
      <${w} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${c.length===0?s`<div class="empty-state">No active or ready tasks</div>`:c.slice(0,6).map(v=>s`
                <${is}
                  key=${v.task.id}
                  tone=${v.tone}
                  title=${v.task.title}
                  subtitle=${`${$i(v.task.priority)} · ${v.note}`}
                  meta=${[v.task.assignee?`Owner ${v.task.assignee}`:"Unassigned",v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No live signal",v.task.updated_at?`Touched ${new Date(v.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${v.focus}
                  onClick=${()=>Rt("overview")}
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
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(a==null?void 0:a.active)??0}</strong><small>${((r=t==null?void 0:t.detachments.summary)==null?void 0:r.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(i==null?void 0:i.pending)??0}</strong><small>${(i==null?void 0:i.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(o==null?void 0:o.bad)??0}</strong><small>${(o==null?void 0:o.warn)??0} warn</small></div>
      <div class="monitor-stat-card"><span>Chains</span><strong>${((l=e==null?void 0:e.summary)==null?void 0:l.active_chains)??0}</strong><small>${((p=e==null?void 0:e.summary)==null?void 0:p.linked_operations)??0} linked</small></div>
    </div>
  `}function cp(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function dp({lane:t}){const e=t.counts??{},n=cp(t);return s`
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
  `}function up({event:t}){return s`
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
  `}function pp({gap:t}){return s`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${t.code}</strong>
        <span class="command-chip ${J(t.severity)}">${t.count}</span>
      </div>
      <p>${t.summary}</p>
      ${t.lane_ids.length>0?s`<div class="command-tag-row">${t.lane_ids.map(e=>s`<span class="command-tag">${e}</span>`)}</div>`:null}
    </div>
  `}function mp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return s`
    <div class="command-guide-card ${J(e)}">
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
  `}function vp(){const t=wi(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(p=>p.present))??[],i=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,6))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action;return s`
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
                ${a.length>0?a.map(p=>s`<${dp} lane=${p} />`):s`<div class="empty-state">No active swarm lanes.</div>`}
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

                <${mp} proof=${n} />

                <div class="command-guide-card ${i.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${J(i.some(p=>p.severity==="bad")?"bad":i.length>0?"warn":"ok")}">${i.length}</span>
                  </div>
                  ${i.length>0?s`<div class="command-card-stack">${i.slice(0,4).map(p=>s`<${pp} gap=${p} />`)}</div>`:s`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${o.length}</span>
                  </div>
                  ${o.length>0?s`<div class="command-card-stack">${o.map(p=>s`<${up} event=${p} />`)}</div>`:s`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:s`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function fp(){return s`
    <div class="command-surface-tabs">
      ${kr.map(t=>s`
        <button
          class="command-surface-tab ${Ke.value===t?"active":""}"
          onClick=${()=>xi(t)}
        >
          ${t}
        </button>
      `)}
    </div>
  `}function gp(){var mt,vt,B,M,k,Dt,Vt,oe,re;const t=wi(),e=Ht.value,n=se.value,a=np(),i=a?At.value.find(E=>E.name===a)??null:null,o=a?yt.value.filter(E=>E.assignee===a&&ip(E)):[],r=((mt=t==null?void 0:t.operations.summary)==null?void 0:mt.active)??0,l=((vt=t==null?void 0:t.detachments.summary)==null?void 0:vt.total)??0,p=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,_=e==null?void 0:e.detachments.detachments.find(E=>{const Et=E.detachment.heartbeat_deadline,le=Et?Date.parse(Et):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(le)&&le<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),d=!!(n!=null&&n.room||n!=null&&n.project),c=(i==null?void 0:i.current_task)??null,g=sp(i==null?void 0:i.last_seen),y=g!=null?g<=120:null,S=[d?{title:"Room readiness",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},a?i?o.length===0?{title:"Task readiness",tone:"warn",detail:`${a} has no claimed task. Claim one or create one first.`,tool:yt.value.length>0?"masc_claim":"masc_add_task"}:c?y===!1?{title:"Task readiness",tone:"warn",detail:`${a} current_task=${c}, but heartbeat is stale (${g}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${a} current_task=${c}${g!=null?` · last seen ${g}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${a} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${a} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((M=t.topology.summary)==null?void 0:M.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:r===0?{title:"Operation readiness",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${r} active operation(s) across ${((Dt=t.topology.summary)==null?void 0:Dt.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},p>0?{title:"Dispatch readiness",tone:"warn",detail:`${p} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:_||m?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${_?` · detachment ${_.detachment.detachment_id} is stalled`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!_&&!m?" · open a detail tab to inspect the exact source.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${l} detachment(s) visible and no strict approval backlog${e?"":" · detail panes stay lazy until opened."}.`,tool:"masc_detachment_list"}],T=d?!a||!i?"masc_join":o.length===0?yt.value.length>0?"masc_claim":"masc_add_task":c?y===!1?"masc_heartbeat":!t||(((Vt=t.topology.summary)==null?void 0:Vt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||_||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",P=op(T),I=rp(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=rs("room_task_hygiene"),R=rs("cpv2_benchmark"),X=rs("supervisor_session"),H=((oe=zn.value)==null?void 0:oe.docs)??[],Pt=[N,R,X].filter(E=>E!==null);return s`
    <div class="command-guide-grid">
      <section class="card command-section">
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
          <div class="command-guide-head">
            <strong>${(P==null?void 0:P.title)??T}</strong>
            <span class="command-chip ok">${T}</span>
          </div>
          <p>${(P==null?void 0:P.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(re=P==null?void 0:P.success_signals)!=null&&re.length?s`<div class="command-tag-row">
                ${P.success_signals.map(E=>s`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
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
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${Ws.value?s`<div class="empty-state">Loading CPv2 runbook…</div>`:ya.value?s`<div class="empty-state error">${ya.value}</div>`:s`
                <div class="command-guide-paths">
                  ${Pt.map(E=>s`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list">
                        ${E.steps.map(Et=>s`
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
  `}function _p(){return s`
    <${lp} />
    <${vp} />
    <${gp} />
  `}function $p(){return ga.value?s`<div class="empty-state">Loading command-plane detail…</div>`:$a.value?s`<div class="empty-state error">${$a.value}</div>`:s`<div class="empty-state">Select a surface to load command-plane detail.</div>`}function xr({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,i=t.active_operation_count??0,o=t.unit.policy;return s`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${ep(t.unit.kind)}</span>
            <span class="command-chip ${J(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>s`<${xr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function hp({source:t}){const e=xo(null),[n,a]=Ha(null);return rt(()=>{let i=!1;const o=e.current;return o?(o.innerHTML="",a(null),(async()=>{try{const l=await Qu(),{svg:p}=await l.render(`command-chain-${++Vu}`,t);if(i||!e.current)return;e.current.innerHTML=p}catch(l){if(i)return;a(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{i=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),s`
    <div class="command-chain-graph-shell">
      ${n?s`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function yp({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,i=t.runtime;return s`
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
        ${i?s`<span class="command-tag ${Zt(a==null?void 0:a.status)}">${yr(i.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${br(t.history)}</div>
    </button>
  `}function bp({item:t}){return s`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Zt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${tt(t.timestamp)}</div>
      <div class="command-card-sub">${br(t)}</div>
    </article>
  `}function kp({node:t}){return s`
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
  `}function xp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,i=`recall:${e.operation_id}`,o=e.chain;return s`
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
                onClick=${()=>{Ai(e.operation_id),xi("chains"),Rt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?s`
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>zu(e.operation_id))}>
                ${it(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${it(i)} onClick=${()=>te(()=>ju(e.operation_id))}>
                ${it(i)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?s`
              <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>te(()=>qu(e.operation_id))}>
                ${it(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Sp({card:t}){var n;const e=t.detachment;return s`
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
        <span>Progress</span><span>${tt(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Ju(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${tt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?s`<span class="command-tag ${Gu(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Ap({alert:t}){return s`
    <article class="command-alert ${J(t.severity)}">
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
  `}function Sr({event:t}){return s`
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
      <pre class="command-trace-detail">${Wu(t.detail)}</pre>
    </article>
  `}function Cp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
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
        <span>Created</span><span>${tt(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?s`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${it(e)} onClick=${()=>te(()=>Ku(t.decision_id))}>
                ${it(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Hu(t.decision_id))}>
                ${it(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?s`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function wp({row:t}){var l,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,i=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return s`
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
        <span>Autonomy</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${i?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${it(n)} onClick=${()=>te(()=>Uu(e.unit_id,!i))}>
          ${it(n)?"Applying…":i?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${it(a)} onClick=${()=>te(()=>Bu(e.unit_id,!o))}>
          ${it(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Tp({item:t}){return s`
    <article class="command-guide-card ${J(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${J(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Np({blocker:t}){return s`
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
  `}function Rp({worker:t}){return s`
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
  `}function Lp(){var l,p,_,m,d,c,g,y,S,T,P,K,I,N,R,X,H,Pt,mt,vt,B;const t=rr.value,e=ap(),n=(l=t==null?void 0:t.provider)!=null&&l.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=((_=t==null?void 0:t.provider)==null?void 0:_.actual_slots)??((m=t==null?void 0:t.provider)==null?void 0:m.total_slots)??0,i=((d=t==null?void 0:t.provider)==null?void 0:d.expected_slots)??"n/a",o=((c=t==null?void 0:t.provider)==null?void 0:c.actual_ctx)??((g=t==null?void 0:t.provider)==null?void 0:g.ctx_per_slot)??0,r=((y=t==null?void 0:t.provider)==null?void 0:y.expected_ctx)??"n/a";return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Swarm Live Run</div>
        ${Gs.value?s`<div class="empty-state">Loading swarm live state…</div>`:ba.value?s`<div class="empty-state error">${ba.value}</div>`:t?s`
                  <div class="command-summary-grid">
                    <div class="monitor-stat-card"><span>Run</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room n/a"}</small></div>
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((S=t.summary)==null?void 0:S.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((P=t.summary)==null?void 0:P.live_workers)??0} live · ${((K=t.summary)==null?void 0:K.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${n}</strong><small>slots ${a}/${i} · ctx ${o}/${r}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"pass":"check"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot n/a"}</small></div>
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
                  ${t.truth_notes.length>0?s`<div class="command-tag-row">
                        ${t.truth_notes.map(M=>s`<span class="command-tag">${M}</span>`)}
                      </div>`:null}
                `:s`<div class="empty-state">No swarm read-model yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Checklist</div>
        ${t&&t.checklist.length>0?s`<div class="command-card-stack">
              ${t.checklist.map(M=>s`<${Tp} item=${M} />`)}
            </div>`:s`<div class="empty-state">No checklist yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Workers</div>
        ${t&&t.workers.length>0?s`<div class="command-card-stack">
              ${t.workers.map(M=>s`<${Rp} worker=${M} />`)}
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
              ${t.blockers.map(M=>s`<${Np} blocker=${M} />`)}
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
              ${t.recent_trace_events.map(M=>s`<${Sr} event=${M} />`)}
            </div>`:s`<div class="empty-state">No run-scoped trace events captured yet.</div>`}
      </section>
    </div>
  `}function Pp(){const t=Ht.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?s`<div class="command-card-stack">
              ${t.operations.operations.map(e=>s`<${xp} card=${e} />`)}
            </div>`:s`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?s`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>s`<${Sp} card=${e} />`)}
            </div>`:s`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Dp(){var l,p,_,m,d,c,g,y,S,T,P,K,I,N,R,X;const t=bi.value,e=(t==null?void 0:t.operations)??[],n=cn.value,a=e.find(H=>H.operation.operation_id===n)??e[0]??null,i=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((p=Ln.value)==null?void 0:p.run)??(a==null?void 0:a.preview_run)??null,r=!((_=Ln.value)!=null&&_.run)&&!!(a!=null&&a.preview_run);return rt(()=>{i?Mu(i):Iu()},[i]),s`
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
            <span>Recent Failures</span><span>${((c=t==null?void 0:t.summary)==null?void 0:c.recent_failures)??0}</span>
            <span>Last Event</span><span>${tt((g=t==null?void 0:t.summary)==null?void 0:g.last_history_event_at)}</span>
          </div>
        </article>

        ${ka.value?s`<div class="empty-state error">${ka.value}</div>`:null}

        ${Js.value&&!t?s`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?s`
                <div class="command-chain-list">
                  ${e.map(H=>s`
                    <${yp}
                      overlay=${H}
                      selected=${(a==null?void 0:a.operation.operation_id)===H.operation.operation_id}
                      onSelect=${()=>Ai(H.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(H=>s`<${bp} item=${H} />`)}
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
                  <span>Progress</span><span>${yr((K=a.runtime)==null?void 0:K.progress)}</span>
                  <span>Elapsed</span><span>${Yu((I=a.runtime)==null?void 0:I.elapsed_sec)}</span>
                  <span>Updated</span><span>${tt(((N=a.operation.chain)==null?void 0:N.last_sync_at)??a.operation.updated_at)}</span>
                </div>
                ${(R=a.operation.chain)!=null&&R.goal?s`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?s`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((X=a.operation.chain)==null?void 0:X.chain_id)??"graph"}</span>
                      </div>
                      <${hp} source=${a.mermaid} />
                    </div>
                  `:s`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${xa.value?s`<div class="empty-state">Loading run detail…</div>`:Pn.value?s`<div class="empty-state error">${Pn.value}</div>`:o&&o.nodes.length>0?s`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?s`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(H=>s`<${kp} node=${H} />`)}
                          </div>
                        `:s`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:s`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Ep(){const t=Ht.value;return s`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?s`${t.topology.units.map(e=>s`<${xr} node=${e} />`)}`:s`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Ip(){const t=Ht.value;return s`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?s`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>s`<${Ap} alert=${e} />`)}
          </div>`:s`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Mp(){const t=Ht.value;return s`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?s`<div class="command-trace-stack">
            ${t.traces.events.map(e=>s`<${Sr} event=${e} />`)}
          </div>`:s`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Op(){const t=Ht.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?s`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>s`<${Cp} decision=${e} />`)}
            </div>`:s`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?s`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>s`<${wp} row=${e} />`)}
            </div>`:s`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function zp(){if(Ke.value==="summary")return s`<${_p} />`;if(!Ht.value)return s`<${$p} />`;switch(Ke.value){case"swarm":return s`<${Lp} />`;case"chains":return s`<${Dp} />`;case"topology":return s`<${Ep} />`;case"alerts":return s`<${Ip} />`;case"trace":return s`<${Mp} />`;case"control":return s`<${Op} />`;case"operations":default:return s`<${Pp} />`}}function qp(){return rt(()=>{fe(),$e(),Ou(),hr()},[]),rt(()=>{if(nt.value.tab!=="command")return;const t=nt.value.params.surface,e=nt.value.params.operation;Zu(t)&&xi(t),e&&Ai(e)},[nt.value.tab,nt.value.params.surface,nt.value.params.operation]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,fe(),$e()},250))},n=new EventSource(tp()),a=Xu.map(i=>{const o=()=>e();return n.addEventListener(i,o),{type:i,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:i,handler:o})=>{n.removeEventListener(i,o)}),n.close(),t&&window.clearTimeout(t)}},[]),s`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{te(()=>Fu())}}
            disabled=${it("dispatch:tick")}
          >
            ${it("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{fe()}} disabled=${ln.value}>
          <button class="control-btn ghost" onClick=${()=>{fe(),$e()}} disabled=${ln.value}>
            ${ln.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${_a.value?s`<div class="empty-state error">${_a.value}</div>`:null}
      ${ha.value?s`<div class="empty-state error">${ha.value}</div>`:null}
      <${fp} />
      <${zp} />
    </section>
  `}const qn=f(null),Sa=f(!1),ae=f(null),W=f(!1),Aa=f([]);let jp=1;function G(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function D(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $t(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ar(t){return typeof t=="boolean"?t:void 0}function Fp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Te(t,e=[]){if(Array.isArray(t))return t;if(!G(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Kp(t){return G(t)?{id:D(t.id),seq:$t(t.seq),from:D(t.from)??D(t.from_agent)??"system",content:D(t.content)??"",timestamp:D(t.timestamp)??new Date().toISOString(),type:D(t.type)}:null}function Hp(t){return G(t)?{room_id:D(t.room_id),current_room:D(t.current_room)??D(t.room),project:D(t.project),cluster:D(t.cluster),paused:Ar(t.paused),pause_reason:D(t.pause_reason)??null,paused_by:D(t.paused_by)??null,paused_at:D(t.paused_at)??null}:{}}function ao(t){if(!G(t))return;const e=Object.entries(t).map(([n,a])=>{const i=D(a);return i?[n,i]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Up(t){if(!G(t))return null;const e=G(t.status)?t.status:void 0,n=G(t.summary)?t.summary:G(e==null?void 0:e.summary)?e.summary:void 0,a=G(t.session)?t.session:G(e==null?void 0:e.session)?e.session:void 0,i=D(t.session_id)??D(n==null?void 0:n.session_id)??D(a==null?void 0:a.session_id);if(!i)return null;const o=ao(t.report_paths)??ao(e==null?void 0:e.report_paths),r=Te(t.recent_events,["events"]).filter(G);return{session_id:i,status:D(t.status)??D(n==null?void 0:n.status)??D(a==null?void 0:a.status),progress_pct:$t(t.progress_pct)??$t(n==null?void 0:n.progress_pct),elapsed_sec:$t(t.elapsed_sec)??$t(n==null?void 0:n.elapsed_sec),remaining_sec:$t(t.remaining_sec)??$t(n==null?void 0:n.remaining_sec),done_delta_total:$t(t.done_delta_total)??$t(n==null?void 0:n.done_delta_total),summary:n,team_health:G(t.team_health)?t.team_health:G(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:G(t.communication_metrics)?t.communication_metrics:G(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:G(t.orchestration_state)?t.orchestration_state:G(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:G(t.cascade_metrics)?t.cascade_metrics:G(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Bp(t){if(!G(t))return null;const e=D(t.name);if(!e)return null;const n=G(t.context)?t.context:void 0;return{name:e,agent_name:D(t.agent_name),status:D(t.status),autonomy_level:D(t.autonomy_level),context_ratio:$t(t.context_ratio)??$t(n==null?void 0:n.context_ratio),generation:$t(t.generation),active_goal_ids:Fp(t.active_goal_ids),last_autonomous_action_at:D(t.last_autonomous_action_at)??null,last_turn_ago_s:$t(t.last_turn_ago_s),model:D(t.model)??D(t.active_model)??D(t.primary_model)}}function Wp(t){if(!G(t))return null;const e=D(t.confirm_token)??D(t.token);return e?{confirm_token:e,actor:D(t.actor),action_type:D(t.action_type),target_type:D(t.target_type),target_id:D(t.target_id)??null,delegated_tool:D(t.delegated_tool),created_at:D(t.created_at),preview:t.preview}:null}function Gp(t){const e=G(t)?t:{};return{room:Hp(e.room),sessions:Te(e.sessions,["items","sessions"]).map(Up).filter(n=>n!==null),keepers:Te(e.keepers,["items","keepers"]).map(Bp).filter(n=>n!==null),recent_messages:Te(e.recent_messages,["messages"]).map(Kp).filter(n=>n!==null),pending_confirms:Te(e.pending_confirms,["items","confirms"]).map(Wp).filter(n=>n!==null),available_actions:Te(e.available_actions,["actions"]).filter(G).map(n=>({action_type:D(n.action_type)??"unknown",target_type:D(n.target_type)??"unknown",description:D(n.description),confirm_required:Ar(n.confirm_required)}))}}function Kn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function so(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ca(t){Aa.value=[{...t,id:jp++,at:new Date().toISOString()},...Aa.value].slice(0,20)}function Cr(t){return t.confirm_required?Kn(t.preview)||"Confirmation required":Kn(t.result)||Kn(t.executed_action)||Kn(t.delegated_tool_result)||t.status}async function He(){Sa.value=!0,ae.value=null;try{const t=await xl();qn.value=Gp(t)}catch(t){ae.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Sa.value=!1}}async function Jp(t){W.value=!0,ae.value=null;try{const e=await On(t);return Ca({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:e.confirm_required?"preview":"executed",message:Cr(e),delegated_tool:e.delegated_tool}),await He(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ae.value=n,Ca({actor:t.actor,action_type:t.action_type,target_label:so(t),outcome:"error",message:n}),e}finally{W.value=!1}}async function Vp(t,e){W.value=!0,ae.value=null;try{const n=await Pl(t,e);return Ca({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Cr(n),delegated_tool:n.delegated_tool}),await He(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ae.value=a,Ca({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{W.value=!1}}const wr="masc_dashboard_agent_name";function Qp(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(wr))==null?void 0:a.trim())||"dashboard"}const Ga=f(Qp()),dn=f(""),Vs=f("Operator pause"),un=f(""),wa=f(""),Qs=f("2"),Ta=f(""),Oe=f("note"),Na=f(""),Ra=f(""),La=f(""),Ys=f("2"),Xs=f("Operator stop request"),Zs=f(""),pn=f("");function Yp(t){const e=t.trim()||"dashboard";Ga.value=e,localStorage.setItem(wr,e)}function io(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Xp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Pa(t){return typeof t=="string"?t.trim().toLowerCase():""}function Zp(t){var a;const e=Pa(t.status);if(e==="paused")return"bad";const n=Pa((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function oo(t){const e=Pa(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function ye(t){const e=Ga.value.trim()||"dashboard";try{const n=await Jp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?C("Confirmation queued","warning"):C(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return C(a,"error"),null}}async function ro(){const t=dn.value.trim();if(!t)return;await ye({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(dn.value="")}async function tm(){await ye({action_type:"room_pause",target_type:"room",payload:{reason:Vs.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function em(){await ye({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function nm(){const t=un.value.trim();if(!t)return;await ye({action_type:"task_inject",target_type:"room",payload:{title:t,description:wa.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Qs.value,10)||2},successMessage:"Task injection submitted"})&&(un.value="",wa.value="")}async function am(){var o;const t=qn.value,e=Ta.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){C("Select a team session first","warning");return}const n={turn_kind:Oe.value},a=Na.value.trim();a&&(n.message=a),Oe.value==="task"&&(n.task_title=Ra.value.trim()||"Operator injected task",n.task_description=La.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Ys.value,10)||2),await ye({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Na.value="",Oe.value==="task"&&(Ra.value="",La.value=""))}async function sm(){var n;const t=qn.value,e=Ta.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){C("Select a team session first","warning");return}await ye({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Xs.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function im(){var i;const t=qn.value,e=Zs.value||((i=t==null?void 0:t.keepers[0])==null?void 0:i.name)||"",n=pn.value.trim();if(!e){C("Select a keeper first","warning");return}if(!n)return;await ye({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(pn.value="")}async function om(t){const e=Ga.value.trim()||"dashboard";try{await Vp(e,t),C("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";C(a,"error")}}function rm(){var d;const t=qn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],i=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Ta.value)??n[0]??null,l=a.find(c=>c.name===Zs.value)??a[0]??null,p=n.filter(c=>Zp(c)!=="ok"),_=a.filter(c=>oo(c)!=="ok"),m=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:i.length,detail:i.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:i.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(c=>Pa(c.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:_.length,detail:_.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:_.some(c=>oo(c)==="bad")?"bad":_.length>0?"warn":"ok"}];return s`
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
            value=${Ga.value}
            onInput=${c=>Yp(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{He()}} disabled=${Sa.value||W.value}>
            ${Sa.value?"Refreshing...":"Refresh"}
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
          ${m.map(c=>s`
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
                ${c.preview?s`<pre class="ops-code-block">${io(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{om(c.confirm_token)}} disabled=${W.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
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
                  </div>
                  <div class="ops-feed-content">${c.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?s`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var g;return s`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{Ta.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(g=c.team_health)!=null&&g.status?String(c.team_health.status):"health n/a"}</span>
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
        </div>
      </section>
    </section>
  `}function lm({text:t}){if(!t)return null;const e=cm(t);return s`<div class="markdown-content">${e}</div>`}function cm(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const i=e[a];if(/^(`{3,}|~{3,})/.test(i)){const r=i.match(/^(`{3,}|~{3,})/)[0],l=i.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(s`<pre><code class=${l?`language-${l}`:""}>${p.join(`
`)}</code></pre>`);continue}if(i.trim()==="<think>"||i.trim().startsWith("<think>")){const r=[],l=i.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const _=e[a].replace("</think>","").trim();_&&r.push(_),a++}const p=r.join(`
`).trim();n.push(s`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ls(p)}</div>
        </details>
      `);continue}if(i.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${ls(r.join(`
`))}</blockquote>`);continue}if(i.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(s`<p>${ls(o.join(`
`))}</p>`)}return n}function ls(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,i;for(;(i=n.exec(t))!==null;){if(i.index>a&&e.push(t.slice(a,i.index)),i[1]){const o=i[1].slice(1,-1);e.push(s`<code>${o}</code>`)}else if(i[2]){const o=i[2].slice(2,-2);e.push(s`<strong>${o}</strong>`)}else if(i[3]){const o=i[3].slice(1,-1);e.push(s`<em>${o}</em>`)}else i[4]&&i[5]&&e.push(s`<a href=${i[5]} target="_blank" rel="noopener">${i[4]}</a>`);a=i.index+i[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const an=f("posts"),ti=f([]),ei=f([]),mn=f(""),Da=f(!1),vn=f(!1),Dn=f(""),Ea=f(null),Tt=f(null),ni=f(!1),Xt=f(null),aa=f(null);async function Ja(){Da.value=!0,Dn.value="";try{const[t,e]=await Promise.all([fc(),gc()]);ti.value=t,ei.value=e,Xt.value=!0,aa.value=Date.now()}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load council data",Xt.value=!1}finally{Da.value=!1}}ad(Ja);async function lo(){const t=mn.value.trim();if(t){vn.value=!0;try{const e=await _c(t);mn.value="",C(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ja()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";C(n,"error")}finally{vn.value=!1}}}async function dm(t){Ea.value=t,ni.value=!0,Tt.value=null;try{Tt.value=await $c(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate status",Tt.value=null}finally{ni.value=!1}}const Tr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],sa=f(null),fn=f([]),he=f(!1),ge=f(null),gn=f("");function um(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const pm=f(um()),_n=f(!1);async function Ti(t){ge.value=t,sa.value=null,fn.value=[],he.value=!0;try{const e=await ql(t);if(ge.value!==t)return;sa.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},fn.value=e.comments??[]}catch{ge.value===t&&(sa.value=null,fn.value=[])}finally{ge.value===t&&(he.value=!1)}}async function co(t){const e=gn.value.trim();if(e){_n.value=!0;try{await jl(t,pm.value,e),gn.value="",C("Comment posted","success"),await Ti(t),qt()}catch{C("Failed to post comment","error")}finally{_n.value=!1}}}function mm(){const t=An.value;return s`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Tr.map(e=>s`
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
  `}function ai(){var e;const t=(e=se.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:s`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?s`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Nr({flair:t}){return t?s`<span class="post-flair ${t}">${t}</span>`:null}function vm(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function uo(t){return t.updated_at!==t.created_at}function si(){var n;const t=((n=Tr.find(a=>a.id===An.value))==null?void 0:n.label)??An.value,e=Be.value.length;return s`
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
        <strong>${Hs.value?s`<${F} timestamp=${Hs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function fm({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Eo(t.id,n),qt()}catch{C("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>Zr(t.id)}>
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
              <${Nr} flair=${t.flair} />
              ${uo(t)?s`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${F} timestamp=${t.created_at} /></span>
            ${uo(t)?s`<span>Updated <${F} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?s`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${vm(t.content)}</div>
      </div>
    </div>
  `}function gm({comments:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No comments yet</div>`:s`
    <div class="comment-thread">
      ${t.map(e=>s`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function _m({postId:t}){return s`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${gn.value}
        onInput=${e=>{gn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&co(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${_n.value}
      />
      <button
        onClick=${()=>co(t)}
        disabled=${_n.value||gn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${_n.value?"...":"Post"}
      </button>
    </div>
  `}function $m({post:t}){ge.value!==t.id&&!he.value&&Ti(t.id);const e=async n=>{try{await Eo(t.id,n),qt()}catch{C("Failed to vote","error")}};return s`
    <div>
      <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
      <${w} title=${s`${t.title} <${Nr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${lm} text=${t.content} />
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

      <${w} title="Comments (${he.value?"...":fn.value.length})">
        ${he.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${gm} comments=${fn.value} />`}
        <${_m} postId=${t.id} />
      <//>
    </div>
  `}function hm({debate:t}){const e=Ea.value===t.id;return s`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>dm(t.id)}
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
  `}function ym({session:t}){return s`
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
  `}function Rr(){return Xt.value===null||Xt.value&&!aa.value?null:s`
    <div class="feed-health-banner ${Xt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Xt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${aa.value?s`<span class="feed-health-meta">Last sync: <${F} timestamp=${aa.value} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function bm(){const t=Xt.value===!1;return s`
    <div>
      <${Rr} />
      <${w} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${mn.value}
            onInput=${e=>{mn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&lo()}}
            disabled=${vn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${lo}
            disabled=${vn.value||mn.value.trim()===""}
          >
            ${vn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ja} disabled=${Da.value}>
            ${Da.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Dn.value?s`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section">
        <div class="council-list">
          ${ti.value.length===0?s`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:ti.value.map(e=>s`<${hm} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${w} title=${Ea.value?`Debate Detail (${Ea.value})`:"Debate Detail"} class="section">
        ${ni.value?s`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?s`
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
  `}function km(){const t=Xt.value===!1;return s`
    <div>
      <${Rr} />
      <${w} title="Voting Sessions" class="section">
        <div class="council-list">
          ${ei.value.length===0?s`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:ei.value.map(e=>s`<${ym} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function xm(){const t=an.value;return s`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{an.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{an.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{an.value="voting"}}>Voting</button>
    </div>
  `}function Sm(){var a,i;const t=Be.value,e=wn.value,n=((i=(a=se.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;return s`
    <div>
      <${ai} />
      <${si} />
      <${mm} />
      ${e?s`<div class="loading-indicator">Loading board...</div>`:t.length===0?s`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":ue.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:s`<div class="board-post-list">
              ${t.map(o=>s`<${fm} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function Am(){var i,o;const t=Be.value,e=nt.value.postId,n=((o=(i=se.value)==null?void 0:i.data_quality)==null?void 0:o.board_contract_ok)===!1,a=an.value;if(rt(()=>{(a==="debates"||a==="voting")&&Ja()},[a]),e){const r=t.find(l=>l.id===e)??(ge.value===e?sa.value:null);return!r&&ge.value!==e&&!he.value&&Ti(e),r?s`
          <${ai} />
          <${si} />
          <${$m} post=${r} />
        `:s`
          <div>
            <${ai} />
            <${si} />
            <button class="back-btn" onClick=${()=>Rt("board")}>← Back to Board</button>
            ${he.value?s`<div class="loading-indicator">Loading post...</div>`:s`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return s`
    <${xm} />
    ${a==="debates"?s`<${bm} />`:a==="voting"?s`<${km} />`:s`<${Sm} />`}
  `}const Cm=40;function wm({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:i,className:o=""}){const r=xo(null),[l,p]=Ha({start:0,end:30}),_=t.length>Cm;if(rt(()=>{if(!_)return;const g=r.current;if(!g)return;let y=!1;const S=()=>{const{scrollTop:I,clientHeight:N}=g,R=Math.max(0,Math.floor(I/e)-n),X=Math.min(t.length,Math.ceil((I+N)/e)+n);p(H=>H.start===R&&H.end===X?H:{start:R,end:X})};let T=!1;const P=()=>{T||y||(T=!0,requestAnimationFrame(()=>{y||S(),T=!1}))},K=new ResizeObserver(()=>{y||S()});return S(),g.addEventListener("scroll",P,{passive:!0}),K.observe(g),()=>{y=!0,g.removeEventListener("scroll",P),K.disconnect()}},[_,t.length,e,n]),!_)return s`
      <div class=${o}>
        ${t.map((g,y)=>a(g,y))}
      </div>
    `;const m=t.length*e,d=l.start*e,c=t.slice(l.start,l.end);return s`
    <div ref=${r} class=${o}>
      <div class="virtual-list-spacer" style=${{height:`${m}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${d}px)`}}
        >
          ${c.map((g,y)=>{const S=l.start+y;return s`<div key=${i(g)}>${a(g,S)}</div>`})}
        </div>
      </div>
    </div>
  `}function Tm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Nm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Rm(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Lr=120,Lm=12,Pm=16,Dm=12,ii=f("all"),Em={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Im={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Mm(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Om(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Tm(t),actor:Nm(t),content:Rm(t),timestamp:new Date(t.timestamp).toISOString()}}function zm(t,e){var i;const n=(i=t.assignee)==null?void 0:i.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function qm(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Hn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function oi(t){return t.last_heartbeat??Hn(t.last_turn_ago_s)??Hn(t.last_proactive_ago_s)??Hn(t.last_handoff_ago_s)??Hn(t.last_compaction_ago_s)}function jm(t,e){const n=oi(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function It(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const ri=Ct(()=>{const t=Sn.value.map(Mm),e=ca.value.map(Om),n=[...yt.value].sort((o,r)=>It(r.updated_at??r.created_at??0)-It(o.updated_at??o.created_at??0)).slice(0,Lm).map(zm).filter(o=>o!==null),a=[...Be.value].sort((o,r)=>It(r.updated_at||r.created_at)-It(o.updated_at||o.created_at)).slice(0,Pm).map(qm),i=[...Jt.value].sort((o,r)=>It(oi(r)??0)-It(oi(o)??0)).slice(0,Dm).map(jm).filter(o=>o!==null);return[...t,...e,...n,...a,...i].sort((o,r)=>It(r.timestamp)-It(o.timestamp))}),Fm=Ct(()=>{const t=ri.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Km=Ct(()=>{const t=ii.value;return(t==="all"?ri.value:ri.value.filter(n=>n.kind===t)).slice(0,Lr)}),Hm=Ct(()=>{const t=Ba.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return At.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const i=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return i!==0?i:It(a.motion.lastActivityAt??0)-It(n.motion.lastActivityAt??0)})});function Um(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ze({label:t,value:e,color:n}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Bm({row:t}){return s`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Um(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Im[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Wm(){const t=Fm.value,e=Km.value,n=e[0],a=Hm.value;return s`
    <div class="stats-grid">
      <${Ze} label="Visible rows" value=${e.length} />
      <${Ze} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Ze} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Ze} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Ze} label="SSE events" value=${In.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(i=>s`
            <button
              class="goal-filter-btn ${ii.value===i?"active":""}"
              onClick=${()=>{ii.value=i}}
            >
              ${Em[i]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ft.value?"":"pill-stale"}">
            ${Ft.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?s`Latest: <${F} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Lr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?s`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:s`<${wm}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${i=>i.id}
            renderItem=${i=>s`<${Bm} row=${i} />`}
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
  `}function Pr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,i=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),s`
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
  `}const cs=600*1e3,Gm=1200*1e3,po=.8;function Qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ce(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Jm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Vm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Qm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Ym(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Xm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Zm(t){var p,_;const e=Ba.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Qt(n)):Number.POSITIVE_INFINITY,i=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>Gm?(o="quiet",r="bad",l=i?"Working without a fresh signal":"No fresh agent signal"):i?(o="working",r=a>cs?"warn":"ok",l=a>cs?"Execution looks quiet for too long":"Task and live signal aligned"):a>cs?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function tv(t){const e=Bo.value.get(t.name)??"idle",n=Wo.value.has(t.name),a=t.context_ratio??0;let i="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(i="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=po)&&(i="warning",o="warn",r=a>=po?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:i,tone:o,focus:Ym(t),note:r}}function tn({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function ev({item:t}){const e=t.kind==="agent"?()=>Me(t.agent.name):()=>fa(t.keeper);return s`
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
  `}function mo({row:t}){const{agent:e,motion:n}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Me(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Pr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Jm(t.state)}</span>
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
  `}function nv({row:t}){const{keeper:e}=t;return s`
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
        <${Pr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Lt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Vm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?s`<span>Heartbeat <${F} timestamp=${e.last_heartbeat} /></span>`:s`<span>No heartbeat</span>`}
        <span>${Xm(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Qm(e.context_ratio)}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?s`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function av(){const t=[...At.value].map(Zm).sort((m,d)=>{const c=Ce(d.tone)-Ce(m.tone);if(c!==0)return c;const g=d.activeTaskCount-m.activeTaskCount;return g!==0?g:Qt(d.lastSignalAt)-Qt(m.lastSignalAt)}),e=[...Jt.value].map(tv).sort((m,d)=>{const c=Ce(d.tone)-Ce(m.tone);if(c!==0)return c;const g=(d.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return g!==0?g:Qt(d.keeper.last_heartbeat)-Qt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),i=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Qt(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),_=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,d)=>{const c=Ce(d.tone)-Ce(m.tone);return c!==0?c:Qt(d.timestamp)-Qt(m.timestamp)}).slice(0,8);return s`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${tn} label="Agents online" value=${i} color="#4ade80" caption="active + idle" />
        <${tn} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${tn} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${tn} label="Agent alerts" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${tn} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?s`<div class="empty-state">No agent or keeper alerts right now</div>`:_.map(m=>s`<${ev} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?s`<div class="empty-state">No keepers active</div>`:e.map(m=>s`<${nv} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

        <${w} title="Agent Watch" class="section">
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
                  ${n.map(m=>s`<${mo} key=${m.agent.name} row=${m} />`)}
                `:null}
                ${a.length>0?s`
                  <div class="agent-group-header">
                    Offline <span class="group-count">${a.length}</span>
                  </div>
                  ${a.map(m=>s`<${mo} key=${m.agent.name} row=${m} />`)}
                `:null}
              `}
          </div>
        <//>
      </div>
    </div>
  `}const Ia=f("all"),Ma=f("all"),li=Ct(()=>{let t=Cn.value;return Ia.value!=="all"&&(t=t.filter(e=>e.horizon===Ia.value)),Ma.value!=="all"&&(t=t.filter(e=>e.status===Ma.value)),t}),sv=Ct(()=>{const t={short:[],mid:[],long:[]};for(const e of li.value){const n=t[e.horizon];n&&n.push(e)}return t}),iv=Ct(()=>{const t=Array.from(Fo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function ov(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ni(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ia(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function rv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function vo(t){return t.toFixed(4)}function fo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function lv({goal:t}){return s`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ia(t.horizon)}">
            ${Ni(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${ov(t.priority)}</span>
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
  `}function go({label:t,timestamp:e,source:n,note:a}){return s`
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
  `}function ds({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,i)=>i.priority-a.priority);return s`
    <${w} title="${Ni(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>s`<${lv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function cv(){return s`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>s`
          <button
            class="goal-filter-btn ${Ia.value===t?"active":""}"
            onClick=${()=>{Ia.value=t}}
          >
            ${t==="all"?"All":Ni(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>s`
          <button
            class="goal-filter-btn ${Ma.value===t?"active":""}"
            onClick=${()=>{Ma.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function dv(){const t=Cn.value,e=t.filter(i=>i.status==="active").length,n=t.filter(i=>i.status==="completed").length,a={short:0,mid:0,long:0};for(const i of t)i.horizon in a&&a[i.horizon]++;return s`
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
  `}function uv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return s`
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
          <span>Baseline ${vo(t.baseline_metric)}</span>
          <span>Current ${vo(t.current_metric)}</span>
          <span class=${fo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${fo(t)}
          </span>
          <span>Elapsed ${rv(t.elapsed_seconds)}</span>
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
  `}function us({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return s`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?s`<${F} timestamp=${t.created_at} />`:s`<span>-</span>`}
        ${t.assignee?s`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function pv(){const{todo:t,inProgress:e,done:n}=Uo.value;return s`
    <${w} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?s`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>s`<${us} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?s`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>s`<${us} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?s`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>s`<${us} key=${a.id} task=${a} />`)}
          ${n.length>20?s`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function mv(){const t=sv.value,e=iv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,i=Cn.value.filter(l=>l.status==="active").length,o=qs.value,r=o==="idle"?"No loop running":o==="error"?js.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${i}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${li.value.length}</div>
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
            <button class="control-btn ghost" onClick=${Tn} disabled=${Le.value}>
              ${Le.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${je} disabled=${Pe.value}>
              ${Pe.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Tn(),je()}}
              disabled=${Le.value||Pe.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${go} label="Goals" timestamp=${Ko.value} source="masc_goal_list" />
          <${go}
            label="MDAL loops"
            timestamp=${Ho.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section">
        <${dv} />
        <${cv} />
      <//>

      ${Le.value&&Cn.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:li.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${ds} horizon="short" items=${t.short??[]} />
              <${ds} horizon="mid" items=${t.mid??[]} />
              <${ds} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section">
        ${Pe.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?s`
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
                  ${e.map(l=>s`<${uv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${pv} />
    </div>
  `}const Ne=f(""),ps=f("ability_check"),ms=f("10"),vs=f("12"),Un=f(""),Bn=f("idle"),Yt=f(""),Wn=f("keeper-late"),fs=f("player"),gs=f(""),St=f("idle"),_s=f(null),Gn=f(""),$s=f(""),hs=f("player"),ys=f(""),bs=f(""),ks=f(""),$n=f("20"),xs=f("20"),Ss=f(""),Jn=f("idle"),ci=f(null),Dr=f("overview"),As=f("all"),Cs=f("all"),ws=f("all"),vv=12e4,Va=f(null),_o=f(Date.now());function fv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function gv(t,e){return e>0?Math.round(t/e*100):0}const _v={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},$v={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Vn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function hv(t){const e=t.trim().toLowerCase();return _v[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function yv(t){const e=t.trim().toLowerCase();return $v[e]??"상황에 따라 선택되는 전술 액션입니다."}function ee(t){return typeof t=="object"&&t!==null}function _t(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Mt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const bv=new Set(["str","dex","con","int","wis","cha"]);function kv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(i){throw new Error(`능력치 JSON 파싱 실패: ${i instanceof Error?i.message:"invalid json"}`)}if(!ee(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([i,o])=>{const r=i.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function xv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt($n.value.trim(),10);Number.isFinite(a)&&a>n&&($n.value=String(n))}function di(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Sv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Av(t){Dr.value=t}function Er(t){const e=Va.value;return e==null||e<=t}function Cv(t){const e=Va.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Oa(){Va.value=null}function Ir(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function wv(t,e){Ir(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Va.value=Date.now()+vv,C("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function oa(t){return Er(t)?(C("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ui(t,e,n){return Ir([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Tv({hp:t,max:e}){const n=gv(t,e),a=fv(t,e);return s`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Nv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return s`
    <div class="trpg-actor-stats">
      ${e.map(n=>s`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Rv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return s`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Mr({actor:t}){var p,_,m,d;const e=(p=t.archetype)==null?void 0:p.trim(),n=(_=t.persona)==null?void 0:_.trim(),a=(m=t.portrait)==null?void 0:m.trim(),i=(d=t.background)==null?void 0:d.trim(),o=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([c,g])=>Number.isFinite(g)).filter(([c])=>!bv.has(c.toLowerCase()));return s`
    <div class="trpg-actor">
      ${a?s`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${c=>{const g=c.target;g&&(g.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Lt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Rv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?s`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?s`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Tv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Nv} stats=${t.stats} />
          </div>
        `:null}
      ${e?s`<div class="trpg-actor-meta">Archetype: ${Vn(e)}</div>`:null}
      ${i?s`<div class="trpg-actor-meta">Background: ${i}</div>`:null}
      ${n?s`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([c,g])=>s`
                <span class="trpg-custom-stat-chip">${Vn(c)} ${g}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(c=>s`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Vn(c)}</span>
                  <span class="trpg-annot-desc">${hv(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(c=>s`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Vn(c)}</span>
                  <span class="trpg-annot-desc">${yv(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Lv({mapStr:t}){return s`<pre class="trpg-map">${t}</pre>`}function Or({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?s`<div class="empty-state" style="font-size:13px">${e}</div>`:s`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var i;return s`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Sv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${di(n)}</strong>
            ${" "}
          ${n.dice_roll?s`<span class="trpg-dice">[${n.dice_roll.notation}: ${(i=n.dice_roll.rolls)==null?void 0:i.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Pv({events:t}){const e="__none__",n=As.value,a=Cs.value,i=ws.value,o=Array.from(new Set(t.map(di).map(d=>d.trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),l=t.some(d=>(d.type??"").trim()===""),p=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,c)=>d.localeCompare(c)),_=t.some(d=>(d.phase??"").trim()===""),m=t.filter(d=>{if(n!=="all"&&di(d)!==n)return!1;const c=(d.type??"").trim(),g=(d.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(i===e){if(g!=="")return!1}else if(i!=="all"&&g!==i)return!1;return!0});return s`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${d=>{As.value=d.target.value}}>
          <option value="all">all</option>
          ${o.map(d=>s`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${d=>{Cs.value=d.target.value}}>
          <option value="all">all</option>
          ${l?s`<option value=${e}>(none)</option>`:null}
          ${r.map(d=>s`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${i} onChange=${d=>{ws.value=d.target.value}}>
          <option value="all">all</option>
          ${_?s`<option value=${e}>(none)</option>`:null}
          ${p.map(d=>s`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{As.value="all",Cs.value="all",ws.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Or} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Dv({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",i=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return s`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?s`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${i?s`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${i}</div>`:null}
    </div>
  `}function zr({state:t}){const e=t.history??[];return e.length===0?null:s`
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
  `}function Ev({state:t,nowMs:e}){var _;const n=Ut.value||((_=t.session)==null?void 0:_.room)||"",a=Bn.value,i=t.party??[];if(!i.find(m=>m.id===Ne.value)&&i.length>0){const m=i[0];m&&(Ne.value=m.id)}const r=async()=>{var d,c;if(!n){C("Room ID가 비어 있습니다.","error");return}if(!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ui("라운드 실행",n,m)){Bn.value="running";try{const g=await nc(n);ci.value=g,Bn.value="ok";const y=ee(g.summary)?g.summary:null,S=y?En(y,"advanced",!1):!1,T=y?_t(y,"progress_reason",""):"";C(S?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,S?"success":"warning"),jt()}catch(g){ci.value=null,Bn.value="error";const y=g instanceof Error?g.message:"라운드 실행에 실패했습니다.";C(y,"error")}finally{Oa()}}},l=async()=>{var d,c;if(!n||!oa(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ui("턴 강제 진행",n,m))try{await ic(n),C("턴을 다음 단계로 이동했습니다.","success"),jt()}catch{C("턴 이동에 실패했습니다.","error")}finally{Oa()}},p=async()=>{if(!n||!oa(e))return;const m=Ne.value.trim();if(!m){C("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(ms.value,10),c=Number.parseInt(vs.value,10);if(Number.isNaN(d)||Number.isNaN(c)){C("stat/dc는 숫자여야 합니다.","warning");return}const g=Number.parseInt(Un.value,10),y=Un.value.trim()===""||Number.isNaN(g)?void 0:g;try{await sc({roomId:n,actorId:m,action:ps.value.trim()||"ability_check",statValue:d,dc:c,rawD20:y}),C("주사위 판정을 기록했습니다.","success"),jt()}catch{C("주사위 판정 기록에 실패했습니다.","error")}};return s`
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
            value=${Ne.value}
            onChange=${m=>{Ne.value=m.target.value}}
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
              value=${ps.value}
              onInput=${m=>{ps.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${ms.value}
              onInput=${m=>{ms.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${vs.value}
              onInput=${m=>{vs.value=m.target.value}}
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
  `}function Iv({state:t}){var i;const e=Ut.value||((i=t.session)==null?void 0:i.room)||"",n=Jn.value,a=async()=>{if(!e){C("Room ID가 비어 있습니다.","warning");return}const o=Gn.value.trim(),r=$s.value.trim();if(!r&&!o){C("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt($n.value.trim(),10),p=Number.parseInt(xs.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(l)?Math.max(0,Math.min(_,l)):_;let d={};try{d=kv(Ss.value)}catch(c){C(c instanceof Error?c.message:"능력치 JSON 오류","error");return}Jn.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,g=await oc(e,{actor_id:o||void 0,name:r||void 0,role:hs.value,idempotencyKey:c,portrait:bs.value.trim()||void 0,background:ks.value.trim()||void 0,hp:m,max_hp:_,alive:m>0,stats:Object.keys(d).length>0?d:void 0}),y=typeof g.actor_id=="string"?g.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const S=ys.value.trim();S&&await rc(e,y,S),Ne.value=y,Yt.value=y,o||(Gn.value=""),Jn.value="ok",C(`Actor 생성 완료: ${y}`,"success"),await jt()}catch(c){Jn.value="error",C(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${$s.value}
            onInput=${o=>{$s.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${hs.value}
            onChange=${o=>{hs.value=o.target.value}}
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
            value=${ys.value}
            onInput=${o=>{ys.value=o.target.value}}
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
              value=${bs.value}
              onInput=${o=>{bs.value=o.target.value}}
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
              value=${xs.value}
              onInput=${o=>{const r=o.target.value;xs.value=r,xv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ks.value}
              onInput=${o=>{ks.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ss.value}
              onInput=${o=>{Ss.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?s`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Mv({state:t,nowMs:e}){var c;const n=Ut.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,i=_s.value,o=ee(i)?i:null,r=(t.party??[]).filter(g=>g.role!=="dm"),l=Yt.value.trim(),p=r.some(g=>g.id===l),_=p?l:l?"__manual__":"",m=async()=>{const g=Yt.value.trim(),y=Wn.value.trim();if(!n||!g){C("Room/Actor가 필요합니다.","warning");return}St.value="checking";try{const S=await lc(n,g,y||void 0);_s.value=S,St.value="ok",C("참가 가능 여부를 갱신했습니다.","success")}catch(S){St.value="error";const T=S instanceof Error?S.message:"참가 가능 여부 확인에 실패했습니다.";C(T,"error")}},d=async()=>{var P,K;const g=Yt.value.trim(),y=Wn.value.trim(),S=gs.value.trim();if(!n||!g||!y){C("Room/Actor/Keeper가 필요합니다.","warning");return}if(!oa(e))return;const T=((P=t.current_round)==null?void 0:P.phase)??((K=t.session)==null?void 0:K.status)??"unknown";if(ui("Mid-Join 승인 요청",n,T)){St.value="requesting";try{const I=await cc({room_id:n,actor_id:g,keeper_name:y,role:fs.value,...S?{name:S}:{}});_s.value=I;const N=ee(I)?En(I,"granted",!1):!1,R=ee(I)?_t(I,"reason_code",""):"";N?C("Mid-Join이 승인되었습니다.","success"):C(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),St.value=N?"ok":"error",jt()}catch(I){St.value="error";const N=I instanceof Error?I.message:"Mid-Join 요청에 실패했습니다.";C(N,"error")}finally{Oa()}}};return s`
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
            onChange=${g=>{const y=g.target.value;if(y==="__manual__"){(p||!l)&&(Yt.value="");return}Yt.value=y}}
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
            value=${Wn.value}
            onInput=${g=>{Wn.value=g.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${fs.value}
            onChange=${g=>{fs.value=g.target.value}}
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
            value=${gs.value}
            onInput=${g=>{gs.value=g.target.value}}
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
  `}function qr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?s`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:s`
    <div class="trpg-round-list">
      ${e.map(n=>s`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function jr({state:t}){var n;const e=t.current_round;return e?s`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?s`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Fr(){const t=ci.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ee(e)?e:null,i=(Array.isArray(t.statuses)?t.statuses:[]).filter(ee).slice(-8),o=t.canon_check,r=ee(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],_=n?En(n,"advanced",!1):!1,m=n?_t(n,"progress_reason",""):"",d=n?_t(n,"progress_detail",""):"",c=n?Mt(n,"player_successes",0):0,g=n?Mt(n,"player_required_successes",0):0,y=n?En(n,"dm_success",!1):!1,S=n?Mt(n,"timeouts",0):0,T=n?Mt(n,"unavailable",0):0,P=n?Mt(n,"reprompts",0):0,K=n?Mt(n,"npc_attacks",0):0,I=n?Mt(n,"keeper_timeout_sec",0):0,N=n?Mt(n,"roll_audit_count",0):0;return s`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${c}/${g}
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
  `}function Ov({state:t,nowMs:e}){var r,l,p;const n=Ut.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",i=Er(e),o=Cv(e);return s`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${i?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${i?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${i?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${i?s`<button class="trpg-run-btn recommend" onClick=${()=>wv(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{Oa(),C("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function zv({active:t}){return s`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>s`
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
  `}function qv({state:t}){const e=t.party??[],n=t.story_log??[];return s`
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
          <${Or} events=${n.slice(-20)} />
        <//>

        ${t.map?s`
            <${w} title="맵" style="margin-top:16px;">
              <${Lv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드">
          <${jr} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;">
          <${qr} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>s`<${Mr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?s`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${zr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function jv({state:t}){const e=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${Pv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과">
          <${Fr} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;">
          <${jr} state=${t} />
        <//>
      </div>
    </div>
  `}function Fv({state:t,nowMs:e}){const n=t.party??[];return s`
    <div>
      <${Ov} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널">
            <${Ev} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${Iv} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${Mv} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${Fr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;">
            <${qr} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>s`<${Mr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?s`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${zr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Kv(){var l,p,_,m,d;const t=jo.value,e=Ks.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{_o.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return s`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return s`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>jt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],i=t.outcome,o=Dr.value,r=_o.value;return s`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ut.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>jt()}>새로고침</button>
      </div>

      <${Dv} outcome=${i} />

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

      <${zv} active=${o} />

      ${o==="overview"?s`<${qv} state=${t} />`:o==="timeline"?s`<${jv} state=${t} />`:s`<${Fv} state=${t} nowMs=${r} />`}
    </div>
  `}const Ri="masc_dashboard_agent_name";function Hv(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Ri);return e??n??"dashboard"}const ht=f(Hv()),hn=f(""),yn=f(""),za=f(""),Kr=f(null),qa=f(null),bn=f(!1),De=f(!1),kn=f(!1),xn=f(!1),ja=f(!1),Fa=f(!1),Qa=f(!1);function Ka(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ra(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Hr(t){return!t||t.length===0?"none":t.join(", ")}function Uv(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Ka(t.quiet_start)}-${Ka(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ra(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${ra(t.interval_s)}.`:`Lodge ticks every ${ra(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ge(){qe();try{await ne()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Li(t){const e=t.trim();ht.value=e,e&&localStorage.setItem(Ri,e)}function Bv(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function pi(){const t=ht.value.trim();if(t){kn.value=!0;try{const e=await uc(t),n=Bv(e);n&&Li(n),Qa.value=!0,await Ge(),C(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";C(n,"error")}finally{kn.value=!1}}}async function Wv(){const t=ht.value.trim();if(t){xn.value=!0;try{await Mo(t),Qa.value=!1,await Ge(),C(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";C(n,"error")}finally{xn.value=!1}}}async function Gv(){const t=ht.value.trim();if(t)try{await Mo(t)}catch{}localStorage.removeItem(Ri),Li("dashboard"),Qa.value=!1,await pi()}async function Jv(){const t=ht.value.trim();if(t){ja.value=!0;try{await pc(t),await Ge(),C("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";C(n,"error")}finally{ja.value=!1}}}async function $o(){const t=ht.value.trim(),e=hn.value.trim();if(!(!t||!e)){bn.value=!0;try{await Io(t,e),hn.value="",await Ge(),C("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";C(a,"error")}finally{bn.value=!1}}}async function Vv(){const t=yn.value.trim(),e=za.value.trim()||"Created from dashboard";if(t){De.value=!0;try{await dc(t,e,1),yn.value="",za.value="",await Ge(),C("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";C(a,"error")}finally{De.value=!1}}}async function ho(){const t=ht.value.trim()||"dashboard";Fa.value=!0,qa.value=null;try{const e=await On({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=gi(e.result);Kr.value=n,await Ge(),n!=null&&n.skipped_reason?C(n.skipped_reason,"warning"):C(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";qa.value=n,C(n,"error")}finally{Fa.value=!1}}function Qv({runtime:t}){var i,o;const e=Kr.value??(t==null?void 0:t.last_tick_result)??null;if(qa.value)return s`<div class="control-result-box is-error">${qa.value}</div>`;if(!e)return s`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((i=e.skipped_rows)==null?void 0:i.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?s`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Hr(e.acted_names)}</div>
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
  `}function Yv(t){return t.find(n=>n.name===sn.value)??t[0]??null}function Xv(){var a,i;const t=Jt.value,e=((a=se.value)==null?void 0:a.lodge)??null,n=Yv(t);return rt(()=>{pi()},[]),rt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!sn.value&&o){Yn(o);return}sn.value&&!t.some(l=>l.name===sn.value)&&Yn(o)},[t.map(o=>o.name).join("|")]),s`
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
          onInput=${o=>Li(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{pi()}}
            disabled=${kn.value||ht.value.trim()===""}
          >
            ${kn.value?"Joining...":Qa.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Wv()}}
            disabled=${xn.value||ht.value.trim()===""}
          >
            ${xn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Gv()}}
            disabled=${kn.value||xn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Jv()}}
            disabled=${ja.value||ht.value.trim()===""}
          >
            ${ja.value?"Pinging...":"Heartbeat"}
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
            onKeyDown=${o=>{o.key==="Enter"&&$o()}}
            disabled=${bn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{$o()}}
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
          ${t.length===0?s`<option value="">No keepers available</option>`:t.map(o=>s`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${nr} keeper=${n} />
        <${sr}
          actor=${ht.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{ho()}}
        />
        <${ar}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${Uv(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${ra(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Ka(e==null?void 0:e.quiet_start)}-${Ka(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Hr((i=e==null?void 0:e.last_tick_result)==null?void 0:i.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?s`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{ho()}}
            disabled=${Fa.value}
          >
            ${Fa.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${Qv} runtime=${e} />
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
          disabled=${De.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${za.value}
          onInput=${o=>{za.value=o.target.value}}
          disabled=${De.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{Vv()}}
          disabled=${De.value||yn.value.trim()===""}
        >
          ${De.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const yo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],mi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],bo="masc_dashboard_quick_actions_open";function Zv(){const t=Ft.value;return s`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${In.value} events</span>
    </div>
  `}function tf(){const t=nt.value.tab,e=Ft.value,n=mi.find(r=>r.id===t),a=yo.find(r=>r.id===(n==null?void 0:n.group)),[i,o]=Ha(()=>{const r=localStorage.getItem(bo);return r!=="0"});return rt(()=>{localStorage.setItem(bo,i?"1":"0")},[i]),s`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?s`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${yo.map(r=>s`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${mi.filter(l=>l.group===r.id).map(l=>s`
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
            onClick=${()=>{ne(),t==="command"&&(fe(),$e()),t==="ops"&&He(),t==="board"&&qt(),t==="trpg"&&jt(),t==="goals"&&(Tn(),je())}}
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
        ${i?s`<div class="rail-fold-body"><${Xv} /></div>`:s`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function ef(){switch(nt.value.tab){case"command":return s`<${qp} />`;case"overview":return s`<${to} />`;case"ops":return s`<${rm} />`;case"board":return s`<${Am} />`;case"agents":return s`<${av} />`;case"goals":return s`<${mv} />`;case"trpg":return s`<${Kv} />`;default:return s`<${to} />`}}function nf(){rt(()=>{tl(),No(),ne();const n=id();return od(),()=>{ll(),n(),rd()}},[]),rt(()=>{const n=setInterval(()=>{const a=nt.value.tab;a==="command"?(fe(),$e()):a==="ops"?He():a==="board"?qt():a==="trpg"?jt():a==="goals"&&(Tn(),je())},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=nt.value.tab;n==="command"&&(fe(),$e()),n==="ops"&&He(),n==="board"&&qt(),n==="trpg"&&jt(),n==="goals"&&(Tn(),je())},[nt.value.tab]);const t=nt.value.tab,e=mi.find(n=>n.id===t);return s`
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
            onClick=${qd}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${Zv} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${tf} />
        <main class="dashboard-main">
          ${Fs.value&&!Ft.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${ef} />`}
        </main>
      </div>

      ${Fe.value?s`
        <div class="activity-panel-backdrop" onClick=${Vi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${Vi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Wm} />
          </div>
        </aside>
      `:null}

      <${Od} />
      <${gd} />
      <${ud} />
    </div>
  `}const ko=document.getElementById("app");ko&&Jr(s`<${nf} />`,ko);export{Jd as _};
