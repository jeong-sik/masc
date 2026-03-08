var xr=Object.defineProperty;var Sr=(t,e,n)=>e in t?xr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var he=(t,e,n)=>Sr(t,typeof e!="symbol"?e+"":e,n);import{e as Ar,_ as wr,c as f,b as xt,y as bt,d as ni,A as Tr,G as Cr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const i of document.querySelectorAll('link[rel="modulepreload"]'))a(i);new MutationObserver(i=>{for(const o of i)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(i){const o={};return i.integrity&&(o.integrity=i.integrity),i.referrerPolicy&&(o.referrerPolicy=i.referrerPolicy),i.crossOrigin==="use-credentials"?o.credentials="include":i.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(i){if(i.ep)return;i.ep=!0;const o=n(i);fetch(i.href,o)}})();var s=Ar.bind(wr);const Nr=["command","overview","board","goals","agents","ops","trpg"],ro={tab:"overview",params:{},postId:null},Rr={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function yi(t){return!!t&&Nr.includes(t)}function bi(t){if(t)return Rr[t]??t}function gs(t){try{return decodeURIComponent(t)}catch{return t}}function _s(t){const e={};return t&&new URLSearchParams(t).forEach((a,i)=>{e[i]=a}),e}function Lr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function lo(t,e){const n=bi(t[0]),a=bi(e.tab),i=yi(n)?n:yi(a)?a:"overview";let o=null;return i==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=gs(t[2]):t[0]==="post"&&t[1]&&(o=gs(t[1]))),{tab:i,params:e,postId:o}}function Zn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ro;const n=gs(e);let a=n,i;if(n.startsWith("?"))a="",i=n.slice(1);else{const d=n.indexOf("?");d>=0&&(a=n.slice(0,d),i=n.slice(d+1))}!i&&a.includes("=")&&!a.includes("/")&&(i=a,a="");const o=_s(i),r=Lr(a);return lo(r,o)}function Dr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...ro,params:_s(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const i=_s(e.replace(/^\?/,""));return lo(a,i)}function co(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([i])=>i!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Nt=f(Zn(window.location.hash));window.addEventListener("hashchange",()=>{Nt.value=Zn(window.location.hash)});function Mt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=co(n)}function Pr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Ir(){if(window.location.hash&&window.location.hash!=="#"){Nt.value=Zn(window.location.hash);return}const t=Dr(window.location.pathname,window.location.search);if(t){Nt.value=t;const e=co(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Nt.value=Zn(window.location.hash)}const ki="masc_dashboard_sse_session_id",Er=1e3,Mr=15e3,jt=f(!1),Tn=f(0),uo=f(null),ta=f([]);function Or(){let t=sessionStorage.getItem(ki);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ki,t)),t}const zr=200;function qr(t,e,n="system",a={}){const i={agent:t,text:e,timestamp:Date.now(),kind:n,...a};ta.value=[i,...ta.value].slice(0,zr)}function $s(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function xi(t,e){const n=$s(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function wt(t,e,n,a,i={}){qr(t,e,n,{eventType:a,...i})}let Et=null,Re=null,hs=0;function po(){Re&&(clearTimeout(Re),Re=null)}function jr(){if(Re)return;hs++;const t=Math.min(hs,5),e=Math.min(Mr,Er*Math.pow(2,t));Re=setTimeout(()=>{Re=null,mo()},e)}function mo(){po(),Et&&(Et.close(),Et=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Or());const i=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(i);Et=o,o.onopen=()=>{Et===o&&(hs=0,jt.value=!0)},o.onerror=()=>{Et===o&&(jt.value=!1,o.close(),Et=null,jr())},o.onmessage=r=>{try{const d=JSON.parse(r.data);Tn.value++,uo.value=d,Fr(d)}catch{}}}function Fr(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":wt(n,"Joined","system","agent_joined");break;case"agent_left":wt(n,"Left","system","agent_left");break;case"broadcast":wt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":wt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":wt(n,xi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:$s(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":wt(n,xi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:$s(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":wt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":wt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":wt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":wt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:wt(n,e,"system","unknown")}}function Kr(){po(),Et&&(Et.close(),Et=null),jt.value=!1}function vo(){return new URLSearchParams(window.location.search)}function fo(){const t=vo(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function go(){return{...fo(),"Content-Type":"application/json"}}const Hr=15e3,ai=3e4,Ur=6e4,Si=new Set([408,425,429,500,502,503,504]);class Cn extends Error{constructor(n){const a=n.method.toUpperCase(),i=n.timeout===!0,o=i?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);he(this,"method");he(this,"path");he(this,"status");he(this,"statusText");he(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=i}}async function si(t,e,n){const a=new AbortController,i=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Cn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(i)}}function Br(){var e,n;const t=vo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Y(t){const e=await si(t,{headers:fo()},Hr);if(!e.ok)throw new Cn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Wr(t){return new Promise(e=>setTimeout(e,t))}function Gr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Jr(t){if(t instanceof Cn)return t.timeout||typeof t.status=="number"&&Si.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Gr(t.message);return e!==null&&Si.has(e)}async function Fe(t,e,n=2){let a=0;for(;;)try{return await e()}catch(i){if(!Jr(i)||a>=n)throw i;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,i),await Wr(o),a+=1}}async function Ft(t,e,n,a=ai){const i=await si(t,{method:"POST",headers:{...go(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Cn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.json()}async function Vr(t,e,n,a=ai){const i=await si(t,{method:"POST",headers:{...go(),...n??{}},body:JSON.stringify(e)},a);if(!i.ok)throw new Cn({method:"POST",path:t,status:i.status,statusText:i.statusText});return i.text()}function Qr(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Yr(t){var e,n,a,i,o,r,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((i=(a=t.result.content)==null?void 0:a[0])==null?void 0:i.text)??"MCP tool call failed";throw new Error(p)}return((d=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:d.text)??""}async function _t(t,e){const n=await Vr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ur),a=Qr(n);return Yr(a)}function Xr(t="compact"){return Y(`/api/v1/dashboard?mode=${t}`)}function Zr(){return Y("/api/v1/agents?limit=100")}function tl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),Y(`/api/v1/tasks?${e}`)}function el(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),Y(`/api/v1/messages?${e}`)}function nl(t={}){return Fe("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return Y(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function al(){return Y("/api/v1/operator")}function sl(){return Y("/api/v1/command-plane")}function il(){return Y("/api/v1/command-plane/summary")}function ol(){return Y("/api/v1/command-plane/help")}function rl(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return Y(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function ll(t,e){return Ft(t,e)}function cl(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ai}}function Nn(t){return Ft("/api/v1/operator/action",t,void 0,cl(t))}function dl(t,e){return Ft("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const ul=new Set(["lodge-system","team-session"]);function Ee(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function pl(t){return ul.has(t.trim().toLowerCase())}function ml(t){return t.filter(e=>!pl(e.author))}function vl(t){var i;const e=t.trim(),a=((i=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:i.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function _o(t){if(!M(t))return null;const e=$(t.id,"").trim(),n=$(t.author,"").trim(),a=$(t.content,"").trim();if(!e||!n)return null;const i=q(t.score,0),o=q(t.votes_up,0),r=q(t.votes_down,0),d=q(t.votes,i||o-r),p=q(t.comment_count,q(t.reply_count,0)),_=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(M(y)){const C=$(y.name,"").trim();if(C)return C}return $(t.flair_name,"").trim()||void 0})(),m=$(t.created_at_iso,"").trim()||Ee(t.created_at),c=$(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ee(t.updated_at):m),g=$(t.title,"").trim()||vl(a);return{id:e,author:n,title:g,content:a,tags:[],votes:d,vote_balance:i,comment_count:p,created_at:m,updated_at:c,flair:_,hearth_count:q(t.hearth_count,0)}}function fl(t){if(!M(t))return null;const e=$(t.id,"").trim(),n=$(t.post_id,"").trim(),a=$(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:$(t.content,""),created_at:Ee(t.created_at)}}async function gl(t,e){return Fe("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),i=await Y(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(i.posts)?i.posts.map(_o).filter(d=>d!==null):[];return{posts:e!=null&&e.excludeSystem?ml(o):o}})}async function _l(t){return Fe("fetchBoardPost",async()=>{const e=await Y(`/api/v1/board/${t}?format=flat`),n=M(e.post)?e.post:e,a=_o(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(fl).filter(r=>r!==null);return{...a,comments:o}})}function $o(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Br()})}function $l(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function hl(t){const e=$(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function at(...t){for(const e of t){const n=$(e,"");if(n.trim())return n.trim()}return""}function Ai(t){const e=hl(at(t.outcome,t.result,t.result_code));if(!e)return;const n=at(t.reason,t.reason_code,t.description,t.detail),a=at(t.summary,t.summary_ko,t.summary_en,t.note),i=at(t.details,t.details_text,t.text,t.note),o=at(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=at(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=at(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(l=>{if(typeof l=="string")return l.trim();if(M(l)){const g=$(l.summary,"").trim();if(g)return g;const y=$(l.text,"").trim();if(y)return y;const x=$(l.type,"").trim();return x||$(l.event_id,"").trim()}return""}).filter(l=>l.length>0):[]})(),_=(()=>{const c=q(t.turn,Number.NaN);if(Number.isFinite(c))return c;const l=q(t.turn_number,Number.NaN);if(Number.isFinite(l))return l;const g=q(t.current_turn,Number.NaN);if(Number.isFinite(g))return g;const y=q(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=at(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:i||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:d||void 0,turn:_,phase:m||void 0}}function yl(t,e){const n=M(t.state)?t.state:{};if($(n.status,"active").toLowerCase()!=="ended")return;const i=[...e].reverse().find(r=>M(r)?$(r.type,"")==="session.outcome":!1),o=M(n.session_outcome)?n.session_outcome:{};if(M(o)&&Object.keys(o).length>0){const r=Ai(o);if(r)return r}if(M(i))return Ai(M(i.payload)?i.payload:{})}function M(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function q(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function bl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ys(t,e=!1){return typeof t=="boolean"?t:e}function Ge(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(M(e)){const n=$(e.name,"").trim(),a=$(e.id,"").trim(),i=$(e.skill,"").trim();return n||a||i}return""}).filter(e=>e.length>0):[]}function kl(t){const e={};if(!M(t)&&!Array.isArray(t))return e;if(M(t))return Object.entries(t).forEach(([n,a])=>{const i=n.trim(),o=$(a,"").trim();!i||!o||(e[i]=o)}),e;for(const n of t){if(!M(n))continue;const a=at(n.to,n.target,n.actor_id,n.name,n.id),i=at(n.relationship,n.relation,n.type,n.kind);!a||!i||(e[a]=i)}return e}function xl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ht(t,e,n,a=0){const i=t[e];if(typeof i=="number"&&Number.isFinite(i))return i;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const Sl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Al(t){const e=M(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,i])=>{const o=a.trim();o&&(Sl.has(o.toLowerCase())||typeof i=="number"&&Number.isFinite(i)&&(n[o]=i))}),n}function wl(t,e){if(t!=="dice.rolled")return;const n=q(e.raw_d20,0),a=q(e.total,0),i=q(e.bonus,0),o=$(e.action,"roll"),r=q(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:i}}function Tl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Cl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Nl(t,e,n,a){const i=n||e||$(a.actor_id,"")||$(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=$(a.proposed_action,$(a.reply,""));return o?`${i||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=$(a.reply,$(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return $(a.reply,$(a.content,$(a.text,"Narration")));case"dice.rolled":{const o=$(a.action,"roll"),r=q(a.total,0),d=q(a.dc,0),p=$(a.label,""),_=i||"actor",m=d>0?` vs DC ${d}`:"",c=p?` (${p})`:"";return`${_} ${o}: ${r}${m}${c}`}case"turn.started":return`Turn ${q(a.turn,1)} started`;case"phase.changed":return`Phase: ${$(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(a.name,M(a.actor)?$(a.actor.name,i||"unknown"):i||"unknown")}`;case"actor.claimed":return`${$(a.keeper_name,$(a.keeper,"keeper"))} claimed ${i||"actor"}`;case"actor.released":return`${$(a.keeper_name,$(a.keeper,"keeper"))} released ${i||"actor"}`;case"join.window.opened":return`Join window opened (turn ${q(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${q(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${i||$(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${i||$(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${$(a.reason_code,"unknown")}`;case"memory.signal":{const o=M(a.entity_refs)?a.entity_refs:{},r=$(o.requested_tier,""),d=$(o.effective_tier,""),p=ys(o.guardrail_applied,!1),_=$(a.summary_en,$(a.summary_ko,"Memory signal"));if(!r&&!d)return _;const m=r&&d?`${r}->${d}`:d||r;return`${_} [${m}${p?" (guardrail)":""}]`}case"world.event":{if($(a.event_type,"")==="canon.check"){const r=$(a.status,"unknown"),d=$(a.contract_id,"n/a");return`Canon ${r}: ${d}`}return $(a.description,$(a.summary,"World event"))}case"combat.attack":return $(a.summary,$(a.result,"Attack resolved"));case"combat.defense":return $(a.summary,$(a.result,"Defense resolved"));case"session.outcome":return $(a.summary,$(a.outcome,"Session ended"));default:{const o=Tl(a);return o?`${t}: ${o}`:t}}}function Rl(t,e){const n=M(t)?t:{},a=$(n.type,"event"),i=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=$(n.actor_name,"").trim()||e[i]||$(M(n.payload)?n.payload.actor_name:"",""),r=M(n.payload)?n.payload:{},d=$(n.ts,$(n.timestamp,new Date().toISOString())),p=$(n.phase,$(r.phase,"")),_=$(n.category,"");return{type:a,actor:o||i||$(r.actor_name,""),actor_id:i||$(r.actor_id,""),actor_name:o,seq:n.seq,room_id:$(n.room_id,""),phase:p||void 0,category:_||Cl(a),visibility:$(n.visibility,$(r.visibility,"public")),event_id:$(n.event_id,""),content:Nl(a,i,o,r),dice_roll:wl(a,r),timestamp:d}}function Ll(t,e,n){var St,At;const a=$(t.room_id,"")||n||"default",i=M(t.state)?t.state:{},o=M(i.party)?i.party:{},r=M(i.actor_control)?i.actor_control:{},d=M(i.join_gate)?i.join_gate:{},p=M(i.contribution_ledger)?i.contribution_ledger:{},_=Object.entries(o).map(([B,X])=>{const k=M(X)?X:{},Lt=ht(k,"max_hp",void 0,10),Jt=ht(k,"hp",void 0,Lt),ie=ht(k,"max_mp",void 0,0),oe=ht(k,"mp",void 0,0),I=ht(k,"level",void 0,1),Dt=ht(k,"xp",void 0,0),re=ys(k.alive,Jt>0),Be=r[B],We=typeof Be=="string"?Be:void 0,v=xl(k.role,B,We),N=bl(k.generation),j=at(k.joined_at,k.joinedAt,k.started_at,k.startedAt),Z=at(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),z=at(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),dt=at(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),G=at(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:B,name:$(k.name,B),role:v,keeper:We,archetype:$(k.archetype,""),persona:$(k.persona,""),portrait:$(k.portrait,"")||void 0,background:$(k.background,"")||void 0,traits:Ge(k.traits),skills:Ge(k.skills),stats_raw:Al(k),status:re?"active":"dead",generation:N,joined_at:j||void 0,claimed_at:Z||void 0,last_seen:z||void 0,scene:dt||void 0,location:G||void 0,inventory:Ge(k.inventory),notes:Ge(k.notes),relationships:kl(k.relationships),stats:{hp:Jt,max_hp:Lt,mp:oe,max_mp:ie,level:I,xp:Dt,strength:ht(k,"strength","str",10),dexterity:ht(k,"dexterity","dex",10),constitution:ht(k,"constitution","con",10),intelligence:ht(k,"intelligence","int",10),wisdom:ht(k,"wisdom","wis",10),charisma:ht(k,"charisma","cha",10)}}}),m=_.filter(B=>B.status!=="dead"),c=yl(t,e),l={phase_open:ys(d.phase_open,!0),min_points:q(d.min_points,3),window:$(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},g=Object.entries(p).map(([B,X])=>{const k=M(X)?X:{};return{actor_id:B,score:q(k.score,0),last_reason:$(k.last_reason,"")||null,reasons:Ge(k.reasons)}}),y=_.reduce((B,X)=>(B[X.id]=X.name,B),{}),x=e.map(B=>Rl(B,y)),C=q(i.turn,1),E=$(i.phase,"round"),L=$(i.map,""),O=M(i.world)?i.world:{},R=L||$(O.ascii_map,$(O.map,"")),D=x.filter((B,X)=>{const k=e[X];if(!M(k))return!1;const Lt=M(k.payload)?k.payload:{};return q(Lt.turn,-1)===C}),ut=(D.length>0?D:x).slice(-12),ct=$(i.status,"active");return{session:{id:a,room:a,status:ct==="ended"?"ended":ct==="paused"?"paused":"active",round:C,actors:m,created_at:((St=x[0])==null?void 0:St.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:E,events:ut,timestamp:((At=x[x.length-1])==null?void 0:At.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:l,contribution_ledger:g,outcome:c,party:m,story_log:x,history:[]}}async function Dl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Y(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Pl(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Y(`/api/v1/trpg/state${e}`),Dl(t)]);return Ll(n,a,t)}function Il(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function El(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ml(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function Ol(t,e){const n=El();return Ft("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function zl(t,e){var i;const n=(i=e.idempotencyKey)==null?void 0:i.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ft("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function ql(t,e,n){return Ft("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function jl(t,e,n){const a=await _t("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Fl(t){const e=await _t("trpg.mid_join.request",t);return JSON.parse(e)}async function ho(t,e){await _t("masc_broadcast",{agent_name:t,message:e})}async function Kl(t,e,n=1){await _t("masc_add_task",{title:t,description:e,priority:n})}async function Hl(t){return _t("masc_join",{agent_name:t})}async function yo(t){await _t("masc_leave",{agent_name:t})}async function Ul(t){await _t("masc_heartbeat",{agent_name:t})}async function Bl(t=40){return(await _t("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Wl(t,e=20){return _t("masc_task_history",{task_id:t,limit:e})}async function Gl(){return Fe("fetchDebates",async()=>{const t=await Y("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!M(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:$(e.status,"open"),argument_count:q(e.argument_count,0),created_at:Ee(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Jl(){return Fe("fetchCouncilSessions",async()=>{const t=await Y("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!M(e))return null;const n=$(e.id,"").trim(),a=$(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:$(e.initiator,"system"),votes:q(e.votes,0),quorum:q(e.quorum,0),state:$(e.state,"open"),created_at:Ee(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Vl(t){const e=await _t("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ql(t){return Fe("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Y(`/api/v1/council/debates/${e}/summary`);if(!M(n))return null;const a=$(n.id,"").trim();return a?{id:a,topic:$(n.topic,""),status:$(n.status,"open"),support_count:q(n.support_count,0),oppose_count:q(n.oppose_count,0),neutral_count:q(n.neutral_count,0),total_arguments:q(n.total_arguments,0),created_at:Ee(n.created_at_iso??n.created_at),summary_text:$(n.summary_text,"")}:null})}function Yl(t,e,n){return _t("masc_keeper_msg",{name:t,message:e})}async function Xl(){try{const t=await _t("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const tn=f(""),Ut=f({}),it=f({}),bs=f({}),ks=f({}),xs=f({}),Ss=f({}),Bt=f({});function nt(t,e,n){t.value={...t.value,[e]:n}}function Wt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function K(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Ct(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function we(t){return typeof t=="boolean"?t:void 0}function As(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ws(t){return Array.isArray(t)?t.map(e=>K(e)).filter(e=>!!e):[]}function Zl(t){var n;const e=(n=K(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function tc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ja(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Wt(a))continue;const i=K(a.name);if(!i)continue;const o=K(a[e]);e==="summary"?n.push({name:i,summary:o}):n.push({name:i,reason:o})}return n}function ec(t){if(!Wt(t))return null;const e=K(t.name);return e?{name:e,trigger:K(t.trigger),outcome:K(t.outcome),summary:K(t.summary),reason:K(t.reason)}:null}function nc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function ac(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function bo(t,e,n){return K(t)??ac(e,n)}function ko(t,e){return typeof t=="boolean"?t:e==="recover"}function ea(t){if(!Wt(t))return null;const e=K(t.health_state),n=K(t.next_action_path),a=K(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:K(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:As(t.last_reply_at),last_reply_preview:K(t.last_reply_preview)??null,last_error:K(t.last_error)??null,next_eligible_at_s:Ct(t.next_eligible_at_s)??null,recoverable:ko(t.recoverable,n),summary:bo(t.summary,e,K(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function ii(t){return Wt(t)?{hour:Ct(t.hour),checked:Ct(t.checked)??0,acted:Ct(t.acted)??0,acted_names:ws(t.acted_names),activity_report:K(t.activity_report),quiet_hours_overridden:we(t.quiet_hours_overridden),skipped_reason:K(t.skipped_reason),acted_rows:ja(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ja(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ja(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(ec).filter(e=>e!==null):[]}:null}function sc(t){return Wt(t)?{enabled:we(t.enabled)??!1,interval_s:Ct(t.interval_s)??0,quiet_start:Ct(t.quiet_start),quiet_end:Ct(t.quiet_end),quiet_active:we(t.quiet_active),use_planner:we(t.use_planner),delegate_llm:we(t.delegate_llm),agent_count:Ct(t.agent_count),agents:ws(t.agents),last_tick_ago_s:Ct(t.last_tick_ago_s)??null,last_tick_ago:K(t.last_tick_ago),total_ticks:Ct(t.total_ticks),total_checkins:Ct(t.total_checkins),last_skip_reason:K(t.last_skip_reason)??null,last_tick_result:ii(t.last_tick_result),active_self_heartbeats:ws(t.active_self_heartbeats)}:null}function ic(t){return Wt(t)?{status:t.status,diagnostic:ea(t.diagnostic)}:null}function oc(t){return Wt(t)?{recovered:we(t.recovered)??!1,skipped_reason:K(t.skipped_reason)??null,before:ea(t.before),after:ea(t.after),down:t.down,up:t.up}:null}function rc(t,e){var L,O;if(!(t!=null&&t.name))return null;const n=K((L=t.agent)==null?void 0:L.status)??K(t.status)??"unknown",a=K((O=t.agent)==null?void 0:O.error)??null,i=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,d=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,_=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,c=p&&m!=null?Math.max(0,_-m):null,l=r<=0||d==null?"never":d>900?"stale":"fresh",g=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(i&&!o?"keeper keepalive is not running":null),x=n==="offline"||n==="inactive"?"offline":y?"degraded":l==="stale"?"stale":l==="never"?"idle":"healthy",C=y?nc(y):e!=null&&e.quiet_active&&l!=="fresh"?"quiet_hours":i&&!o?"disabled":r<=0?"never_started":c!=null&&c>0?"min_gap":l==="fresh"||l==="stale"?"no_recent_activity":"unknown",E=x==="offline"||x==="degraded"||x==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:x,quiet_reason:C,next_action_path:E,last_reply_status:l,last_reply_at:g,last_reply_preview:null,last_error:y,next_eligible_at_s:c!=null&&c>0?c:null,recoverable:ko(void 0,E),summary:bo(void 0,x,C),keepalive_running:o}}function lc(t,e){if(!Wt(t))return null;const n=Zl(t.role),a=K(t.content)??K(t.preview);if(!a)return null;const i=As(t.ts_unix)??As(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:tc(n),text:a,timestamp:i,delivery:"history"}}function cc(t,e,n){const a=Wt(n)?n:null,i=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>lc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:ea(a==null?void 0:a.diagnostic),history:i,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function wi(t,e){const n=it.value[t]??[];it.value={...it.value,[t]:[...n,e].slice(-50)}}function dc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function uc(t,e){const a=(it.value[t]??[]).filter(i=>i.delivery!=="history"&&!e.some(o=>dc(i,o)));it.value={...it.value,[t]:[...e,...a].slice(-50)}}function Pa(t,e){Ut.value={...Ut.value,[t]:e},uc(t,e.history)}function Ti(t,e){const n=Ut.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Pa(t,{...n,diagnostic:{...a,...e}})}async function oi(){Me();try{await te()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Kn(t){tn.value=t.trim()}async function xo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Ut.value[n])return Ut.value[n];nt(bs,n,!0),nt(Bt,n,null);try{const a=await _t("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let i=null;try{i=JSON.parse(a)}catch{i=null}const o=cc(n,a,i);return Pa(n,o),o}catch(a){const i=a instanceof Error?a.message:`Failed to inspect ${n}`;return nt(Bt,n,i),null}finally{nt(bs,n,!1)}}async function pc(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const i=`local-${Date.now()}`;wi(n,{id:i,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),nt(ks,n,!0),nt(Bt,n,null);try{const o=await Yl(n,a);it.value={...it.value,[n]:(it.value[n]??[]).map(r=>r.id===i?{...r,delivery:"delivered"}:r)},wi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Ti(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await oi()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw it.value={...it.value,[n]:(it.value[n]??[]).map(d=>d.id===i?{...d,delivery:"error",error:r}:d)},Ti(n,{last_reply_status:"error",last_error:r}),nt(Bt,n,r),o}finally{nt(ks,n,!1)}}async function mc(t,e){const n=t.trim();if(!n)return null;nt(xs,n,!0),nt(Bt,n,null);try{const a=await Nn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),i=ic(a.result),o=(i==null?void 0:i.diagnostic)??null;if(o){const r=Ut.value[n];Pa(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??it.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await oi(),o}catch(a){const i=a instanceof Error?a.message:`Failed to probe ${n}`;throw nt(Bt,n,i),a}finally{nt(xs,n,!1)}}async function vc(t,e){const n=t.trim();if(!n)return null;nt(Ss,n,!0),nt(Bt,n,null);try{const a=await Nn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),i=oc(a.result),o=(i==null?void 0:i.after)??null;if(o){const r=Ut.value[n];Pa(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??it.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await oi(),o}catch(a){const i=a instanceof Error?a.message:`Failed to recover ${n}`;throw nt(Bt,n,i),a}finally{nt(Ss,n,!1)}}function le(t){return(t??"").trim().toLowerCase()}function pt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Hn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Dn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Je(t){return t.last_heartbeat??Dn(t.last_turn_ago_s)??Dn(t.last_proactive_ago_s)??Dn(t.last_handoff_ago_s)??Dn(t.last_compaction_ago_s)}function fc(t){const e=t.title.trim();return e||Hn(t.content)}function gc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function _c(t,e,n,a,i={}){var O;const o=le(t),r=e.filter(R=>le(R.assignee)===o&&(R.status==="claimed"||R.status==="in_progress")).length,d=n.filter(R=>le(R.from)===o).sort((R,D)=>pt(D.timestamp)-pt(R.timestamp))[0],p=a.filter(R=>le(R.agent)===o||le(R.author)===o).sort((R,D)=>pt(D.timestamp)-pt(R.timestamp))[0],_=(i.boardPosts??[]).filter(R=>le(R.author)===o).sort((R,D)=>pt(D.updated_at||D.created_at)-pt(R.updated_at||R.created_at))[0],m=(i.keepers??[]).filter(R=>le(R.name)===o&&Je(R)!==null).sort((R,D)=>pt(Je(D)??0)-pt(Je(R)??0))[0],c=d?pt(d.timestamp):0,l=p?pt(p.timestamp):0,g=_?pt(_.updated_at||_.created_at):0,y=m?pt(Je(m)??0):0,x=i.lastSeen?pt(i.lastSeen):0,C=((O=i.currentTask)==null?void 0:O.trim())||(r>0?`${r} claimed tasks`:null);if(c===0&&l===0&&g===0&&y===0&&x===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:C};const L=[d?{timestamp:d.timestamp,ts:c,text:Hn(d.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:g,text:`Post: ${Hn(fc(_))}`}:null,m?{timestamp:Je(m),ts:y,text:gc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:l,text:Hn(p.text)}:null].filter(R=>R!==null).sort((R,D)=>D.ts-R.ts)[0];return L&&L.ts>=x?{activeAssignedCount:r,lastActivityAt:L.timestamp,lastActivityText:L.text}:{activeAssignedCount:r,lastActivityAt:i.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const kt=f([]),gt=f([]),$n=f([]),Gt=f([]),ne=f(null),Xe=f(null),Ts=f(new Map),Ke=f([]),hn=f("hot"),de=f(!0),So=f(null),Ht=f(""),yn=f([]),Te=f(!1),Ao=f(new Map),Cs=f("unknown"),Ns=f(null),Rs=f(!1),bn=f(!1),Ls=f(!1),Ce=f(!1),$c=f(null),Ds=f(null),wo=f(null),To=f(null),hc=xt(()=>kt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Co=xt(()=>{const t=gt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ia=xt(()=>{const t=new Map,e=gt.value,n=$n.value,a=ta.value,i=Ke.value,o=Gt.value;for(const r of kt.value)t.set(r.name.trim().toLowerCase(),_c(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:i,keepers:o}));return t});function yc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const i=a.context_ratio;return i>.85?"handoff-imminent":i>.7?"preparing":i>.5?"compacting":"active"}const No=xt(()=>{const t=new Map;for(const e of Gt.value)t.set(e.name,yc(e));return t}),bc=12e4;function kc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const i=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof i=="number"?Date.now()-i*1e3:null}const Ro=xt(()=>{const t=Date.now(),e=new Set,n=Ts.value;for(const a of Gt.value){const i=kc(a,n);i!=null&&t-i>bc&&e.add(a.name)}return e}),na={},xc=5e3;let Fa=null;function Sc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Me(){delete na.compact,delete na.full}function ot(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ve(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ps(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Lo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Ac(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Do(t){if(!ot(t))return null;const e=b(t.name);return e?{name:e,status:Lo(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:ve(t.traits),interests:ve(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function Po(t){if(!ot(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:Ac(t.status),priority:S(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function Io(t){if(!ot(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:S(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function wc(t){return Array.isArray(t)?t.map(e=>{if(!ot(e))return null;const n=S(e.ts_unix);if(n==null)return null;const a=ot(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?S(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ci(t){if(!ot(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const i=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":i==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":i==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":i==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:i,next_action_path:n,last_reply_status:a,last_reply_at:Ps(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:S(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Tc(t,e){return(Array.isArray(t)?t:ot(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ot(a))return null;const i=ot(a.agent)?a.agent:null,o=ot(a.context)?a.context:null,r=ot(a.metrics_window)?a.metrics_window:void 0,d=b(a.name);if(!d)return null;const p=S(a.context_ratio)??S(o==null?void 0:o.context_ratio),_=b(a.status)??b(i==null?void 0:i.status)??"offline",m=Lo(_),c=b(a.model)??b(a.active_model)??b(a.primary_model),l=ve(a.skill_secondary),g=o?{source:b(o.source),context_ratio:S(o.context_ratio),context_tokens:S(o.context_tokens),context_max:S(o.context_max),message_count:S(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=i?{name:b(i.name),exists:typeof i.exists=="boolean"?i.exists:void 0,error:b(i.error),status:b(i.status),current_task:b(i.current_task)??null,last_seen:b(i.last_seen),last_seen_ago_s:S(i.last_seen_ago_s),is_zombie:typeof i.is_zombie=="boolean"?i.is_zombie:void 0}:void 0,x=wc(a.metrics_series),C={name:d,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:c,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:S(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:S(a.proactive_idle_sec),proactive_cooldown_sec:S(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(i==null?void 0:i.last_seen),generation:S(a.generation),turn_count:S(a.turn_count)??S(a.total_turns),keeper_age_s:S(a.keeper_age_s),last_turn_ago_s:S(a.last_turn_ago_s),last_handoff_ago_s:S(a.last_handoff_ago_s),last_compaction_ago_s:S(a.last_compaction_ago_s),last_proactive_ago_s:S(a.last_proactive_ago_s),context_ratio:p,context_tokens:S(a.context_tokens)??S(o==null?void 0:o.context_tokens),context_max:S(a.context_max)??S(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:g,traits:ve(a.traits),interests:ve(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:S(a.activityLevel)??S(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:S(a.conversation_tail_count),k2k_count:S(a.k2k_count),handoff_count_total:S(a.handoff_count_total)??S(a.trace_history_count),compaction_count:S(a.compaction_count),last_compaction_saved_tokens:S(a.last_compaction_saved_tokens),diagnostic:Ci(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:l,skill_reason:b(a.skill_reason)??null,metrics_series:x.length>0?x:void 0,metrics_window:r,agent:y};return C.diagnostic=Ci(a.diagnostic)??rc(C,(e==null?void 0:e.lodge)??null),C}).filter(a=>a!==null)}function Cc(t){return ot(t)?{...t,lodge:sc(t.lodge)??void 0}:null}function Nc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function Rc(t){if(!ot(t))return null;const e=S(t.iteration);if(e==null)return null;const n=S(t.metric_before)??0,a=S(t.metric_after)??n,i=ot(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:S(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:S(t.elapsed_ms)??0,cost_usd:S(t.cost_usd)??null,evidence:i?{worker_engine:(i.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(i.worker_model)??"",tool_call_count:S(i.tool_call_count)??0,tool_names:ve(i.tool_names)??[],session_id:b(i.session_id)??"",evidence_status:i.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Lc(t){var o,r;if(!ot(t))return null;const e=b(t.loop_id);if(!e)return null;const n=S(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(Rc).filter(d=>d!==null):[],i=S(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:Nc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:S(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:S(t.max_iterations)??0,baseline_metric:n,current_metric:i,target:b(t.target)??"",stagnation_streak:S(t.stagnation_streak)??0,stagnation_limit:S(t.stagnation_limit)??0,elapsed_seconds:S(t.elapsed_seconds)??0,updated_at:Ps(t.updated_at)??null,stopped_at:Ps(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:S(t.latest_tool_call_count)??0,latest_tool_names:ve(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function te(t="full"){var a,i,o;const e=Date.now(),n=na[t];if(!(n&&e-n.time<xc)){Rs.value=!0;try{const r=await Xr(t);na[t]={data:r,time:e},kt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(Do).filter(p=>p!==null),gt.value=(Array.isArray((i=r.tasks)==null?void 0:i.tasks)?r.tasks.tasks:[]).map(Po).filter(p=>p!==null),$n.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(Io).filter(p=>p!==null);const d=Cc(r.status);ne.value=d,Gt.value=Tc(r.keepers,d),Xe.value=r.perpetual??null,$c.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Rs.value=!1}}}async function Dc(){try{const t=await Zr(),e=(Array.isArray(t.agents)?t.agents:[]).map(Do).filter(i=>i!==null),n=kt.value,a=new Map(n.map(i=>[i.name,i]));kt.value=e.map(i=>{const o=a.get(i.name);return o?{...o,status:i.status,current_task:i.current_task}:i})}catch(t){console.error("Agents selective fetch error:",t)}}async function Pc(){try{const t=await tl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(Po).filter(i=>i!==null),n=gt.value,a=new Map(n.map(i=>[i.id,i]));gt.value=e.map(i=>{const o=a.get(i.id);return o?{...o,status:i.status,priority:i.priority??o.priority,assignee:i.assignee??o.assignee}:i})}catch(t){console.error("Tasks selective fetch error:",t)}}async function Ic(){try{const t=$n.value,e=t.reduce((r,d)=>Math.max(r,d.seq??0),0),n=await el(e),a=(Array.isArray(n.messages)?n.messages:[]).map(Io).filter(r=>r!==null);if(a.length===0)return;const i=new Set(t.map(r=>r.seq).filter(r=>r!=null)),o=a.filter(r=>r.seq==null||!i.has(r.seq));if(o.length>0){const r=[...t,...o];$n.value=r.length>500?r.slice(-500):r}}catch(t){console.error("Messages selective fetch error:",t)}}async function zt(){bn.value=!0;try{const t=await gl(hn.value,{excludeSystem:de.value});Ke.value=t.posts??[],Ds.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{bn.value=!1}}async function qt(){var t;Ls.value=!0;try{const e=Ht.value||((t=ne.value)==null?void 0:t.room)||"default";Ht.value||(Ht.value=e);const n=await Pl(e);So.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Ls.value=!1}}async function kn(){Te.value=!0;try{const t=await Xl();yn.value=Array.isArray(t)?t:[],wo.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Te.value=!1}}async function Oe(){Ce.value=!0;try{const t=await nl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const i=Lc(a);i&&n.set(i.loop_id,i)}Ao.value=n,To.value=new Date().toISOString(),Ns.value=null,Cs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),Cs.value="error",Ns.value=t instanceof Error?t.message:String(t)}finally{Ce.value=!1}}let Un=null;function Ec(t){Un=t}let Bn=null;function Mc(t){Bn=t}const Le={};function ce(t,e,n=500){Le[t]||(Le[t]=setTimeout(()=>{e(),delete Le[t]},n))}function Oc(){const t=uo.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ts.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ts.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ce("agents",Dc),Sc(e.type)&&(Me(),Fa||(Fa=setTimeout(()=>{te(),Bn==null||Bn(),Fa=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ce("tasks",Pc),e.type==="broadcast"&&ce("messages",Ic),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ce("dashboard",()=>{Me(),te()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ce("board",zt),e.type.startsWith("decision_")&&ce("council",()=>Un==null?void 0:Un()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ce("mdal",Oe,350)}});return()=>{t();for(const e of Object.keys(Le))clearTimeout(Le[e]),delete Le[e]}}let en=null;function zc(){en||(en=setInterval(()=>{jt.value||Me(),te()},1e4))}function qc(){en&&(clearInterval(en),en=null)}function w({title:t,class:e,children:n}){return s`
    <div class="card ${e??""}">
      ${t?s`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Rt({status:t,label:e}){return s`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function jc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const i=Math.floor(a/60);if(i<60)return`${i}m ago`;const o=Math.floor(i/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function F({timestamp:t}){const e=jc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function J(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function tt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function ue(t){return(t??"").trim().toLowerCase()}function st(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Ot(t){return typeof t!="number"||Number.isNaN(t)?3:t}function ri(t){const e=Ot(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let Fc=0;const pe=f([]);function A(t,e="success",n=4e3){const a=++Fc;pe.value=[...pe.value,{id:a,message:t,type:e}],setTimeout(()=>{pe.value=pe.value.filter(i=>i.id!==a)},n)}function Kc(t){pe.value=pe.value.filter(e=>e.id!==t)}function Hc(){const t=pe.value;return t.length===0?null:s`
    <div class="toast-container">
      ${t.map(e=>s`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Kc(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Uc="masc_dashboard_agent_name",He=f(null),aa=f(!1),xn=f(""),sa=f([]),Sn=f([]),De=f(""),nn=f(!1);function Pe(t){He.value=t,li()}function Ni(){He.value=null,xn.value="",sa.value=[],Sn.value=[],De.value=""}function Bc(){const t=He.value;return t?kt.value.find(e=>e.name===t)??null:null}function Eo(t){return t?gt.value.filter(e=>e.assignee===t):[]}async function li(){const t=He.value;if(t){aa.value=!0,xn.value="",sa.value=[],Sn.value=[];try{const e=await Bl(80);sa.value=e.filter(i=>i.includes(t)).slice(0,20);const n=Eo(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async i=>{try{const o=await Wl(i.id,25);return{taskId:i.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:i.id,text:`Failed to load history: ${r}`}}}));Sn.value=a}catch(e){xn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{aa.value=!1}}}async function Ri(){var a;const t=He.value,e=De.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(Uc))==null?void 0:a.trim())||"dashboard";nn.value=!0;try{await ho(n,`@${t} ${e}`),De.value="",A(`Mention sent to ${t}`,"success"),li()}catch(i){const o=i instanceof Error?i.message:"Failed to send mention";A(o,"error")}finally{nn.value=!1}}function Wc({task:t}){return s`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Rt} status=${t.status} />
    </div>
  `}function Gc({row:t}){return s`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Jc(){var i,o,r,d;const t=He.value;if(!t)return null;const e=Bc(),n=Eo(t),a=sa.value;return s`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&Ni()}}
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
                        <${Rt} status=${e.status} />
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
                    ${e.last_seen?s`<span>Last seen: <${F} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{li()}} disabled=${aa.value}>
              ${aa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ni}>Close</button>
          </div>
        </div>

        ${xn.value?s`<div class="council-error">${xn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(p=>s`<${Wc} key=${p.id} task=${p} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((p,_)=>s`<div key=${_} class="agent-activity-line">${p}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${Sn.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${Sn.value.map(p=>s`<${Gc} key=${p.taskId} row=${p} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${De.value}
              onInput=${p=>{De.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&Ri()}}
              disabled=${nn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ri()}}
              disabled=${nn.value||De.value.trim()===""}
            >
              ${nn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ia=600*1e3,Wn=1200*1e3;function Mo(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Oo(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function Vc(t){return t.updated_at??t.created_at??null}function Li(t,e,n){var C,E;const a=ue(t.assignee),i=a?e.get(a)??null:null,o=i?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(i==null?void 0:i.last_seen)??null,d=r?Math.max(0,Date.now()-J(r)):Number.POSITIVE_INFINITY,p=st(t.description),_=st(i==null?void 0:i.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let c="ok",l="Fresh owner coverage",g=_??p??t.id,y=!1,x=!1;return t.status==="todo"?t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,c="bad",l="Assigned owner is offline",g="Queue item is blocked until ownership changes."):d>ia?(c="warn",l="Owner exists but live signal is quiet",g=_??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(C=i.current_task)!=null&&C.trim()?(c="warn",l="Owner is already carrying active work",g=_??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(l="Ready and covered by a fresh operator",g=_??p??"This can be picked up immediately."):(y=!0,c="bad",l="Assigned owner is not present in the room",g="Reassign or bring the owner back online."):(y=!0,c=Ot(t.priority)<=2?"bad":"warn",l=Ot(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",g="Assign an agent before this queue item slips."):m&&(t.assignee?i?i.status==="offline"||i.status==="inactive"?(y=!0,c="bad",l="Assigned owner is offline",g=_??"Execution has no live operator right now."):d>Wn?(x=!0,c="bad",l="Assigned owner has gone quiet",g=_??"Fresh operator signal is missing."):d>ia?(x=!0,c="warn",l="Execution has been quiet for too long",g=_??"Check whether this work is blocked."):(E=i.current_task)!=null&&E.trim()?(l="Execution has fresh owner coverage",g=_??p??t.id):(c="warn",l=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",g=_??"Task state and agent focus are drifting apart."):(y=!0,c="bad",l="Assigned owner is not active in the room",g="Execution is orphaned until ownership is restored."):(y=!0,c="bad",l="Active work has no assignee",g="Claim or reassign this task immediately.")),{task:t,assigneeAgent:i,motion:o,tone:c,note:l,focus:g,lastSignalAt:r,lastTouchedAt:Vc(t),ownerGap:y,quiet:x}}function Qc(t,e){var l;const n=e.get(ue(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,i=a?Math.max(0,Date.now()-J(a)):Number.POSITIVE_INFINITY,o=!!((l=t.current_task)!=null&&l.trim()),r=n.activeAssignedCount,d=o||r>0;let p="loaded",_="ok",m="Healthy active load",c=st(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",_="bad",m="Agent is unavailable"):d&&i>Wn?(p="quiet",_="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",_="warn",m="Claimed work exists but current_task is empty",c=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",_="warn",m="current_task has no matching claimed work",c=st(t.current_task)??"Task metadata and operator state drifted."):!d&&i<=ia?(p="dispatchable",_="ok",m="Fresh signal and no active load",c=n.lastActivityText??"Ready for assignment."):d?i>ia&&(p="loaded",_="warn",m="Execution load is healthy but slightly quiet",c=st(t.current_task)??`${r} active tasks in flight.`):(p="quiet",_=i>Wn?"bad":"warn",m=i>Wn?"No fresh signal while idle":"Reachable, but not freshly active",c=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:_,state:p,note:m,focus:c,lastSignalAt:a,activeTaskCount:r}}function Ve({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Yc({item:t}){return s`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?ri(t.taskRow.task.priority):Oo(t.agentRow.state)}
        </span>
        ${t.kind==="task"?s`<span>${Mo(t.taskRow.task.status)}</span>`:s`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?s`<span><${F} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </div>
  `}function Di({row:t}){var e;return s`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${ri(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?s`<${Rt} status=${t.assigneeAgent.status} />`:s`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${Mo(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?s`<span>Owner ${t.task.assignee}</span>`:s`<span>Unassigned</span>`}
        ${t.lastTouchedAt?s`<span>Touched <${F} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&st(t.assigneeAgent.current_task)!==t.focus?s`<div class="monitor-footnote">Owner focus: ${st(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function Xc({row:t}){const{agent:e}=t;return s`
    <button class="monitor-row ${t.tone}" onClick=${()=>Pe(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Rt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Oo(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${F} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function Zc(){const t=kt.value,e=gt.value,n=new Map(t.map(c=>[ue(c.name),c])),a=Ia.value,i=e.filter(c=>c.status==="claimed"||c.status==="in_progress").map(c=>Li(c,n,a)).sort((c,l)=>{const g=tt(l.tone)-tt(c.tone);return g!==0?g:J(l.lastSignalAt??l.lastTouchedAt)-J(c.lastSignalAt??c.lastTouchedAt)}),o=e.filter(c=>c.status==="todo").map(c=>Li(c,n,a)).sort((c,l)=>{const g=tt(l.tone)-tt(c.tone);if(g!==0)return g;const y=Ot(c.task.priority)-Ot(l.task.priority);return y!==0?y:J(c.lastTouchedAt)-J(l.lastTouchedAt)}),r=t.map(c=>Qc(c,a)).filter(c=>c.state==="dispatchable"||c.state==="drift"||c.state==="quiet").sort((c,l)=>{if(c.state==="dispatchable"&&l.state!=="dispatchable")return-1;if(l.state==="dispatchable"&&c.state!=="dispatchable")return 1;const g=tt(l.tone)-tt(c.tone);return g!==0?g:J(l.lastSignalAt)-J(c.lastSignalAt)}),d=[...i.filter(c=>c.tone!=="ok").map(c=>({kind:"task",key:`active-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt??c.lastTouchedAt,taskRow:c})),...o.filter(c=>c.tone==="bad").map(c=>({kind:"task",key:`ready-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastTouchedAt,taskRow:c})),...r.filter(c=>c.state==="drift"||c.tone==="bad").map(c=>({kind:"agent",key:`agent-${c.agent.name}`,tone:c.tone,title:c.agent.name,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt,agentRow:c}))].sort((c,l)=>{const g=tt(l.tone)-tt(c.tone);return g!==0?g:J(l.timestamp)-J(c.timestamp)}).slice(0,8),p=r.filter(c=>c.state==="dispatchable"),_=[...i,...o].filter(c=>c.ownerGap),m=i.filter(c=>c.quiet);return s`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ve} label="Active work" value=${i.length} color="#fbbf24" caption="claimed + in progress" />
        <${Ve} label="Needs intervention" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Ve} label="Ownership gaps" value=${_.length} color=${_.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Ve} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Ve} label="Quiet execution" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${d.length===0?s`<div class="empty-state">No active execution risks right now</div>`:d.map(c=>s`<${Yc} key=${c.key} item=${c} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?s`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(c=>s`<${Di} key=${c.task.id} row=${c} />`)}
          </div>
        <//>

        <${w} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?s`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(c=>s`<${Xc} key=${c.agent.name} row=${c} />`)}
          </div>
        <//>
      </div>

      <${w} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${i.length===0?s`<div class="empty-state">No active execution tasks</div>`:i.map(c=>s`<${Di} key=${c.task.id} row=${c} />`)}
        </div>
      <//>
    </div>
  `}function td(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function ed(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function nd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Pi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function zo(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function ad(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function qo(t){if(!t)return null;const e=Ut.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function jo({keeper:t,showRawStatus:e=!1}){if(bt(()=>{t!=null&&t.name&&xo(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ut.value[t.name],a=qo(t),i=bs.value[t.name];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${td(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${ed((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${i?s`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?s` · ${zo(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?s` · next eligible ${ad(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?s`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?s`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Fo({keeperName:t,placeholder:e}){const[n,a]=ni("");bt(()=>{t&&xo(t)},[t]);const i=it.value[t]??[],o=ks.value[t]??!1,r=Bt.value[t],d=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await pc(t,p)}catch(_){const m=_ instanceof Error?_.message:`Failed to message ${t}`;A(m,"error")}}};return s`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${i.length===0?s`<div class="control-status-copy">No direct keeper conversation yet.</div>`:i.map(p=>s`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Pi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Pi(p)}`}>${nd(p)}</span>
                  ${p.timestamp?s`<span class="keeper-conversation-time">${zo(p.timestamp)}</span>`:null}
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
  `}function Ko({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=qo(e),i=xs.value[e.name]??!1,o=Ss.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",d=(a==null?void 0:a.recoverable)??r==="recover";return s`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{mc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;A(_,"error")})}}
        disabled=${i||!t.trim()}
      >
        ${i?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{vc(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;A(_,"error")})}}
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
  `}const ci=f(null);function oa(t){ci.value=t,Kn(t.name)}function Ii(){ci.value=null}const xe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function sd(t){if(!t)return 0;const e=xe.findIndex(n=>n.level===t);return e>=0?e:0}function id({keeper:t}){const e=sd(t.autonomy_level),n=xe[e]??xe[0];if(!n)return null;const a=(e+1)/xe.length*100;return s`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${xe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${xe.map((i,o)=>s`
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
  `}function Gn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function od({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",i=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return s`
    <div class="keeper-kpis">
      ${i.map(o=>s`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?s`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Gn(t.context_tokens)}</div>
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
  `}function rd({keeper:t}){var m,c;const e=t.metrics_series??[];if(e.length<2){const l=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,g=l>85?"#ef4444":l>70?"#f59e0b":"#22c55e";return s`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${l.toFixed(1)}%;background:${g}"></div>
        </div>
        <span class="chart-pct">${l.toFixed(1)}%</span>
      </div>`}const n=200,a=60,i=2,o=e.length,r=e.map((l,g)=>{const y=i+g/(o-1)*(n-2*i),x=a-i-(l.context_ratio??0)*(a-2*i);return{x:y,y:x,p:l}}),d=r.map(({x:l,y:g})=>`${l.toFixed(1)},${g.toFixed(1)}`).join(" "),p=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return s`
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
    </div>`}const Ka=f("");function ld({keeper:t}){var i,o,r,d;const e=Ka.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((i=t.traits)==null?void 0:i.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return s`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ka.value}
        onInput=${p=>{Ka.value=p.target.value}}
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
      ${t.context_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Gn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Gn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?s`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Gn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function cd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return s`
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
  `}function dd({items:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No equipment</div>`:s`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>s`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function ud({rels:t}){const e=Object.entries(t);return e.length===0?s`<div class="empty-state" style="font-size:13px">No relationships</div>`:s`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>s`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ei({traits:t,label:e}){return t.length===0?null:s`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>s`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ha(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function pd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ha(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ha(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ha(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return s`
    <div class="keeper-signal-list">
      ${n.map(a=>s`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Ho(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function md(){try{const t=await Nn({actor:Ho(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=ii(t.result);Me(),await te(),e!=null&&e.skipped_reason?A(e.skipped_reason,"warning"):A(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";A(e,"error")}}function vd({keeper:t}){return s`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${jo} keeper=${t} />
          <${Ko}
            actor=${Ho()}
            keeper=${t}
            onPokeLodge=${()=>{md()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Fo}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function fd(){var e,n,a;const t=ci.value;return t?s`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${i=>{i.target.classList.contains("keeper-detail-overlay")&&Ii()}}
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
            <${Rt} status=${t.status} />
            ${t.model?s`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ii()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${od} keeper=${t} />

        ${""}
        <${rd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${ld} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${Ei} traits=${t.traits??[]} label="Traits" />
            <${Ei} traits=${t.interests??[]} label="Interests" />
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
                <${id} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?s`
              <${w} title="TRPG Stats">
                <${cd} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?s`
              <${w} title="Equipment (${t.inventory.length})">
                <${dd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?s`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${ud} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${pd} keeper=${t} />
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
        <${vd} keeper=${t} />
      </div>
    </div>
  `:null}const ze=f(!1);function gd(){ze.value=!0}function Mi(){ze.value=!1}function _d(){ze.value=!ze.value}const Ua=600*1e3,Ba=1200*1e3,Oi=.8,Wa=f("triage");function ye(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Pn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function zi(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function qi(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function $d(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Ga(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function hd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function yd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function bd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function kd(t){return t?t.enabled?t.quiet_active?`Quiet hours ${zi(t.quiet_start)}-${zi(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${qi(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${qi(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function ji(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function be({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function xd({item:t}){return s`
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
  `}function Ja({tone:t,title:e,subtitle:n,meta:a,focus:i,onClick:o}){return s`
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
  `}function Fi(){var ut,ct,se,St,At,B,X,k,Lt,Jt,ie,oe,I,Dt,re,Be,We;const t=ne.value,e=kt.value,n=gt.value,a=Gt.value,i=Co.value,o=(ut=t==null?void 0:t.monitoring)==null?void 0:ut.board,r=(ct=t==null?void 0:t.monitoring)==null?void 0:ct.council,d=jt.value,p=new Map(e.map(v=>[ue(v.name),v])),_=Ia.value,m=e.map(v=>{var hi;const N=_.get(ue(v.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},j=N.lastActivityAt??v.last_seen??null,Z=j?Math.max(0,Date.now()-J(j)):Number.POSITIVE_INFINITY,z=N.activeAssignedCount,dt=!!((hi=v.current_task)!=null&&hi.trim()),G=dt||z>0;let V="ok",$t="Fresh and ready",_e=!1,$e=!1;return v.status==="offline"||v.status==="inactive"?(V=G?"bad":"warn",$t=G?"Load without an available owner":"Offline"):G&&Z>Ba?(V="bad",$t="Execution is stale"):z>0&&!dt?(V="warn",$t="Claimed work has no current_task",$e=!0):dt&&z===0?(V="warn",$t="current_task has no claimed work",$e=!0):!G&&Z<=Ua?(V="ok",$t="Dispatchable now",_e=!0):!G&&Z>Ba?(V="warn",$t="Idle but not freshly active"):G&&Z>Ua&&(V="warn",$t="Execution is getting quiet"),{agent:v,lastSignalAt:j,activeTaskCount:z,tone:V,note:$t,focus:st(v.current_task)??N.lastActivityText??(_e?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:_e,drift:$e}}).sort((v,N)=>{const j=tt(N.tone)-tt(v.tone);return j!==0?j:J(N.lastSignalAt)-J(v.lastSignalAt)}),c=a.map(v=>{var V;const N=No.value.get(v.name)??"idle",j=Ro.value.has(v.name),Z=v.context_ratio??0,z=v.diagnostic??null;let dt="ok",G="Healthy keeper";return j||v.status==="offline"||N==="handoff-imminent"||(z==null?void 0:z.health_state)==="offline"||(z==null?void 0:z.health_state)==="degraded"?(dt="bad",G=st(z==null?void 0:z.summary,56)??(j?"Heartbeat stale":N==="handoff-imminent"?"Handoff imminent":(z==null?void 0:z.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((z==null?void 0:z.health_state)==="stale"||Z>=Oi||N==="preparing"||N==="compacting")&&(dt="warn",G=st(z==null?void 0:z.summary,56)??(Z>=Oi?"High context pressure":`Lifecycle ${N}`)),{keeper:v,tone:dt,note:G,focus:st(z==null?void 0:z.summary,120)??st((V=v.agent)==null?void 0:V.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,N)=>{const j=tt(N.tone)-tt(v.tone);return j!==0?j:J(N.timestamp)-J(v.timestamp)}),l=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var _e,$e;const N=v.assignee?p.get(ue(v.assignee))??null:null,j=N?_.get(ue(N.name))??null:null,Z=(j==null?void 0:j.lastActivityAt)??(N==null?void 0:N.last_seen)??null,z=Z?Math.max(0,Date.now()-J(Z)):Number.POSITIVE_INFINITY,dt=v.status==="claimed"||v.status==="in_progress";let G="ok",V="Covered",$t=!1;return v.assignee?!N||N.status==="offline"||N.status==="inactive"?(G="bad",V="Assigned owner is unavailable",$t=!0):dt&&z>Ba?(G="bad",V="Execution has lost a fresh signal"):dt&&z>Ua?(G="warn",V="Execution is drifting quiet"):v.status==="todo"&&Ot(v.priority)<=2&&!((_e=N.current_task)!=null&&_e.trim())&&((j==null?void 0:j.activeAssignedCount)??0)===0?(G="ok",V="Ready for dispatch"):dt&&!(($e=N.current_task)!=null&&$e.trim())&&(G="warn",V="Owner focus is not explicit"):(G=Ot(v.priority)<=2?"bad":"warn",V=dt?"Active work has no owner":"Ready work has no owner",$t=!0),{task:v,owner:N,lastSignalAt:Z,tone:G,note:V,focus:st(N==null?void 0:N.current_task)??(j==null?void 0:j.lastActivityText)??st(v.description)??"Needs operator attention.",ownerGap:$t}}).sort((v,N)=>{const j=tt(N.tone)-tt(v.tone);if(j!==0)return j;const Z=Ot(v.task.priority)-Ot(N.task.priority);return Z!==0?Z:J(N.lastSignalAt??N.task.updated_at??N.task.created_at)-J(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),g=l.filter(v=>v.task.status==="todo"&&Ot(v.task.priority)<=2),y=l.filter(v=>v.ownerGap).length,x=m.filter(v=>v.dispatchable),C=m.filter(v=>v.drift||v.tone!=="ok"),E=c.filter(v=>v.tone!=="ok"),L=t!=null&&t.paused?"bad":((se=t==null?void 0:t.data_quality)==null?void 0:se.board_contract_ok)===!1||((St=t==null?void 0:t.data_quality)==null?void 0:St.council_feed_ok)===!1?"warn":d?"ok":"warn",O=[];t!=null&&t.paused&&O.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((At=t.data_quality)==null?void 0:At.last_sync_at)??null,action:()=>Mt("ops")}),d||O.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:gd}),ye(o==null?void 0:o.alert_level)!=="ok"&&O.push({key:"board-monitor",tone:ye(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${Ga(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>Mt("board")}),ye(r==null?void 0:r.alert_level)!=="ok"&&O.push({key:"council-monitor",tone:ye(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${Ga(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>Mt("board")}),(((B=t==null?void 0:t.data_quality)==null?void 0:B.board_contract_ok)===!1||((X=t==null?void 0:t.data_quality)==null?void 0:X.council_feed_ok)===!1)&&O.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((k=t.data_quality)==null?void 0:k.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Lt=t.data_quality)==null?void 0:Lt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Jt=t.data_quality)==null?void 0:Jt.last_sync_at)??null,action:()=>Mt("ops")});const R=[...O,...l.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>Mt("overview")})),...E.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>oa(v.keeper)})),...C.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Pe(v.agent.name)}))].sort((v,N)=>{const j=tt(N.tone)-tt(v.tone);return j!==0?j:J(N.timestamp)-J(v.timestamp)}).slice(0,8),D=Wa.value;return s`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${D==="triage"?"active":""}"
        onClick=${()=>{Wa.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${D==="dispatch"?"active":""}"
        onClick=${()=>{Wa.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${D==="dispatch"?s`<${Zc} />`:s`<div class="stats-grid">
      <${be}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Pn(L)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${be}
        label="Urgent Queue"
        value=${g.length}
        color=${g.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${be}
        label="Active Work"
        value=${i.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${be}
        label="Dispatchable"
        value=${x.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${be}
        label="Keeper Pressure"
        value=${E.length}
        color=${E.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${be}
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
          <div class="stat-value" style=${`color:${d?"#4ade80":"#fbbf24"}`}>${d?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${Tn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Pn(ye(o==null?void 0:o.alert_level))}`}>${ji(o==null?void 0:o.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${Ga(o==null?void 0:o.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Pn(ye(r==null?void 0:r.alert_level))}`}>${ji(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Pn(L)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${$d((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(ie=t==null?void 0:t.data_quality)!=null&&ie.last_sync_at?s`Last sync <${F} timestamp=${t.data_quality.last_sync_at} />`:s`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${kd(t==null?void 0:t.lodge)}</div>
        ${(oe=t==null?void 0:t.lodge)!=null&&oe.last_skip_reason?s`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
      </div>
    <//>

    <div class="grid-2col">
      <${w} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${R.length===0?s`<div class="empty-state">No immediate intervention required</div>`:R.map(v=>s`<${xd} key=${v.key} item=${v} />`)}
        </div>
      <//>

      <${w} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${x.length===0?s`<div class="empty-state">No fully dispatchable agents right now</div>`:x.slice(0,5).map(v=>s`
                <${Ja}
                  key=${v.agent.name}
                  tone=${v.tone}
                  title=${v.agent.name}
                  subtitle=${v.note}
                  meta=${[v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No recent signal",v.agent.model??"model n/a",v.agent.koreanName??"room agent"]}
                  focus=${v.focus}
                  onClick=${()=>Pe(v.agent.name)}
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
          ${l.length===0?s`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(v=>s`
                <${Ja}
                  key=${v.task.id}
                  tone=${v.tone}
                  title=${v.task.title}
                  subtitle=${`${ri(v.task.priority)} · ${v.note}`}
                  meta=${[v.task.assignee?`Owner ${v.task.assignee}`:"Unassigned",v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No live signal",v.task.updated_at?`Touched ${new Date(v.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${v.focus}
                  onClick=${()=>Mt("overview")}
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
          ${E.length===0?s`<div class="empty-state">No keeper pressure signals right now</div>`:E.slice(0,5).map(v=>{var N;return s`
                <${Ja}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(N=v.keeper.diagnostic)!=null&&N.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${yd(v.keeper.diagnostic.quiet_reason)} · next ${bd(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>oa(v.keeper)}
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
          ${C.length===0?s`<div class="empty-state">No agent drift or stale load right now</div>`:C.slice(0,5).map(v=>s`
                <button class="monitor-row ${v.tone}" onClick=${()=>Pe(v.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${v.agent.name}</span>
                        ${v.agent.koreanName?s`<span class="monitor-sub">${v.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${v.note}</div>
                    </div>
                    <${Rt} status=${v.agent.status} />
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
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${hc.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${Xe.value?`Perpetual runtime ${Xe.value.running?"running":"stopped"}${Xe.value.goal?` · ${st(Xe.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(I=t==null?void 0:t.lodge)!=null&&I.enabled?"enabled":"disabled"} · Last tick ${((Dt=t==null?void 0:t.lodge)==null?void 0:Dt.last_tick_ago)??"never"} · Self heartbeats ${((Be=(re=t==null?void 0:t.lodge)==null?void 0:re.active_self_heartbeats)==null?void 0:Be.length)??0}${(We=t==null?void 0:t.lodge)!=null&&We.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${E.length} · Highest context ${hd(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>`}
  `}const Uo=f(null),Kt=f(null),ra=f(!1),la=f(!1),ca=f(null),da=f(null),Is=f(null),ua=f(null),qe=f("summary"),Rn=f(null),Es=f(!1),pa=f(null),Bo=f(null),Ms=f(!1),ma=f(null);function T(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Q(t){return typeof t=="boolean"?t:void 0}function rt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Sd(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Ad(t){if(T(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:rt(t.tool_allowlist),model_allowlist:rt(t.model_allowlist),requires_human_for:rt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:h(t.escalation_timeout_sec),kill_switch:Q(t.kill_switch),frozen:Q(t.frozen)}}function wd(t){if(T(t))return{headcount_cap:h(t.headcount_cap),active_operation_cap:h(t.active_operation_cap),max_cost_usd:h(t.max_cost_usd),max_tokens:h(t.max_tokens)}}function di(t){if(!T(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:rt(t.roster),capability_profile:rt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:Ad(t.policy),budget:wd(t.budget)}}function Wo(t){if(!T(t))return null;const e=di(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:h(t.roster_total),roster_live:h(t.roster_live),active_operation_count:h(t.active_operation_count),health:u(t.health),reasons:rt(t.reasons),children:Array.isArray(t.children)?t.children.map(Wo).filter(n=>n!==null):[]}:null}function Td(t){if(T(t))return{total_units:h(t.total_units),company_count:h(t.company_count),platoon_count:h(t.platoon_count),squad_count:h(t.squad_count),leaf_agent_unit_count:h(t.leaf_agent_unit_count),live_agent_count:h(t.live_agent_count),managed_unit_count:h(t.managed_unit_count),active_operation_count:h(t.active_operation_count)}}function Go(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:Td(e.summary),units:Array.isArray(e.units)?e.units.map(Wo).filter(n=>n!==null):[]}}function ui(t){if(!T(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),i=u(t.trace_id),o=u(t.status);return!e||!n||!a||!i||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:i,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:rt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function Cd(t){if(!T(t))return null;const e=ui(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function Jo(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),active:h(n.active),paused:h(n.paused),managed:h(n.managed),projected:h(n.projected)}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Cd).filter(a=>a!==null):[]}}function Vo(t){if(!T(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:rt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function Nd(t){if(!T(t))return null;const e=Vo(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:ui(t.operation)}:null}function Qo(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),active:h(n.active),projected:h(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Nd).filter(a=>a!==null):[]}}function Rd(t){if(!T(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),i=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!i||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:i,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function Yo(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),pending:h(n.pending),approved:h(n.approved),denied:h(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Rd).filter(a=>a!==null):[]}}function Ld(t){if(!T(t))return null;const e=di(t.unit);return e?{unit:e,roster_total:h(t.roster_total),roster_live:h(t.roster_live),headcount_cap:h(t.headcount_cap),active_operations:h(t.active_operations),active_operation_cap:h(t.active_operation_cap),utilization:h(t.utilization)}:null}function Dd(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Ld).filter(n=>n!==null):[]}}function Pd(t){if(!T(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function Xo(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:h(n.total),bad:h(n.bad),warn:h(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Pd).filter(a=>a!==null):[]}}function Zo(t){if(!T(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function Id(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map(Zo).filter(n=>n!==null):[]}}function Ed(t){if(!T(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function Md(t){if(!T(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),i=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),d=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!i||!o||!r||!d||!p)return null;const _=T(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Q(t.present)??!1,phase:i,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:d,current_step:p,blockers:rt(t.blockers),counts:{operations:h(_.operations),detachments:h(_.detachments),workers:h(_.workers),approvals:h(_.approvals),alerts:h(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Ed).filter(m=>m!==null):[]}}function Od(t){if(!T(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),i=u(t.timestamp),o=u(t.title),r=u(t.detail),d=u(t.tone),p=u(t.source);return!e||!n||!a||!i||!o||!r||!d||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:i,title:o,detail:r,tone:d,source:p}}function zd(t){if(!T(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:rt(t.lane_ids),count:h(t.count)??0}}function tr(t){if(!T(t))return;const e=T(t.overview)?t.overview:{},n=T(t.gaps)?t.gaps:{},a=T(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:h(e.active_lanes),moving_lanes:h(e.moving_lanes),stalled_lanes:h(e.stalled_lanes),projected_lanes:h(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Md).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Od).filter(i=>i!==null):[],gaps:{count:h(n.count),items:Array.isArray(n.items)?n.items.map(zd).filter(i=>i!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function qd(t){if(!T(t))return;const e=T(t.workers)?t.workers:{},n=Q(t.pass);return{status:u(t.status)??"missing",source:u(t.source)??"none",run_id:u(t.run_id)??null,captured_at:u(t.captured_at)??null,...n!==void 0?{pass:n}:{},...h(t.peak_hot_slots)!=null?{peak_hot_slots:h(t.peak_hot_slots)}:{},...h(t.ctx_per_slot)!=null?{ctx_per_slot:h(t.ctx_per_slot)}:{},workers:{expected:h(e.expected),joined:h(e.joined),current_task_bound:h(e.current_task_bound),fresh_heartbeats:h(e.fresh_heartbeats),done:h(e.done),final:h(e.final)},artifact_ref:u(t.artifact_ref)??null,missing_reason:u(t.missing_reason)??null}}function jd(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:Go(e.topology),operations:Jo(e.operations),detachments:Qo(e.detachments),alerts:Xo(e.alerts),decisions:Yo(e.decisions),capacity:Dd(e.capacity),traces:Id(e.traces),swarm_status:tr(e.swarm_status)}}function Fd(t){const e=T(t)?t:{},n=Go(e.topology),a=Jo(e.operations),i=Qo(e.detachments),o=Xo(e.alerts),r=Yo(e.decisions);return{version:u(e.version),generated_at:u(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary},detachments:{version:i.version,generated_at:i.generated_at,summary:i.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:tr(e.swarm_status),swarm_proof:qd(e.swarm_proof)}}function Kd(t){if(!T(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function Hd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Ud(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),i=u(t.summary);return!e||!n||!a||!i?null:{id:e,title:n,tool:a,summary:i,success_signals:rt(t.success_signals),pitfalls:rt(t.pitfalls)}}function Bd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),i=u(t.when_to_use);return!e||!n||!a||!i?null:{id:e,title:n,summary:a,when_to_use:i,steps:Array.isArray(t.steps)?t.steps.map(Ud).filter(o=>o!==null):[]}}function Wd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:rt(t.tools)}}function Gd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),i=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!i||!o||!r?null:{id:e,title:n,symptom:a,why:i,fix_tool:o,fix_summary:r}}function Jd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),i=u(t.transport);return!e||!n||!a||!i?null:{id:e,title:n,path_id:a,transport:i,request:t.request,response:t.response,notes:rt(t.notes)}}function Vd(t){const e=T(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Kd).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Hd).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Bd).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Wd).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Gd).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Jd).filter(n=>n!==null):[]}}function Qd(t){if(!T(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{id:e,title:n,status:a,detail:i,next_tool:o}}function Yd(t){if(!T(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),i=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!i||!o?null:{code:e,severity:n,title:a,detail:i,next_tool:o}}function Xd(t){if(!T(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),i=h(t.seq);return!e||!n||!a||i==null?null:{seq:i,from:e,content:n,timestamp:a}}function Zd(t){if(!T(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),i=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),d=u(t.final_marker);if(!e||!n||!a||!i||!o||!r||!d)return null;const p=(()=>{if(!T(t.last_message))return null;const _=h(t.last_message.seq),m=u(t.last_message.content),c=u(t.last_message.timestamp);return _==null||!m||!c?null:{seq:_,content:m,timestamp:c}})();return{name:e,role:n,lane:a,joined:Q(t.joined)??!1,live_presence:Q(t.live_presence)??!1,completed:Q(t.completed)??!1,status:i,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:Q(t.current_task_matches_run)??!1,squad_member:Q(t.squad_member)??!1,detachment_member:Q(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:h(t.heartbeat_age_sec)??null,heartbeat_fresh:Q(t.heartbeat_fresh)??!1,claim_marker_seen:Q(t.claim_marker_seen)??!1,done_marker_seen:Q(t.done_marker_seen)??!1,final_marker_seen:Q(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:d,last_message:p}}function tu(t){if(!T(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!T(n))return null;const a=u(n.timestamp),i=h(n.active_slots);if(!a||i==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:i,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,total_slots:h(t.total_slots),ctx_per_slot:h(t.ctx_per_slot),active_slots_now:h(t.active_slots_now),peak_active_slots:h(t.peak_active_slots),sample_count:h(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function eu(t){const e=T(t)?t:{},n=T(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:h(n.expected_workers),joined_workers:h(n.joined_workers),live_workers:h(n.live_workers),squad_roster_size:h(n.squad_roster_size),detachment_roster_size:h(n.detachment_roster_size),current_task_bound:h(n.current_task_bound),fresh_heartbeats:h(n.fresh_heartbeats),claim_markers_seen:h(n.claim_markers_seen),done_markers_seen:h(n.done_markers_seen),final_markers_seen:h(n.final_markers_seen),completed_workers:h(n.completed_workers),peak_hot_slots:h(n.peak_hot_slots),hot_window_ok:Q(n.hot_window_ok),pass_hot_concurrency:Q(n.pass_hot_concurrency),pass_end_to_end:Q(n.pass_end_to_end),pending_decisions:h(n.pending_decisions),pass:Q(n.pass)}:void 0,provider:tu(e.provider),operation:ui(e.operation),squad:di(e.squad),detachment:Vo(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Zd).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Qd).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Yd).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Xd).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Zo).filter(a=>a!==null):[],truth_notes:rt(e.truth_notes)}}function nu(t){qe.value=t,t!=="summary"&&au()}async function Ea(){ra.value=!0,ca.value=null;try{const t=await il();Uo.value=Fd(t)}catch(t){ca.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ra.value=!1}}async function pi(){la.value=!0,da.value=null;try{const t=await sl();Kt.value=jd(t)}catch(t){da.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{la.value=!1}}async function au(){Kt.value||la.value||await pi()}async function mi(){await Ea(),qe.value!=="summary"&&await pi()}async function su(){Es.value=!0,pa.value=null;try{const t=await ol();Rn.value=Vd(t)}catch(t){pa.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Es.value=!1}}async function er(t=Sd()){Ms.value=!0,ma.value=null;try{const e=await rl(t);Bo.value=eu(e)}catch(e){ma.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{Ms.value=!1}}async function ae(t,e,n){Is.value=t,ua.value=null;try{await ll(e,n),await Ea(),(Kt.value||qe.value!=="summary")&&await pi(),await er()}catch(a){throw ua.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{Is.value=null}}function iu(t){return ae(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function ou(t){return ae(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function ru(t){return ae(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function lu(t={}){return ae("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function cu(t){return ae(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function du(t){return ae(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function uu(t,e){return ae(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function pu(t,e){return ae(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Mc(()=>{Ea()});function mu(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function lt(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function vu(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function fu(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function W(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function gu(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function et(t){return Is.value===t}function vi(){return Uo.value}function _u(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function $u(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function hu(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function yu(t){return t.status==="claimed"||t.status==="in_progress"}function bu(t){const e=Rn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(i=>i.tool===t);if(a)return a}return null}function Va(t){var e;return((e=Rn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function ku(t){const e=Rn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function Xt(t){try{await t()}catch{}}function xu(){var o;const t=vi(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary;return s`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${(e==null?void 0:e.total_units)??0}</strong><small>${(e==null?void 0:e.managed_unit_count)??0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${(n==null?void 0:n.active)??0}</strong><small>${((o=t==null?void 0:t.detachments.summary)==null?void 0:o.active)??0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${(a==null?void 0:a.pending)??0}</strong><small>${(a==null?void 0:a.total)??0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${(i==null?void 0:i.bad)??0}</strong><small>${(i==null?void 0:i.warn)??0} warn</small></div>
    </div>
  `}function Su(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Au({lane:t}){const e=t.counts??{},n=Su(t);return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.source_of_truth}</div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${W(n)}">${t.phase}</span>
          <span class="command-chip ${W(n)}">${t.motion_state}</span>
          <span class="command-chip">${lt(t.last_movement_at)}</span>
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
              ${t.hard_flags.map(a=>s`<span class="command-tag ${W(a.severity)}">${a.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function wu({event:t}){return s`
    <div class="command-trace-row">
      <div class="command-trace-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${W(t.tone)}">${t.lane_id}</span>
        <span class="command-chip">${t.kind}</span>
        <span class="command-chip">${lt(t.timestamp)}</span>
      </div>
      <div class="command-card-sub">${t.source}</div>
      <div class="command-card-foot">${t.detail}</div>
    </div>
  `}function Tu({gap:t}){return s`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${t.code}</strong>
        <span class="command-chip ${W(t.severity)}">${t.count}</span>
      </div>
      <p>${t.summary}</p>
      ${t.lane_ids.length>0?s`<div class="command-tag-row">${t.lane_ids.map(e=>s`<span class="command-tag">${e}</span>`)}</div>`:null}
    </div>
  `}function Cu({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return s`
    <div class="command-guide-card ${W(e)}">
      <div class="command-guide-head">
        <strong>Hot Proof</strong>
        <span class="command-chip ${W(e)}">${(t==null?void 0:t.status)??"missing"}</span>
      </div>
      ${t?s`
            <div class="command-card-grid">
              <span>Source</span><span>${t.source}</span>
              <span>Run</span><span>${t.run_id??"n/a"}</span>
              <span>Captured</span><span>${lt(t.captured_at)}</span>
              <span>Pass</span><span>${t.pass==null?"n/a":t.pass?"yes":"no"}</span>
              <span>Peak Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>Workers</span><span>${t.workers.expected??"n/a"} expected · ${t.workers.done??"n/a"} done · ${t.workers.final??"n/a"} final</span>
            </div>
            ${t.artifact_ref?s`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?s`<p>${t.missing_reason}</p>`:null}
          `:s`<p>No swarm proof is available yet.</p>`}
    </div>
  `}function Nu(){const t=vi(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(p=>p.present))??[],i=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,6))??[],r=e==null?void 0:e.overview,d=e==null?void 0:e.recommended_next_action;return s`
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${e?s`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${lt(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`snapshot ${lt(e.generated_at)}`:"snapshot now"}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${(d==null?void 0:d.label)??"Observe operator state"}</strong><small>${(d==null?void 0:d.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${a.length>0?a.map(p=>s`<${Au} lane=${p} />`):s`<div class="empty-state">No active swarm lanes.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(d==null?void 0:d.label)??"Observe operator state"}</strong>
                    <span class="command-chip">${(d==null?void 0:d.lane_id)??"global"}</span>
                  </div>
                  <p>${(d==null?void 0:d.reason)??"No active swarm lane is visible yet."}</p>
                  <div class="command-card-foot">${(d==null?void 0:d.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Cu} proof=${n} />

                <div class="command-guide-card ${i.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${W(i.some(p=>p.severity==="bad")?"bad":i.length>0?"warn":"ok")}">${i.length}</span>
                  </div>
                  ${i.length>0?s`<div class="command-card-stack">${i.slice(0,4).map(p=>s`<${Tu} gap=${p} />`)}</div>`:s`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${o.length}</span>
                  </div>
                  ${o.length>0?s`<div class="command-card-stack">${o.map(p=>s`<${wu} event=${p} />`)}</div>`:s`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `:s`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `}function Ru(){return s`
    <div class="command-surface-tabs">
      ${["summary","swarm","operations","topology","alerts","trace","control"].map(e=>s`
        <button
          class="command-surface-tab ${qe.value===e?"active":""}"
          onClick=${()=>nu(e)}
        >
          ${e}
        </button>
      `)}
    </div>
  `}function Lu(){var St,At,B,X,k,Lt,Jt,ie,oe;const t=vi(),e=Kt.value,n=ne.value,a=_u(),i=a?kt.value.find(I=>I.name===a)??null:null,o=a?gt.value.filter(I=>I.assignee===a&&yu(I)):[],r=((St=t==null?void 0:t.operations.summary)==null?void 0:St.active)??0,d=((At=t==null?void 0:t.detachments.summary)==null?void 0:At.total)??0,p=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,_=e==null?void 0:e.detachments.detachments.find(I=>{const Dt=I.detachment.heartbeat_deadline,re=Dt?Date.parse(Dt):Number.NaN;return I.detachment.status==="stalled"||!Number.isNaN(re)&&re<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(I=>I.severity==="bad"),c=!!(n!=null&&n.room||n!=null&&n.project),l=(i==null?void 0:i.current_task)??null,g=hu(i==null?void 0:i.last_seen),y=g!=null?g<=120:null,x=[c?{title:"Room readiness",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room readiness",tone:"bad",detail:"No room snapshot yet. Set room to repo root before joining.",tool:"masc_set_room"},a?i?o.length===0?{title:"Task readiness",tone:"warn",detail:`${a} has no claimed task. Claim one or create one first.`,tool:gt.value.length>0?"masc_claim":"masc_add_task"}:l?y===!1?{title:"Task readiness",tone:"warn",detail:`${a} current_task=${l}, but heartbeat is stale (${g}s).`,tool:"masc_heartbeat"}:{title:"Task readiness",tone:"ok",detail:`${a} current_task=${l}${g!=null?` · last seen ${g}s ago`:""}`,tool:"masc_plan_get_task"}:{title:"Task readiness",tone:"bad",detail:`${a} has a claimed task but no session current_task binding.`,tool:"masc_plan_set_task"}:{title:"Task readiness",tone:"bad",detail:`${a} is not visible in the room roster.`,tool:"masc_join"}:{title:"Task readiness",tone:"warn",detail:"No ?agent= query param. Dashboard can show room health but not agent-specific next steps.",tool:"masc_join"},!t||(((X=t.topology.summary)==null?void 0:X.managed_unit_count)??0)===0?{title:"Operation readiness",tone:"warn",detail:"No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.",tool:"masc_unit_define"}:r===0?{title:"Operation readiness",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0} managed units are ready, but there is no active operation.`,tool:"masc_operation_start"}:{title:"Operation readiness",tone:"ok",detail:`${r} active operation(s) across ${((Lt=t.topology.summary)==null?void 0:Lt.managed_unit_count)??0} managed unit(s).`,tool:"masc_observe_operations"},p>0?{title:"Dispatch readiness",tone:"warn",detail:`${p} pending approval(s) are blocking strict actions.`,tool:"masc_policy_approve"}:r>0&&d===0?{title:"Dispatch readiness",tone:"bad",detail:"Active operation exists but no detachment has been materialized yet.",tool:"masc_dispatch_tick"}:_||m?{title:"Dispatch readiness",tone:"warn",detail:`Dispatch needs reconciliation${_?` · detachment ${_.detachment.detachment_id} is stalled`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!_&&!m?" · open a detail tab to inspect the exact source.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"Dispatch readiness",tone:"ok",detail:`${d} detachment(s) visible and no strict approval backlog${e?"":" · detail panes stay lazy until opened."}.`,tool:"masc_detachment_list"}],C=c?!a||!i?"masc_join":o.length===0?gt.value.length>0?"masc_claim":"masc_add_task":l?y===!1?"masc_heartbeat":!t||(((Jt=t.topology.summary)==null?void 0:Jt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&d===0||_||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",E=bu(C),O=ku(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=Va("room_task_hygiene"),D=Va("cpv2_benchmark"),ut=Va("supervisor_session"),ct=((ie=Rn.value)==null?void 0:ie.docs)??[],se=[R,D,ut].filter(I=>I!==null);return s`
    <div class="command-guide-grid">
      <section class="card command-section">
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${x.map(I=>s`
            <article class="command-guide-card ${W(I.tone)}">
              <div class="command-guide-head">
                <strong>${I.title}</strong>
                <span class="command-chip ${W(I.tone)}">${I.tone}</span>
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
          <div class="command-guide-head">
            <strong>${(E==null?void 0:E.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(E==null?void 0:E.summary)??"Use the next tool in the canonical flow to remove the current blocker."}</p>
          ${(oe=E==null?void 0:E.success_signals)!=null&&oe.length?s`<div class="command-tag-row">
                ${E.success_signals.map(I=>s`<span class="command-tag ok">${I}</span>`)}
              </div>`:null}
          ${O.length>0?s`<div class="command-guide-list">
                ${O.map(I=>s`
                  <article class="command-guide-inline">
                    <strong>${I.title}</strong>
                    <div>${I.symptom}</div>
                    <div class="command-card-sub">Fix with ${I.fix_tool}: ${I.fix_summary}</div>
                  </article>
                `)}
              </div>`:null}
        </article>
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${Es.value?s`<div class="empty-state">Loading CPv2 runbook…</div>`:pa.value?s`<div class="empty-state error">${pa.value}</div>`:s`
                <div class="command-guide-paths">
                  ${se.map(I=>s`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${I.title}</strong>
                        <span class="command-chip">${I.id}</span>
                      </div>
                      <p>${I.summary}</p>
                      <div class="command-card-sub">${I.when_to_use}</div>
                      <div class="command-step-list">
                        ${I.steps.map(Dt=>s`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Dt.tool}</span>
                            <span>${Dt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${ct.length>0?s`<div class="command-doc-links">
                      ${ct.map(I=>s`<span class="command-tag">${I.title}: ${I.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Du(){return s`
    <${xu} />
    <${Nu} />
    <${Lu} />
  `}function Pu(){return la.value?s`<div class="empty-state">Loading command-plane detail…</div>`:da.value?s`<div class="empty-state error">${da.value}</div>`:s`<div class="empty-state">Select a surface to load command-plane detail.</div>`}function nr({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,i=t.active_operation_count??0,o=t.unit.policy;return s`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${gu(t.unit.kind)}</span>
            <span class="command-chip ${W(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>s`<${nr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Iu({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,i=`recall:${e.operation_id}`;return s`
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
        <span>Updated</span><span>${lt(e.updated_at)}</span>
      </div>
      ${e.checkpoint_ref?s`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        ${e.source==="managed"&&e.status==="active"?s`
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Xt(()=>iu(e.operation_id))}>
                ${et(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${et(i)} onClick=${()=>Xt(()=>ru(e.operation_id))}>
                ${et(i)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?s`
              <button class="control-btn ghost" disabled=${et(a)} onClick=${()=>Xt(()=>ou(e.operation_id))}>
                ${et(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Eu({card:t}){var n;const e=t.detachment;return s`
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
        <span>Progress</span><span>${lt(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${fu(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${lt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?s`<span class="command-tag ${vu(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Mu({alert:t}){return s`
    <article class="command-alert ${W(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${W(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${lt(t.timestamp)}</span>
      </div>
      ${t.detail?s`<p>${t.detail}</p>`:null}
    </article>
  `}function ar({event:t}){return s`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${lt(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${mu(t.detail)}</pre>
    </article>
  `}function Ou({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
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
        <span>Created</span><span>${lt(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?s`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${et(e)} onClick=${()=>Xt(()=>cu(t.decision_id))}>
                ${et(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Xt(()=>du(t.decision_id))}>
                ${et(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?s`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function zu({row:t}){var d,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,i=!!((d=e.policy)!=null&&d.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return s`
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
        <span>Frozen</span><span>${i?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${et(n)} onClick=${()=>Xt(()=>uu(e.unit_id,!i))}>
          ${et(n)?"Applying…":i?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${et(a)} onClick=${()=>Xt(()=>pu(e.unit_id,!o))}>
          ${et(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function qu({item:t}){return s`
    <article class="command-guide-card ${W(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${W(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function ju({blocker:t}){return s`
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
  `}function Fu({worker:t}){return s`
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
      ${t.last_message?s`<div class="command-card-foot">${lt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Ku(){var n,a,i,o,r,d,p,_,m,c,l,g,y,x,C,E;const t=Bo.value,e=$u();return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Swarm Live Run</div>
        ${Ms.value?s`<div class="empty-state">Loading swarm live state…</div>`:ma.value?s`<div class="empty-state error">${ma.value}</div>`:t?s`
                  <div class="command-summary-grid">
                    <div class="monitor-stat-card"><span>Run</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room n/a"}</small></div>
                    <div class="monitor-stat-card"><span>Workers</span><strong>${((n=t.summary)==null?void 0:n.joined_workers)??0}/${((a=t.summary)==null?void 0:a.expected_workers)??0}</strong><small>${((i=t.summary)==null?void 0:i.live_workers)??0} live · ${((o=t.summary)==null?void 0:o.completed_workers)??0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${((r=t.provider)==null?void 0:r.active_slots_now)??0}/${((d=t.provider)==null?void 0:d.total_slots)??0}</strong><small>peak ${((p=t.summary)==null?void 0:p.peak_hot_slots)??0} · ctx ${((_=t.provider)==null?void 0:_.ctx_per_slot)??0}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${(m=t.summary)!=null&&m.pass_hot_concurrency?"pass":"check"}</strong><small>${((c=t.provider)==null?void 0:c.slot_url)??"slot n/a"}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${(l=t.summary)!=null&&l.pass_end_to_end?"pass":"check"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                  </div>
                  <div class="command-card-grid">
                    <span>Operation</span><span>${((g=t.operation)==null?void 0:g.operation_id)??"none"}</span>
                    <span>Squad</span><span>${((y=t.squad)==null?void 0:y.label)??"none"}</span>
                    <span>Detachment</span><span>${((x=t.detachment)==null?void 0:x.detachment_id)??"none"}</span>
                    <span>Expected</span><span>${((C=t.summary)==null?void 0:C.expected_workers)??0} workers</span>
                    <span>Final Markers</span><span>${((E=t.summary)==null?void 0:E.final_markers_seen)??0}</span>
                    <span>Recommended</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                  </div>
                  ${t.truth_notes.length>0?s`<div class="command-tag-row">
                        ${t.truth_notes.map(L=>s`<span class="command-tag">${L}</span>`)}
                      </div>`:null}
                `:s`<div class="empty-state">No swarm read-model yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Checklist</div>
        ${t&&t.checklist.length>0?s`<div class="command-card-stack">
              ${t.checklist.map(L=>s`<${qu} item=${L} />`)}
            </div>`:s`<div class="empty-state">No checklist yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Workers</div>
        ${t&&t.workers.length>0?s`<div class="command-card-stack">
              ${t.workers.map(L=>s`<${Fu} worker=${L} />`)}
            </div>`:s`<div class="empty-state">No worker rows yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Runtime</div>
        ${t!=null&&t.provider?s`
              <div class="command-card-grid">
                <span>Slot URL</span><span>${t.provider.slot_url??"n/a"}</span>
                <span>Total Slots</span><span>${t.provider.total_slots??0}</span>
                <span>Active Now</span><span>${t.provider.active_slots_now??0}</span>
                <span>Peak Active</span><span>${t.provider.peak_active_slots??0}</span>
                <span>Sample Count</span><span>${t.provider.sample_count??0}</span>
                <span>Last Sample</span><span>${t.provider.last_sample_at?lt(t.provider.last_sample_at):"n/a"}</span>
              </div>
              ${t.provider.timeline.length>0?s`<div class="command-trace-stack">
                    ${t.provider.timeline.slice(-12).map(L=>s`
                      <article class="command-trace-row">
                        <div class="command-trace-main">
                          <div class="command-trace-head">
                            <strong>${L.active_slots} active</strong>
                            <span class="command-chip">${lt(L.timestamp)}</span>
                          </div>
                          <div class="command-card-sub">slots ${L.active_slot_ids.join(", ")||"none"}</div>
                        </div>
                      </article>
                    `)}
                  </div>`:s`<div class="empty-state">No slot telemetry captured yet.</div>`}
            `:s`<div class="empty-state">No runtime telemetry yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Blockers</div>
        ${t&&t.blockers.length>0?s`<div class="command-card-stack">
              ${t.blockers.map(L=>s`<${ju} blocker=${L} />`)}
            </div>`:s`<div class="empty-state">No blockers. Use ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} for the next action.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Messages</div>
        ${t&&t.recent_messages.length>0?s`<div class="command-trace-stack">
              ${t.recent_messages.map(L=>s`
                <article class="command-trace-row">
                  <div class="command-trace-main">
                    <div class="command-trace-head">
                      <strong>${L.from}</strong>
                      <span class="command-chip">${lt(L.timestamp)}</span>
                    </div>
                    <div class="command-card-sub">seq ${L.seq}</div>
                  </div>
                  <pre class="command-trace-detail">${L.content}</pre>
                </article>
              `)}
            </div>`:s`<div class="empty-state">No run-scoped broadcasts captured yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Trace Events</div>
        ${t&&t.recent_trace_events.length>0?s`<div class="command-trace-stack">
              ${t.recent_trace_events.map(L=>s`<${ar} event=${L} />`)}
            </div>`:s`<div class="empty-state">No run-scoped trace events captured yet.</div>`}
      </section>
    </div>
  `}function Hu(){const t=Kt.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?s`<div class="command-card-stack">
              ${t.operations.operations.map(e=>s`<${Iu} card=${e} />`)}
            </div>`:s`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?s`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>s`<${Eu} card=${e} />`)}
            </div>`:s`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Uu(){const t=Kt.value;return s`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?s`${t.topology.units.map(e=>s`<${nr} node=${e} />`)}`:s`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function Bu(){const t=Kt.value;return s`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?s`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>s`<${Mu} alert=${e} />`)}
          </div>`:s`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function Wu(){const t=Kt.value;return s`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?s`<div class="command-trace-stack">
            ${t.traces.events.map(e=>s`<${ar} event=${e} />`)}
          </div>`:s`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function Gu(){const t=Kt.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?s`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>s`<${Ou} decision=${e} />`)}
            </div>`:s`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?s`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>s`<${zu} row=${e} />`)}
            </div>`:s`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function Ju(){if(qe.value==="summary")return s`<${Du} />`;if(!Kt.value)return s`<${Pu} />`;switch(qe.value){case"swarm":return s`<${Ku} />`;case"topology":return s`<${Uu} />`;case"alerts":return s`<${Bu} />`;case"trace":return s`<${Wu} />`;case"control":return s`<${Gu} />`;case"operations":default:return s`<${Hu} />`}}function Vu(){return bt(()=>{su(),er()},[]),s`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Xt(()=>lu())}}
            disabled=${et("dispatch:tick")}
          >
            ${et("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{mi()}} disabled=${ra.value}>
            ${ra.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${ca.value?s`<div class="empty-state error">${ca.value}</div>`:null}
      ${ua.value?s`<div class="empty-state error">${ua.value}</div>`:null}
      <${Ru} />
      <${Ju} />
    </section>
  `}const Ln=f(null),va=f(!1),ee=f(null),H=f(!1),fa=f([]);let Qu=1;function U(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function vt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function sr(t){return typeof t=="boolean"?t:void 0}function Yu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Se(t,e=[]){if(Array.isArray(t))return t;if(!U(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Xu(t){return U(t)?{id:P(t.id),seq:vt(t.seq),from:P(t.from)??P(t.from_agent)??"system",content:P(t.content)??"",timestamp:P(t.timestamp)??new Date().toISOString(),type:P(t.type)}:null}function Zu(t){return U(t)?{room_id:P(t.room_id),current_room:P(t.current_room)??P(t.room),project:P(t.project),cluster:P(t.cluster),paused:sr(t.paused),pause_reason:P(t.pause_reason)??null,paused_by:P(t.paused_by)??null,paused_at:P(t.paused_at)??null}:{}}function Ki(t){if(!U(t))return;const e=Object.entries(t).map(([n,a])=>{const i=P(a);return i?[n,i]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function tp(t){if(!U(t))return null;const e=U(t.status)?t.status:void 0,n=U(t.summary)?t.summary:U(e==null?void 0:e.summary)?e.summary:void 0,a=U(t.session)?t.session:U(e==null?void 0:e.session)?e.session:void 0,i=P(t.session_id)??P(n==null?void 0:n.session_id)??P(a==null?void 0:a.session_id);if(!i)return null;const o=Ki(t.report_paths)??Ki(e==null?void 0:e.report_paths),r=Se(t.recent_events,["events"]).filter(U);return{session_id:i,status:P(t.status)??P(n==null?void 0:n.status)??P(a==null?void 0:a.status),progress_pct:vt(t.progress_pct)??vt(n==null?void 0:n.progress_pct),elapsed_sec:vt(t.elapsed_sec)??vt(n==null?void 0:n.elapsed_sec),remaining_sec:vt(t.remaining_sec)??vt(n==null?void 0:n.remaining_sec),done_delta_total:vt(t.done_delta_total)??vt(n==null?void 0:n.done_delta_total),summary:n,team_health:U(t.team_health)?t.team_health:U(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:U(t.communication_metrics)?t.communication_metrics:U(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:U(t.orchestration_state)?t.orchestration_state:U(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:U(t.cascade_metrics)?t.cascade_metrics:U(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function ep(t){if(!U(t))return null;const e=P(t.name);if(!e)return null;const n=U(t.context)?t.context:void 0;return{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:vt(t.context_ratio)??vt(n==null?void 0:n.context_ratio),generation:vt(t.generation),active_goal_ids:Yu(t.active_goal_ids),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:vt(t.last_turn_ago_s),model:P(t.model)??P(t.active_model)??P(t.primary_model)}}function np(t){if(!U(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function ap(t){const e=U(t)?t:{};return{room:Zu(e.room),sessions:Se(e.sessions,["items","sessions"]).map(tp).filter(n=>n!==null),keepers:Se(e.keepers,["items","keepers"]).map(ep).filter(n=>n!==null),recent_messages:Se(e.recent_messages,["messages"]).map(Xu).filter(n=>n!==null),pending_confirms:Se(e.pending_confirms,["items","confirms"]).map(np).filter(n=>n!==null),available_actions:Se(e.available_actions,["actions"]).filter(U).map(n=>({action_type:P(n.action_type)??"unknown",target_type:P(n.target_type)??"unknown",description:P(n.description),confirm_required:sr(n.confirm_required)}))}}function In(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Hi(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ga(t){fa.value=[{...t,id:Qu++,at:new Date().toISOString()},...fa.value].slice(0,20)}function ir(t){return t.confirm_required?In(t.preview)||"Confirmation required":In(t.result)||In(t.executed_action)||In(t.delegated_tool_result)||t.status}async function je(){va.value=!0,ee.value=null;try{const t=await al();Ln.value=ap(t)}catch(t){ee.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{va.value=!1}}async function sp(t){H.value=!0,ee.value=null;try{const e=await Nn(t);return ga({actor:t.actor,action_type:t.action_type,target_label:Hi(t),outcome:e.confirm_required?"preview":"executed",message:ir(e),delegated_tool:e.delegated_tool}),await je(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ee.value=n,ga({actor:t.actor,action_type:t.action_type,target_label:Hi(t),outcome:"error",message:n}),e}finally{H.value=!1}}async function ip(t,e){H.value=!0,ee.value=null;try{const n=await dl(t,e);return ga({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:ir(n),delegated_tool:n.delegated_tool}),await je(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ee.value=a,ga({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{H.value=!1}}const or="masc_dashboard_agent_name";function op(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(or))==null?void 0:a.trim())||"dashboard"}const Ma=f(op()),an=f(""),Os=f("Operator pause"),sn=f(""),_a=f(""),zs=f("2"),$a=f(""),Ie=f("note"),ha=f(""),ya=f(""),ba=f(""),qs=f("2"),js=f("Operator stop request"),Fs=f(""),on=f("");function rp(t){const e=t.trim()||"dashboard";Ma.value=e,localStorage.setItem(or,e)}function Ui(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function lp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function ka(t){return typeof t=="string"?t.trim().toLowerCase():""}function cp(t){var a;const e=ka(t.status);if(e==="paused")return"bad";const n=ka((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Bi(t){const e=ka(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function ge(t){const e=Ma.value.trim()||"dashboard";try{const n=await sp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?A("Confirmation queued","warning"):A(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return A(a,"error"),null}}async function Wi(){const t=an.value.trim();if(!t)return;await ge({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(an.value="")}async function dp(){await ge({action_type:"room_pause",target_type:"room",payload:{reason:Os.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function up(){await ge({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function pp(){const t=sn.value.trim();if(!t)return;await ge({action_type:"task_inject",target_type:"room",payload:{title:t,description:_a.value.trim()||"Injected from Ops tab",priority:Number.parseInt(zs.value,10)||2},successMessage:"Task injection submitted"})&&(sn.value="",_a.value="")}async function mp(){var o;const t=Ln.value,e=$a.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){A("Select a team session first","warning");return}const n={turn_kind:Ie.value},a=ha.value.trim();a&&(n.message=a),Ie.value==="task"&&(n.task_title=ya.value.trim()||"Operator injected task",n.task_description=ba.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(qs.value,10)||2),await ge({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(ha.value="",Ie.value==="task"&&(ya.value="",ba.value=""))}async function vp(){var n;const t=Ln.value,e=$a.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){A("Select a team session first","warning");return}await ge({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:js.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function fp(){var i;const t=Ln.value,e=Fs.value||((i=t==null?void 0:t.keepers[0])==null?void 0:i.name)||"",n=on.value.trim();if(!e){A("Select a keeper first","warning");return}if(!n)return;await ge({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(on.value="")}async function gp(t){const e=Ma.value.trim()||"dashboard";try{await ip(e,t),A("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";A(a,"error")}}function _p(){var c;const t=Ln.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],i=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(l=>l.session_id===$a.value)??n[0]??null,d=a.find(l=>l.name===Fs.value)??a[0]??null,p=n.filter(l=>cp(l)!=="ok"),_=a.filter(l=>Bi(l)!=="ok"),m=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:i.length,detail:i.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:i.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(l=>ka(l.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:_.length,detail:_.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:_.some(l=>Bi(l)==="bad")?"bad":_.length>0?"warn":"ok"}];return s`
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
            value=${Ma.value}
            onInput=${l=>rp(l.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{je()}} disabled=${va.value||H.value}>
            ${va.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${ee.value?s`
        <section class="ops-banner error">${ee.value}</section>
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
                ${l.preview?s`<pre class="ops-code-block">${Ui(l.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{gp(l.confirm_token)}} disabled=${H.value}>
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
              value=${an.value}
              onInput=${l=>{an.value=l.target.value}}
              onKeyDown=${l=>{l.key==="Enter"&&Wi()}}
              disabled=${H.value}
            />
            <button class="control-btn" onClick=${()=>{Wi()}} disabled=${H.value||an.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Os.value}
              onInput=${l=>{Os.value=l.target.value}}
              disabled=${H.value}
            />
            <button class="control-btn ghost" onClick=${()=>{dp()}} disabled=${H.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{up()}} disabled=${H.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${sn.value}
            onInput=${l=>{sn.value=l.target.value}}
            disabled=${H.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${_a.value}
            onInput=${l=>{_a.value=l.target.value}}
            disabled=${H.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${zs.value}
              onChange=${l=>{zs.value=l.target.value}}
              disabled=${H.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{pp()}} disabled=${H.value||sn.value.trim()===""}>
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
                onClick=${()=>{$a.value=l.session_id}}
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
                <pre class="ops-code-block compact">${Ui(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Ie.value}
              onChange=${l=>{Ie.value=l.target.value}}
              disabled=${H.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{mp()}} disabled=${H.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${ha.value}
            onInput=${l=>{ha.value=l.target.value}}
            disabled=${H.value||!r}
          ></textarea>
          ${Ie.value==="task"?s`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${ya.value}
              onInput=${l=>{ya.value=l.target.value}}
              disabled=${H.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${ba.value}
              onInput=${l=>{ba.value=l.target.value}}
              disabled=${H.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${qs.value}
              onChange=${l=>{qs.value=l.target.value}}
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
              value=${js.value}
              onInput=${l=>{js.value=l.target.value}}
              disabled=${H.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{vp()}} disabled=${H.value||!r}>
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
                onClick=${()=>{Fs.value=l.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${l.name}</strong>
                  <span class="status-badge ${l.status??"idle"}">${l.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${l.model??"model n/a"}</span>
                  <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${lp(l.last_turn_ago_s)}</span>
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
            value=${on.value}
            onInput=${l=>{on.value=l.target.value}}
            disabled=${H.value||!d}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{fp()}} disabled=${H.value||!d||on.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${fa.value.length===0?s`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:fa.value.map(l=>s`
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
  `}function $p({text:t}){if(!t)return null;const e=hp(t);return s`<div class="markdown-content">${e}</div>`}function hp(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const i=e[a];if(/^(`{3,}|~{3,})/.test(i)){const r=i.match(/^(`{3,}|~{3,})/)[0],d=i.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(s`<pre><code class=${d?`language-${d}`:""}>${p.join(`
`)}</code></pre>`);continue}if(i.trim()==="<think>"||i.trim().startsWith("<think>")){const r=[],d=i.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&r.push(d),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const _=e[a].replace("</think>","").trim();_&&r.push(_),a++}const p=r.join(`
`).trim();n.push(s`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Qa(p)}</div>
        </details>
      `);continue}if(i.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${Qa(r.join(`
`))}</blockquote>`);continue}if(i.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(s`<p>${Qa(o.join(`
`))}</p>`)}return n}function Qa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,i;for(;(i=n.exec(t))!==null;){if(i.index>a&&e.push(t.slice(a,i.index)),i[1]){const o=i[1].slice(1,-1);e.push(s`<code>${o}</code>`)}else if(i[2]){const o=i[2].slice(2,-2);e.push(s`<strong>${o}</strong>`)}else if(i[3]){const o=i[3].slice(1,-1);e.push(s`<em>${o}</em>`)}else i[4]&&i[5]&&e.push(s`<a href=${i[5]} target="_blank" rel="noopener">${i[4]}</a>`);a=i.index+i[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Ze=f("posts"),Ks=f([]),Hs=f([]),rn=f(""),xa=f(!1),ln=f(!1),An=f(""),Sa=f(null),Tt=f(null),Us=f(!1),Yt=f(null),Jn=f(null);async function Oa(){xa.value=!0,An.value="";try{const[t,e]=await Promise.all([Gl(),Jl()]);Ks.value=t,Hs.value=e,Yt.value=!0,Jn.value=Date.now()}catch(t){An.value=t instanceof Error?t.message:"Failed to load council data",Yt.value=!1}finally{xa.value=!1}}Ec(Oa);async function Gi(){const t=rn.value.trim();if(t){ln.value=!0;try{const e=await Vl(t);rn.value="",A(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Oa()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";A(n,"error")}finally{ln.value=!1}}}async function yp(t){Sa.value=t,Us.value=!0,Tt.value=null;try{Tt.value=await Ql(t)}catch(e){An.value=e instanceof Error?e.message:"Failed to load debate status",Tt.value=null}finally{Us.value=!1}}const rr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Vn=f(null),cn=f([]),fe=f(!1),me=f(null),dn=f("");function bp(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const kp=f(bp()),un=f(!1);async function fi(t){me.value=t,Vn.value=null,cn.value=[],fe.value=!0;try{const e=await _l(t);if(me.value!==t)return;Vn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},cn.value=e.comments??[]}catch{me.value===t&&(Vn.value=null,cn.value=[])}finally{me.value===t&&(fe.value=!1)}}async function Ji(t){const e=dn.value.trim();if(e){un.value=!0;try{await $l(t,kp.value,e),dn.value="",A("Comment posted","success"),await fi(t),zt()}catch{A("Failed to post comment","error")}finally{un.value=!1}}}function xp(){const t=hn.value;return s`
    <div class="board-toolbar">
      <div class="board-controls">
        ${rr.map(e=>s`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{hn.value=e.id,zt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${de.value?"is-active":""}"
          onClick=${()=>{de.value=!de.value,zt()}}
        >
          ${de.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${zt} disabled=${bn.value}>
          ${bn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Bs(){var e;const t=(e=ne.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:s`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?s`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function lr({flair:t}){return t?s`<span class="post-flair ${t}">${t}</span>`:null}function Sp(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Vi(t){return t.updated_at!==t.created_at}function Ws(){var n;const t=((n=rr.find(a=>a.id===hn.value))==null?void 0:n.label)??hn.value,e=Ke.value.length;return s`
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
        <strong>${de.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ds.value?s`<${F} timestamp=${Ds.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Ap({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await $o(t.id,n),zt()}catch{A("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>Pr(t.id)}>
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
              <${lr} flair=${t.flair} />
              ${Vi(t)?s`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${F} timestamp=${t.created_at} /></span>
            ${Vi(t)?s`<span>Updated <${F} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?s`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Sp(t.content)}</div>
      </div>
    </div>
  `}function wp({comments:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No comments yet</div>`:s`
    <div class="comment-thread">
      ${t.map(e=>s`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Tp({postId:t}){return s`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${dn.value}
        onInput=${e=>{dn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Ji(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${un.value}
      />
      <button
        onClick=${()=>Ji(t)}
        disabled=${un.value||dn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${un.value?"...":"Post"}
      </button>
    </div>
  `}function Cp({post:t}){me.value!==t.id&&!fe.value&&fi(t.id);const e=async n=>{try{await $o(t.id,n),zt()}catch{A("Failed to vote","error")}};return s`
    <div>
      <button class="back-btn" onClick=${()=>Mt("board")}>← Back to Board</button>
      <${w} title=${s`${t.title} <${lr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${$p} text=${t.content} />
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

      <${w} title="Comments (${fe.value?"...":cn.value.length})">
        ${fe.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${wp} comments=${cn.value} />`}
        <${Tp} postId=${t.id} />
      <//>
    </div>
  `}function Np({debate:t}){const e=Sa.value===t.id;return s`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>yp(t.id)}
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
  `}function Rp({session:t}){return s`
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
  `}function cr(){return Yt.value===null||Yt.value&&!Jn.value?null:s`
    <div class="feed-health-banner ${Yt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Yt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${Jn.value?s`<span class="feed-health-meta">Last sync: <${F} timestamp=${Jn.value} /></span>`:s`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Lp(){const t=Yt.value===!1;return s`
    <div>
      <${cr} />
      <${w} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${rn.value}
            onInput=${e=>{rn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Gi()}}
            disabled=${ln.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Gi}
            disabled=${ln.value||rn.value.trim()===""}
          >
            ${ln.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Oa} disabled=${xa.value}>
            ${xa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${An.value?s`<div class="council-error">${An.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section">
        <div class="council-list">
          ${Ks.value.length===0?s`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:Ks.value.map(e=>s`<${Np} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${w} title=${Sa.value?`Debate Detail (${Sa.value})`:"Debate Detail"} class="section">
        ${Us.value?s`<div class="loading-indicator">Loading debate detail...</div>`:Tt.value?s`
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
  `}function Dp(){const t=Yt.value===!1;return s`
    <div>
      <${cr} />
      <${w} title="Voting Sessions" class="section">
        <div class="council-list">
          ${Hs.value.length===0?s`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:Hs.value.map(e=>s`<${Rp} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Pp(){const t=Ze.value;return s`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{Ze.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{Ze.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{Ze.value="voting"}}>Voting</button>
    </div>
  `}function Ip(){var a,i;const t=Ke.value,e=bn.value,n=((i=(a=ne.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;return s`
    <div>
      <${Bs} />
      <${Ws} />
      <${xp} />
      ${e?s`<div class="loading-indicator">Loading board...</div>`:t.length===0?s`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":de.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:s`<div class="board-post-list">
              ${t.map(o=>s`<${Ap} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function Ep(){var i,o;const t=Ke.value,e=Nt.value.postId,n=((o=(i=ne.value)==null?void 0:i.data_quality)==null?void 0:o.board_contract_ok)===!1,a=Ze.value;if(bt(()=>{(a==="debates"||a==="voting")&&Oa()},[a]),e){const r=t.find(d=>d.id===e)??(me.value===e?Vn.value:null);return!r&&me.value!==e&&!fe.value&&fi(e),r?s`
          <${Bs} />
          <${Ws} />
          <${Cp} post=${r} />
        `:s`
          <div>
            <${Bs} />
            <${Ws} />
            <button class="back-btn" onClick=${()=>Mt("board")}>← Back to Board</button>
            ${fe.value?s`<div class="loading-indicator">Loading post...</div>`:s`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return s`
    <${Pp} />
    ${a==="debates"?s`<${Lp} />`:a==="voting"?s`<${Dp} />`:s`<${Ip} />`}
  `}const Mp=40;function Op({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:i,className:o=""}){const r=Tr(null),[d,p]=ni({start:0,end:30}),_=t.length>Mp;if(bt(()=>{if(!_)return;const g=r.current;if(!g)return;let y=!1;const x=()=>{const{scrollTop:O,clientHeight:R}=g,D=Math.max(0,Math.floor(O/e)-n),ut=Math.min(t.length,Math.ceil((O+R)/e)+n);p(ct=>ct.start===D&&ct.end===ut?ct:{start:D,end:ut})};let C=!1;const E=()=>{C||y||(C=!0,requestAnimationFrame(()=>{y||x(),C=!1}))},L=new ResizeObserver(()=>{y||x()});return x(),g.addEventListener("scroll",E,{passive:!0}),L.observe(g),()=>{y=!0,g.removeEventListener("scroll",E),L.disconnect()}},[_,t.length,e,n]),!_)return s`
      <div class=${o}>
        ${t.map((g,y)=>a(g,y))}
      </div>
    `;const m=t.length*e,c=d.start*e,l=t.slice(d.start,d.end);return s`
    <div ref=${r} class=${o}>
      <div class="virtual-list-spacer" style=${{height:`${m}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${c}px)`}}
        >
          ${l.map((g,y)=>{const x=d.start+y;return s`<div key=${i(g)}>${a(g,x)}</div>`})}
        </div>
      </div>
    </div>
  `}function zp(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function qp(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function jp(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const dr=120,Fp=12,Kp=16,Hp=12,Gs=f("all"),Up={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Bp={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Wp(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Gp(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:zp(t),actor:qp(t),content:jp(t),timestamp:new Date(t.timestamp).toISOString()}}function Jp(t,e){var i;const n=(i=t.assignee)==null?void 0:i.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Vp(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function En(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Js(t){return t.last_heartbeat??En(t.last_turn_ago_s)??En(t.last_proactive_ago_s)??En(t.last_handoff_ago_s)??En(t.last_compaction_ago_s)}function Qp(t,e){const n=Js(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Pt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Vs=xt(()=>{const t=$n.value.map(Wp),e=ta.value.map(Gp),n=[...gt.value].sort((o,r)=>Pt(r.updated_at??r.created_at??0)-Pt(o.updated_at??o.created_at??0)).slice(0,Fp).map(Jp).filter(o=>o!==null),a=[...Ke.value].sort((o,r)=>Pt(r.updated_at||r.created_at)-Pt(o.updated_at||o.created_at)).slice(0,Kp).map(Vp),i=[...Gt.value].sort((o,r)=>Pt(Js(r)??0)-Pt(Js(o)??0)).slice(0,Hp).map(Qp).filter(o=>o!==null);return[...t,...e,...n,...a,...i].sort((o,r)=>Pt(r.timestamp)-Pt(o.timestamp))}),Yp=xt(()=>{const t=Vs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Xp=xt(()=>{const t=Gs.value;return(t==="all"?Vs.value:Vs.value.filter(n=>n.kind===t)).slice(0,dr)}),Zp=xt(()=>{const t=Ia.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return kt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const i=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return i!==0?i:Pt(a.motion.lastActivityAt??0)-Pt(n.motion.lastActivityAt??0)})});function tm(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Qe({label:t,value:e,color:n}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function em({row:t}){return s`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${tm(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Bp[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function nm(){const t=Yp.value,e=Xp.value,n=e[0],a=Zp.value;return s`
    <div class="stats-grid">
      <${Qe} label="Visible rows" value=${e.length} />
      <${Qe} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Qe} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Qe} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Qe} label="SSE events" value=${Tn.value} color="#c084fc" />
    </div>

    <${w} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(i=>s`
            <button
              class="goal-filter-btn ${Gs.value===i?"active":""}"
              onClick=${()=>{Gs.value=i}}
            >
              ${Up[i]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${jt.value?"":"pill-stale"}">
            ${jt.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?s`Latest: <${F} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${dr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?s`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:s`<${Op}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${i=>i.id}
            renderItem=${i=>s`<${em} row=${i} />`}
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
  `}function ur({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,i=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),s`
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
  `}const Ya=600*1e3,am=1200*1e3,Qi=.8;function Vt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ke(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function sm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function im(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function om(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function rm(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function lm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function cm(t){var p,_;const e=Ia.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Vt(n)):Number.POSITIVE_INFINITY,i=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",d=n?"Offline or inactive":"No recent presence"):a>am?(o="quiet",r="bad",d=i?"Working without a fresh signal":"No fresh agent signal"):i?(o="working",r=a>Ya?"warn":"ok",d=a>Ya?"Execution looks quiet for too long":"Task and live signal aligned"):a>Ya?(o="quiet",r="warn",d="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((_=t.current_task)==null?void 0:_.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function dm(t){const e=No.value.get(t.name)??"idle",n=Ro.value.has(t.name),a=t.context_ratio??0;let i="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(i="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Qi)&&(i="warning",o="warn",r=a>=Qi?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:i,tone:o,focus:rm(t),note:r}}function Ye({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function um({item:t}){const e=t.kind==="agent"?()=>Pe(t.agent.name):()=>oa(t.keeper);return s`
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
  `}function Yi({row:t}){const{agent:e,motion:n}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Pe(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ur} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Rt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${sm(t.state)}</span>
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
  `}function pm({row:t}){const{keeper:e}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>oa(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ur} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Rt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${im(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?s`<span>Heartbeat <${F} timestamp=${e.last_heartbeat} /></span>`:s`<span>No heartbeat</span>`}
        <span>${lm(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${om(e.context_ratio)}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?s`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function mm(){const t=[...kt.value].map(cm).sort((m,c)=>{const l=ke(c.tone)-ke(m.tone);if(l!==0)return l;const g=c.activeTaskCount-m.activeTaskCount;return g!==0?g:Vt(c.lastSignalAt)-Vt(m.lastSignalAt)}),e=[...Gt.value].map(dm).sort((m,c)=>{const l=ke(c.tone)-ke(m.tone);if(l!==0)return l;const g=(c.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return g!==0?g:Vt(c.keeper.last_heartbeat)-Vt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),i=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Vt(m.lastSignalAt)<=12e4).length,d=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),_=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...d.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,c)=>{const l=ke(c.tone)-ke(m.tone);return l!==0?l:Vt(c.timestamp)-Vt(m.timestamp)}).slice(0,8);return s`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ye} label="Agents online" value=${i} color="#4ade80" caption="active + idle" />
        <${Ye} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${Ye} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${Ye} label="Agent alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${Ye} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${w} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${_.length===0?s`<div class="empty-state">No agent or keeper alerts right now</div>`:_.map(m=>s`<${um} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${w} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?s`<div class="empty-state">No keepers active</div>`:e.map(m=>s`<${pm} key=${m.keeper.name} row=${m} />`)}
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
                  ${n.map(m=>s`<${Yi} key=${m.agent.name} row=${m} />`)}
                `:null}
                ${a.length>0?s`
                  <div class="agent-group-header">
                    Offline <span class="group-count">${a.length}</span>
                  </div>
                  ${a.map(m=>s`<${Yi} key=${m.agent.name} row=${m} />`)}
                `:null}
              `}
          </div>
        <//>
      </div>
    </div>
  `}const Aa=f("all"),wa=f("all"),Qs=xt(()=>{let t=yn.value;return Aa.value!=="all"&&(t=t.filter(e=>e.horizon===Aa.value)),wa.value!=="all"&&(t=t.filter(e=>e.status===wa.value)),t}),vm=xt(()=>{const t={short:[],mid:[],long:[]};for(const e of Qs.value){const n=t[e.horizon];n&&n.push(e)}return t}),fm=xt(()=>{const t=Array.from(Ao.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function gm(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function gi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Qn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function _m(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Xi(t){return t.toFixed(4)}function Zi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function $m({goal:t}){return s`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Qn(t.horizon)}">
            ${gi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${gm(t.priority)}</span>
          ${t.metric?s`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?s`<span class="goal-due">Due: <${F} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?s`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Rt} status=${t.status} />
        <div class="goal-updated">
          <${F} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function to({label:t,timestamp:e,source:n,note:a}){return s`
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
  `}function Xa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,i)=>i.priority-a.priority);return s`
    <${w} title="${gi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>s`<${$m} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function hm(){return s`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>s`
          <button
            class="goal-filter-btn ${Aa.value===t?"active":""}"
            onClick=${()=>{Aa.value=t}}
          >
            ${t==="all"?"All":gi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>s`
          <button
            class="goal-filter-btn ${wa.value===t?"active":""}"
            onClick=${()=>{wa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function ym(){const t=yn.value,e=t.filter(i=>i.status==="active").length,n=t.filter(i=>i.status==="completed").length,a={short:0,mid:0,long:0};for(const i of t)i.horizon in a&&a[i.horizon]++;return s`
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
        <div class="goal-summary-value" style="color:${Qn("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Qn("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Qn("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function bm({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return s`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Rt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Xi(t.baseline_metric)}</span>
          <span>Current ${Xi(t.current_metric)}</span>
          <span class=${Zi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Zi(t)}
          </span>
          <span>Elapsed ${_m(t.elapsed_seconds)}</span>
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
  `}function Za({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return s`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?s`<${F} timestamp=${t.created_at} />`:s`<span>-</span>`}
        ${t.assignee?s`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function km(){const{todo:t,inProgress:e,done:n}=Co.value;return s`
    <${w} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?s`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>s`<${Za} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?s`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>s`<${Za} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?s`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>s`<${Za} key=${a.id} task=${a} />`)}
          ${n.length>20?s`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function xm(){const t=vm.value,e=fm.value,n=e.filter(d=>d.status==="running").length,a=e.filter(d=>d.recoverable).length,i=yn.value.filter(d=>d.status==="active").length,o=Cs.value,r=o==="idle"?"No loop running":o==="error"?Ns.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${i}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Qs.value.length}</div>
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
            <button class="control-btn ghost" onClick=${kn} disabled=${Te.value}>
              ${Te.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Oe} disabled=${Ce.value}>
              ${Ce.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{kn(),Oe()}}
              disabled=${Te.value||Ce.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${to} label="Goals" timestamp=${wo.value} source="masc_goal_list" />
          <${to}
            label="MDAL loops"
            timestamp=${To.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section">
        <${ym} />
        <${hm} />
      <//>

      ${Te.value&&yn.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:Qs.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${Xa} horizon="short" items=${t.short??[]} />
              <${Xa} horizon="mid" items=${t.mid??[]} />
              <${Xa} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section">
        ${Ce.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?s`
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
                  ${e.map(d=>s`<${bm} key=${d.loop_id} loop=${d} />`)}
                </div>
              `}
      <//>

      <${km} />
    </div>
  `}const Ae=f(""),ts=f("ability_check"),es=f("10"),ns=f("12"),Mn=f(""),On=f("idle"),Qt=f(""),zn=f("keeper-late"),as=f("player"),ss=f(""),yt=f("idle"),is=f(null),qn=f(""),os=f(""),rs=f("player"),ls=f(""),cs=f(""),ds=f(""),pn=f("20"),us=f("20"),ps=f(""),jn=f("idle"),Ys=f(null),pr=f("overview"),ms=f("all"),vs=f("all"),fs=f("all"),Sm=12e4,za=f(null),eo=f(Date.now());function Am(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function wm(t,e){return e>0?Math.round(t/e*100):0}const Tm={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Cm={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Fn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Nm(t){const e=t.trim().toLowerCase();return Tm[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Rm(t){const e=t.trim().toLowerCase();return Cm[e]??"상황에 따라 선택되는 전술 액션입니다."}function Zt(t){return typeof t=="object"&&t!==null}function mt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function It(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function wn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Lm=new Set(["str","dex","con","int","wis","cha"]);function Dm(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(i){throw new Error(`능력치 JSON 파싱 실패: ${i instanceof Error?i.message:"invalid json"}`)}if(!Zt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([i,o])=>{const r=i.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const d=Number.parseFloat(o.trim());if(Number.isFinite(d)){a[r]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Pm(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(pn.value.trim(),10);Number.isFinite(a)&&a>n&&(pn.value=String(n))}function Xs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Im(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Em(t){pr.value=t}function mr(t){const e=za.value;return e==null||e<=t}function Mm(t){const e=za.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ta(){za.value=null}function vr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Om(t,e){vr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(za.value=Date.now()+Sm,A("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Yn(t){return mr(t)?(A("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Zs(t,e,n){return vr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function zm({hp:t,max:e}){const n=wm(t,e),a=Am(t,e);return s`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function qm({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return s`
    <div class="trpg-actor-stats">
      ${e.map(n=>s`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function jm({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return s`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function fr({actor:t}){var p,_,m,c;const e=(p=t.archetype)==null?void 0:p.trim(),n=(_=t.persona)==null?void 0:_.trim(),a=(m=t.portrait)==null?void 0:m.trim(),i=(c=t.background)==null?void 0:c.trim(),o=t.traits??[],r=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([l,g])=>Number.isFinite(g)).filter(([l])=>!Lm.has(l.toLowerCase()));return s`
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
        <${Rt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${jm} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?s`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?s`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${zm} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${qm} stats=${t.stats} />
          </div>
        `:null}
      ${e?s`<div class="trpg-actor-meta">Archetype: ${Fn(e)}</div>`:null}
      ${i?s`<div class="trpg-actor-meta">Background: ${i}</div>`:null}
      ${n?s`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([l,g])=>s`
                <span class="trpg-custom-stat-chip">${Fn(l)} ${g}</span>
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
                  <span class="trpg-annot-name">${Fn(l)}</span>
                  <span class="trpg-annot-desc">${Nm(l)}</span>
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
                  <span class="trpg-annot-name">${Fn(l)}</span>
                  <span class="trpg-annot-desc">${Rm(l)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Fm({mapStr:t}){return s`<pre class="trpg-map">${t}</pre>`}function gr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?s`<div class="empty-state" style="font-size:13px">${e}</div>`:s`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var i;return s`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Im(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Xs(n)}</strong>
            ${" "}
          ${n.dice_roll?s`<span class="trpg-dice">[${n.dice_roll.notation}: ${(i=n.dice_roll.rolls)==null?void 0:i.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Km({events:t}){const e="__none__",n=ms.value,a=vs.value,i=fs.value,o=Array.from(new Set(t.map(Xs).map(c=>c.trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),d=t.some(c=>(c.type??"").trim()===""),p=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,l)=>c.localeCompare(l)),_=t.some(c=>(c.phase??"").trim()===""),m=t.filter(c=>{if(n!=="all"&&Xs(c)!==n)return!1;const l=(c.type??"").trim(),g=(c.phase??"").trim();if(a===e){if(l!=="")return!1}else if(a!=="all"&&l!==a)return!1;if(i===e){if(g!=="")return!1}else if(i!=="all"&&g!==i)return!1;return!0});return s`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{ms.value=c.target.value}}>
          <option value="all">all</option>
          ${o.map(c=>s`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${c=>{vs.value=c.target.value}}>
          <option value="all">all</option>
          ${d?s`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>s`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${i} onChange=${c=>{fs.value=c.target.value}}>
          <option value="all">all</option>
          ${_?s`<option value=${e}>(none)</option>`:null}
          ${p.map(c=>s`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ms.value="all",vs.value="all",fs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${gr} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Hm({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",i=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return s`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?s`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${i?s`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${i}</div>`:null}
    </div>
  `}function _r({state:t}){const e=t.history??[];return e.length===0?null:s`
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
  `}function Um({state:t,nowMs:e}){var _;const n=Ht.value||((_=t.session)==null?void 0:_.room)||"",a=On.value,i=t.party??[];if(!i.find(m=>m.id===Ae.value)&&i.length>0){const m=i[0];m&&(Ae.value=m.id)}const r=async()=>{var c,l;if(!n){A("Room ID가 비어 있습니다.","error");return}if(!Yn(e))return;const m=((c=t.current_round)==null?void 0:c.phase)??((l=t.session)==null?void 0:l.status)??"unknown";if(Zs("라운드 실행",n,m)){On.value="running";try{const g=await Il(n);Ys.value=g,On.value="ok";const y=Zt(g.summary)?g.summary:null,x=y?wn(y,"advanced",!1):!1,C=y?mt(y,"progress_reason",""):"";A(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,x?"success":"warning"),qt()}catch(g){Ys.value=null,On.value="error";const y=g instanceof Error?g.message:"라운드 실행에 실패했습니다.";A(y,"error")}finally{Ta()}}},d=async()=>{var c,l;if(!n||!Yn(e))return;const m=((c=t.current_round)==null?void 0:c.phase)??((l=t.session)==null?void 0:l.status)??"unknown";if(Zs("턴 강제 진행",n,m))try{await Ol(n),A("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{A("턴 이동에 실패했습니다.","error")}finally{Ta()}},p=async()=>{if(!n||!Yn(e))return;const m=Ae.value.trim();if(!m){A("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(es.value,10),l=Number.parseInt(ns.value,10);if(Number.isNaN(c)||Number.isNaN(l)){A("stat/dc는 숫자여야 합니다.","warning");return}const g=Number.parseInt(Mn.value,10),y=Mn.value.trim()===""||Number.isNaN(g)?void 0:g;try{await Ml({roomId:n,actorId:m,action:ts.value.trim()||"ability_check",statValue:c,dc:l,rawD20:y}),A("주사위 판정을 기록했습니다.","success"),qt()}catch{A("주사위 판정 기록에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{Ht.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ae.value}
            onChange=${m=>{Ae.value=m.target.value}}
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
              value=${ts.value}
              onInput=${m=>{ts.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${es.value}
              onInput=${m=>{es.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ns.value}
              onInput=${m=>{ns.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Mn.value}
              onInput=${m=>{Mn.value=m.target.value}}
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
  `}function Bm({state:t}){var i;const e=Ht.value||((i=t.session)==null?void 0:i.room)||"",n=jn.value,a=async()=>{if(!e){A("Room ID가 비어 있습니다.","warning");return}const o=qn.value.trim(),r=os.value.trim();if(!r&&!o){A("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(pn.value.trim(),10),p=Number.parseInt(us.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(d)?Math.max(0,Math.min(_,d)):_;let c={};try{c=Dm(ps.value)}catch(l){A(l instanceof Error?l.message:"능력치 JSON 오류","error");return}jn.value="spawning";try{const l=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,g=await zl(e,{actor_id:o||void 0,name:r||void 0,role:rs.value,idempotencyKey:l,portrait:cs.value.trim()||void 0,background:ds.value.trim()||void 0,hp:m,max_hp:_,alive:m>0,stats:Object.keys(c).length>0?c:void 0}),y=typeof g.actor_id=="string"?g.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const x=ls.value.trim();x&&await ql(e,y,x),Ae.value=y,Qt.value=y,o||(qn.value=""),jn.value="ok",A(`Actor 생성 완료: ${y}`,"success"),await qt()}catch(l){jn.value="error",A(l instanceof Error?l.message:"Actor 생성에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${os.value}
            onInput=${o=>{os.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${rs.value}
            onChange=${o=>{rs.value=o.target.value}}
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
            value=${ls.value}
            onInput=${o=>{ls.value=o.target.value}}
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
              value=${cs.value}
              onInput=${o=>{cs.value=o.target.value}}
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
              value=${pn.value}
              onInput=${o=>{pn.value=o.target.value}}
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
              value=${us.value}
              onInput=${o=>{const r=o.target.value;us.value=r,Pm(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ds.value}
              onInput=${o=>{ds.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ps.value}
              onInput=${o=>{ps.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?s`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Wm({state:t,nowMs:e}){var l;const n=Ht.value||((l=t.session)==null?void 0:l.room)||"",a=t.join_gate,i=is.value,o=Zt(i)?i:null,r=(t.party??[]).filter(g=>g.role!=="dm"),d=Qt.value.trim(),p=r.some(g=>g.id===d),_=p?d:d?"__manual__":"",m=async()=>{const g=Qt.value.trim(),y=zn.value.trim();if(!n||!g){A("Room/Actor가 필요합니다.","warning");return}yt.value="checking";try{const x=await jl(n,g,y||void 0);is.value=x,yt.value="ok",A("참가 가능 여부를 갱신했습니다.","success")}catch(x){yt.value="error";const C=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";A(C,"error")}},c=async()=>{var E,L;const g=Qt.value.trim(),y=zn.value.trim(),x=ss.value.trim();if(!n||!g||!y){A("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Yn(e))return;const C=((E=t.current_round)==null?void 0:E.phase)??((L=t.session)==null?void 0:L.status)??"unknown";if(Zs("Mid-Join 승인 요청",n,C)){yt.value="requesting";try{const O=await Fl({room_id:n,actor_id:g,keeper_name:y,role:as.value,...x?{name:x}:{}});is.value=O;const R=Zt(O)?wn(O,"granted",!1):!1,D=Zt(O)?mt(O,"reason_code",""):"";R?A("Mid-Join이 승인되었습니다.","success"):A(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),yt.value=R?"ok":"error",qt()}catch(O){yt.value="error";const R=O instanceof Error?O.message:"Mid-Join 요청에 실패했습니다.";A(R,"error")}finally{Ta()}}};return s`
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
            onChange=${g=>{const y=g.target.value;if(y==="__manual__"){(p||!d)&&(Qt.value="");return}Qt.value=y}}
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
            value=${zn.value}
            onInput=${g=>{zn.value=g.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${as.value}
            onChange=${g=>{as.value=g.target.value}}
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
            value=${ss.value}
            onInput=${g=>{ss.value=g.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${yt.value==="checking"||yt.value==="requesting"}>
              ${yt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${yt.value==="checking"||yt.value==="requesting"}>
              ${yt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?s`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${wn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${It(o,"effective_score",0)}/${It(o,"required_points",0)}</span>
            ${mt(o,"reason_code","")?s`<span style="margin-left:8px;">Reason: ${mt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function $r({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?s`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:s`
    <div class="trpg-round-list">
      ${e.map(n=>s`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function hr({state:t}){var n;const e=t.current_round;return e?s`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?s`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function yr(){const t=Ys.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Zt(e)?e:null,i=(Array.isArray(t.statuses)?t.statuses:[]).filter(Zt).slice(-8),o=t.canon_check,r=Zt(o)?o:null,d=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],_=n?wn(n,"advanced",!1):!1,m=n?mt(n,"progress_reason",""):"",c=n?mt(n,"progress_detail",""):"",l=n?It(n,"player_successes",0):0,g=n?It(n,"player_required_successes",0):0,y=n?wn(n,"dm_success",!1):!1,x=n?It(n,"timeouts",0):0,C=n?It(n,"unavailable",0):0,E=n?It(n,"reprompts",0):0,L=n?It(n,"npc_attacks",0):0,O=n?It(n,"keeper_timeout_sec",0):0,R=n?It(n,"roll_audit_count",0):0;return s`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${y?"DM ok":"DM stalled"} / players ${l}/${g}
          </span>
        </div>
        ${m?s`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${c?s`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${E}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${i.length>0?s`
          <div class="trpg-round-list">
            ${i.map(D=>{const ut=mt(D,"status","unknown"),ct=mt(D,"actor_id","-"),se=mt(D,"role","-"),St=mt(D,"reason",""),At=mt(D,"action_type",""),B=mt(D,"reply","");return s`
                <div class="trpg-round-item ${ut.includes("fallback")||ut.includes("timeout")?"failed":"active"}">
                  <span>${ct} (${se})</span>
                  <span style="margin-left:auto; font-size:11px;">${ut}</span>
                  ${At?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${At}</div>`:null}
                  ${St?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${St}</div>`:null}
                  ${B?s`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?s`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${mt(r,"status","unknown")}</strong>
            </div>
            ${p.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(D=>s`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${d.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(D=>s`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Gm({state:t,nowMs:e}){var r,d,p;const n=Ht.value||((r=t.session)==null?void 0:r.room)||"",a=((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"unknown",i=mr(e),o=Mm(e);return s`
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
          ${i?s`<button class="trpg-run-btn recommend" onClick=${()=>Om(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{Ta(),A("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Jm({active:t}){return s`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>s`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Em(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Vm({state:t}){const e=t.party??[],n=t.story_log??[];return s`
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
          <${gr} events=${n.slice(-20)} />
        <//>

        ${t.map?s`
            <${w} title="맵" style="margin-top:16px;">
              <${Fm} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드">
          <${hr} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;">
          <${$r} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>s`<${fr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?s`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${_r} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Qm({state:t}){const e=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${Km} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과">
          <${yr} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;">
          <${hr} state=${t} />
        <//>
      </div>
    </div>
  `}function Ym({state:t,nowMs:e}){const n=t.party??[];return s`
    <div>
      <${Gm} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널">
            <${Um} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;">
            <${Bm} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;">
            <${Wm} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;">
            <${yr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;">
            <${$r} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>s`<${fr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?s`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${_r} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Xm(){var d,p,_,m,c;const t=So.value,e=Ls.value;if(bt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const l=window.setInterval(()=>{eo.value=Date.now()},1e3);return()=>{window.clearInterval(l)}},[]),e&&!t)return s`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return s`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>qt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],i=t.outcome,o=pr.value,r=eo.value;return s`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ht.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>qt()}>새로고침</button>
      </div>

      <${Hm} outcome=${i} />

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

      <${Jm} active=${o} />

      ${o==="overview"?s`<${Vm} state=${t} />`:o==="timeline"?s`<${Qm} state=${t} />`:s`<${Ym} state=${t} nowMs=${r} />`}
    </div>
  `}const _i="masc_dashboard_agent_name";function Zm(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(_i);return e??n??"dashboard"}const ft=f(Zm()),mn=f(""),vn=f(""),Ca=f(""),br=f(null),Na=f(null),fn=f(!1),Ne=f(!1),gn=f(!1),_n=f(!1),Ra=f(!1),La=f(!1),qa=f(!1);function Da(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Xn(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function kr(t){return!t||t.length===0?"none":t.join(", ")}function tv(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Da(t.quiet_start)}-${Da(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Xn(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${Xn(t.interval_s)}.`:`Lodge ticks every ${Xn(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ue(){Me();try{await te()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function $i(t){const e=t.trim();ft.value=e,e&&localStorage.setItem(_i,e)}function ev(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function ti(){const t=ft.value.trim();if(t){gn.value=!0;try{const e=await Hl(t),n=ev(e);n&&$i(n),qa.value=!0,await Ue(),A(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";A(n,"error")}finally{gn.value=!1}}}async function nv(){const t=ft.value.trim();if(t){_n.value=!0;try{await yo(t),qa.value=!1,await Ue(),A(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";A(n,"error")}finally{_n.value=!1}}}async function av(){const t=ft.value.trim();if(t)try{await yo(t)}catch{}localStorage.removeItem(_i),$i("dashboard"),qa.value=!1,await ti()}async function sv(){const t=ft.value.trim();if(t){Ra.value=!0;try{await Ul(t),await Ue(),A("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";A(n,"error")}finally{Ra.value=!1}}}async function no(){const t=ft.value.trim(),e=mn.value.trim();if(!(!t||!e)){fn.value=!0;try{await ho(t,e),mn.value="",await Ue(),A("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";A(a,"error")}finally{fn.value=!1}}}async function iv(){const t=vn.value.trim(),e=Ca.value.trim()||"Created from dashboard";if(t){Ne.value=!0;try{await Kl(t,e,1),vn.value="",Ca.value="",await Ue(),A("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";A(a,"error")}finally{Ne.value=!1}}}async function ao(){const t=ft.value.trim()||"dashboard";La.value=!0,Na.value=null;try{const e=await Nn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=ii(e.result);br.value=n,await Ue(),n!=null&&n.skipped_reason?A(n.skipped_reason,"warning"):A(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Na.value=n,A(n,"error")}finally{La.value=!1}}function ov({runtime:t}){var i,o;const e=br.value??(t==null?void 0:t.last_tick_result)??null;if(Na.value)return s`<div class="control-result-box is-error">${Na.value}</div>`;if(!e)return s`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((i=e.skipped_rows)==null?void 0:i.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?s`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${kr(e.acted_names)}</div>
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
  `}function rv(t){return t.find(n=>n.name===tn.value)??t[0]??null}function lv(){var a,i;const t=Gt.value,e=((a=ne.value)==null?void 0:a.lodge)??null,n=rv(t);return bt(()=>{ti()},[]),bt(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!tn.value&&o){Kn(o);return}tn.value&&!t.some(d=>d.name===tn.value)&&Kn(o)},[t.map(o=>o.name).join("|")]),s`
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
          value=${ft.value}
          onInput=${o=>$i(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ti()}}
            disabled=${gn.value||ft.value.trim()===""}
          >
            ${gn.value?"Joining...":qa.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{nv()}}
            disabled=${_n.value||ft.value.trim()===""}
          >
            ${_n.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{av()}}
            disabled=${gn.value||_n.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{sv()}}
            disabled=${Ra.value||ft.value.trim()===""}
          >
            ${Ra.value?"Pinging...":"Heartbeat"}
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
            value=${mn.value}
            onInput=${o=>{mn.value=o.target.value}}
            onKeyDown=${o=>{o.key==="Enter"&&no()}}
            disabled=${fn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{no()}}
            disabled=${fn.value||mn.value.trim()===""||ft.value.trim()===""}
          >
            ${fn.value?"Sending...":"Send"}
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
          ${t.length===0?s`<option value="">No keepers available</option>`:t.map(o=>s`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${jo} keeper=${n} />
        <${Ko}
          actor=${ft.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{ao()}}
        />
        <${Fo}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${tv(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${Xn(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Da(e==null?void 0:e.quiet_start)}-${Da(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${kr((i=e==null?void 0:e.last_tick_result)==null?void 0:i.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?s`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{ao()}}
            disabled=${La.value}
          >
            ${La.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${ov} runtime=${e} />
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
          value=${vn.value}
          onInput=${o=>{vn.value=o.target.value}}
          disabled=${Ne.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Ca.value}
          onInput=${o=>{Ca.value=o.target.value}}
          disabled=${Ne.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{iv()}}
          disabled=${Ne.value||vn.value.trim()===""}
        >
          ${Ne.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const so=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],ei=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],io="masc_dashboard_quick_actions_open";function cv(){const t=jt.value;return s`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Tn.value} events</span>
    </div>
  `}function dv(){const t=Nt.value.tab,e=jt.value,n=ei.find(r=>r.id===t),a=so.find(r=>r.id===(n==null?void 0:n.group)),[i,o]=ni(()=>{const r=localStorage.getItem(io);return r!=="0"});return bt(()=>{localStorage.setItem(io,i?"1":"0")},[i]),s`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?s`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${so.map(r=>s`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${ei.filter(d=>d.group===r.id).map(d=>s`
                  <button
                    class="rail-tab-btn ${t===d.id?"active":""}"
                    onClick=${()=>Mt(d.id)}
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
            <strong>${kt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${Gt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${gt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${Tn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{te(),t==="command"&&mi(),t==="ops"&&je(),t==="board"&&zt(),t==="trpg"&&qt(),t==="goals"&&(kn(),Oe())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>Mt("ops")}>
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
        ${i?s`<div class="rail-fold-body"><${lv} /></div>`:s`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function uv(){switch(Nt.value.tab){case"command":return s`<${Vu} />`;case"overview":return s`<${Fi} />`;case"ops":return s`<${_p} />`;case"board":return s`<${Ep} />`;case"agents":return s`<${mm} />`;case"goals":return s`<${xm} />`;case"trpg":return s`<${Xm} />`;default:return s`<${Fi} />`}}function pv(){bt(()=>{Ir(),mo(),te();const n=Oc();return zc(),()=>{Kr(),n(),qc()}},[]),bt(()=>{const n=setInterval(()=>{const a=Nt.value.tab;a==="command"?mi():a==="ops"?je():a==="board"?zt():a==="trpg"?qt():a==="goals"&&(kn(),Oe())},15e3);return()=>{clearInterval(n)}},[]),bt(()=>{const n=Nt.value.tab;n==="command"&&Ea(),n==="ops"&&je(),n==="board"&&zt(),n==="trpg"&&qt(),n==="goals"&&(kn(),Oe())},[Nt.value.tab]);const t=Nt.value.tab,e=ei.find(n=>n.id===t);return s`
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
            class="activity-panel-toggle ${ze.value?"active":""}"
            onClick=${_d}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${cv} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${dv} />
        <main class="dashboard-main">
          ${Rs.value&&!jt.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${uv} />`}
        </main>
      </div>

      ${ze.value?s`
        <div class="activity-panel-backdrop" onClick=${Mi} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${Mi}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${nm} />
          </div>
        </aside>
      `:null}

      <${fd} />
      <${Jc} />
      <${Hc} />
    </div>
  `}const oo=document.getElementById("app");oo&&Cr(s`<${pv} />`,oo);
