var vl=Object.defineProperty;var fl=(t,e,n)=>e in t?vl(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Re=(t,e,n)=>fl(t,typeof e!="symbol"?e+"":e,n);import{e as _l,_ as gl,c as _,b as Nt,y as st,d as is,A as Ho,G as $l}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const o of s)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const o={};return s.integrity&&(o.integrity=s.integrity),s.referrerPolicy&&(o.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?o.credentials="include":s.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(s){if(s.ep)return;s.ep=!0;const o=n(s);fetch(s.href,o)}})();var i=_l.bind(gl);const hl=["command","overview","board","goals","agents","ops","trpg"],Uo={tab:"overview",params:{},postId:null},yl={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Yi(t){return!!t&&hl.includes(t)}function Xi(t){if(t)return yl[t]??t}function ua(t){try{return decodeURIComponent(t)}catch{return t}}function Gs(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function bl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Bo(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=ua(t[2])),{tab:"command",params:r,postId:null}}const n=Xi(t[0]),a=Xi(e.tab),s=Yi(n)?n:Yi(a)?a:"overview";let o=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=ua(t[2]):t[0]==="post"&&t[1]&&(o=ua(t[1]))),{tab:s,params:e,postId:o}}function Sa(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Uo;const n=ua(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),s=n.slice(l+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const o=Gs(s),r=bl(a);return Bo(r,o)}function kl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Uo,params:Gs(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Gs(e.replace(/^\?/,""));return Bo(a,s)}function Wo(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const nt=_(Sa(window.location.hash));window.addEventListener("hashchange",()=>{nt.value=Sa(window.location.hash)});function ht(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=Wo(n)}function xl(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Sl(){if(window.location.hash&&window.location.hash!=="#"){nt.value=Sa(window.location.hash);return}const t=kl(window.location.pathname,window.location.search);if(t){nt.value=t;const e=Wo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",nt.value=Sa(window.location.hash)}const Zi="masc_dashboard_sse_session_id",Al=1e3,wl=15e3,Ht=_(!1),Wn=_(0),Go=_(null),Aa=_([]);function Cl(){let t=sessionStorage.getItem(Zi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Zi,t)),t}const Tl=200;function Nl(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};Aa.value=[s,...Aa.value].slice(0,Tl)}function Js(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function to(t,e){const n=Js(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Rt(t,e,n,a,s={}){Nl(t,e,n,{eventType:a,...s})}let zt=null,je=null,Vs=0;function Jo(){je&&(clearTimeout(je),je=null)}function Rl(){if(je)return;Vs++;const t=Math.min(Vs,5),e=Math.min(wl,Al*Math.pow(2,t));je=setTimeout(()=>{je=null,Vo()},e)}function Vo(){Jo(),zt&&(zt.close(),zt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Cl());const s=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(s);zt=o,o.onopen=()=>{zt===o&&(Vs=0,Ht.value=!0)},o.onerror=()=>{zt===o&&(Ht.value=!1,o.close(),zt=null,Rl())},o.onmessage=r=>{try{const l=JSON.parse(r.data);Wn.value++,Go.value=l,Ll(l)}catch{}}}function Ll(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Rt(n,"Joined","system","agent_joined");break;case"agent_left":Rt(n,"Left","system","agent_left");break;case"broadcast":Rt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Rt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Rt(n,to("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Js(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Rt(n,to("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Js(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Rt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Rt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Rt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Rt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Rt(n,e,"system","unknown")}}function Pl(){Jo(),zt&&(zt.close(),zt=null),Ht.value=!1}function Qo(){return new URLSearchParams(window.location.search)}function Yo(){const t=Qo(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Xo(){return{...Yo(),"Content-Type":"application/json"}}const Dl=15e3,Di=3e4,El=6e4,eo=new Set([408,425,429,500,502,503,504]);class Gn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,o=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Re(this,"method");Re(this,"path");Re(this,"status");Re(this,"statusText");Re(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Ei(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Gn({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(s)}}function Il(){var e,n;const t=Qo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function tt(t){const e=await Ei(t,{headers:Yo()},Dl);if(!e.ok)throw new Gn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Ml(t){return new Promise(e=>setTimeout(e,t))}function Ol(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function zl(t){if(t instanceof Gn)return t.timeout||typeof t.status=="number"&&eo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Ol(t.message);return e!==null&&eo.has(e)}async function Ye(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!zl(s)||a>=n)throw s;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,s),await Ml(o),a+=1}}async function Ut(t,e,n,a=Di){const s=await Ei(t,{method:"POST",headers:{...Xo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Gn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function ql(t,e,n,a=Di){const s=await Ei(t,{method:"POST",headers:{...Xo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Gn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function jl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Fl(t){var e,n,a,s,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(u)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function kt(t,e){const n=await ql("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},El),a=jl(n);return Fl(a)}function Kl(t="compact"){return tt(`/api/v1/dashboard?mode=${t}`)}function Hl(){return tt("/api/v1/agents?limit=100")}function Ul(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),tt(`/api/v1/tasks?${e}`)}function Bl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),tt(`/api/v1/messages?${e}`)}function Wl(t={}){return Ye("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return tt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Gl(){return tt("/api/v1/operator")}function Zo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return tt(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Jl(){return tt("/api/v1/command-plane")}function Vl(){return tt("/api/v1/command-plane/summary")}function Ql(){return tt("/api/v1/chains/summary")}function Yl(t){return tt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Xl(){return tt("/api/v1/command-plane/help")}function Zl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const a=n.toString();return tt(`/api/v1/command-plane/swarm${a?`?${a}`:""}`)}function tc(t,e){return Ut(t,e)}function ec(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Di}}function Jn(t){return Ut("/api/v1/operator/action",t,void 0,ec(t))}function nc(t,e){return Ut("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const ac=new Set(["lodge-system","team-session"]);function Be(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function sc(t){return ac.has(t.trim().toLowerCase())}function ic(t){return t.filter(e=>!sc(e.author))}function oc(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function tr(t){if(!O(t))return null;const e=y(t.id,"").trim(),n=y(t.author,"").trim(),a=y(t.content,"").trim();if(!e||!n)return null;const s=j(t.score,0),o=j(t.votes_up,0),r=j(t.votes_down,0),l=j(t.votes,s||o-r),u=j(t.comment_count,j(t.reply_count,0)),f=(()=>{const b=t.flair;if(typeof b=="string"&&b.trim())return b.trim();if(O(b)){const N=y(b.name,"").trim();if(N)return N}return y(t.flair_name,"").trim()||void 0})(),m=y(t.created_at_iso,"").trim()||Be(t.created_at),c=y(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Be(t.updated_at):m),h=y(t.title,"").trim()||oc(a);return{id:e,author:n,title:h,content:a,tags:[],votes:l,vote_balance:s,comment_count:u,created_at:m,updated_at:c,flair:f,hearth_count:j(t.hearth_count,0)}}function rc(t){if(!O(t))return null;const e=y(t.id,"").trim(),n=y(t.post_id,"").trim(),a=y(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:y(t.content,""),created_at:Be(t.created_at)}}async function lc(t,e){return Ye("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await tt(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(s.posts)?s.posts.map(tr).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?ic(o):o}})}async function cc(t){return Ye("fetchBoardPost",async()=>{const e=await tt(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=tr(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(rc).filter(r=>r!==null);return{...a,comments:o}})}function er(t,e){return Ut("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Il()})}function dc(t,e,n){return Ut("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function uc(t){const e=y(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function ut(...t){for(const e of t){const n=y(e,"");if(n.trim())return n.trim()}return""}function no(t){const e=uc(ut(t.outcome,t.result,t.result_code));if(!e)return;const n=ut(t.reason,t.reason_code,t.description,t.detail),a=ut(t.summary,t.summary_ko,t.summary_en,t.note),s=ut(t.details,t.details_text,t.text,t.note),o=ut(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=ut(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=ut(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const c=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof c=="string"?[c]:Array.isArray(c)?c.map(v=>{if(typeof v=="string")return v.trim();if(O(v)){const h=y(v.summary,"").trim();if(h)return h;const b=y(v.text,"").trim();if(b)return b;const w=y(v.type,"").trim();return w||y(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),f=(()=>{const c=j(t.turn,Number.NaN);if(Number.isFinite(c))return c;const v=j(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const h=j(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const b=j(t.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),m=ut(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:l||void 0,turn:f,phase:m||void 0}}function pc(t,e){const n=O(t.state)?t.state:{};if(y(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>O(r)?y(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=no(o);if(r)return r}if(O(s))return no(O(s.payload)?s.payload:{})}function O(t){return typeof t=="object"&&t!==null}function y(t,e=""){return typeof t=="string"?t:e}function j(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function mc(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Qs(t,e=!1){return typeof t=="boolean"?t:e}function an(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=y(e.name,"").trim(),a=y(e.id,"").trim(),s=y(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function vc(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),o=y(a,"").trim();!s||!o||(e[s]=o)}),e;for(const n of t){if(!O(n))continue;const a=ut(n.to,n.target,n.actor_id,n.name,n.id),s=ut(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function fc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function At(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const _c=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function gc(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const o=a.trim();o&&(_c.has(o.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[o]=s))}),n}function $c(t,e){if(t!=="dice.rolled")return;const n=j(e.raw_d20,0),a=j(e.total,0),s=j(e.bonus,0),o=y(e.action,"roll"),r=j(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:s}}function hc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function yc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function bc(t,e,n,a){const s=n||e||y(a.actor_id,"")||y(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=y(a.proposed_action,y(a.reply,""));return o?`${s||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=y(a.reply,y(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return y(a.reply,y(a.content,y(a.text,"Narration")));case"dice.rolled":{const o=y(a.action,"roll"),r=j(a.total,0),l=j(a.dc,0),u=y(a.label,""),f=s||"actor",m=l>0?` vs DC ${l}`:"",c=u?` (${u})`:"";return`${f} ${o}: ${r}${m}${c}`}case"turn.started":return`Turn ${j(a.turn,1)} started`;case"phase.changed":return`Phase: ${y(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${y(a.name,O(a.actor)?y(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${y(a.keeper_name,y(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${y(a.keeper_name,y(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${j(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${j(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||y(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||y(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${y(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=y(o.requested_tier,""),l=y(o.effective_tier,""),u=Qs(o.guardrail_applied,!1),f=y(a.summary_en,y(a.summary_ko,"Memory signal"));if(!r&&!l)return f;const m=r&&l?`${r}->${l}`:l||r;return`${f} [${m}${u?" (guardrail)":""}]`}case"world.event":{if(y(a.event_type,"")==="canon.check"){const r=y(a.status,"unknown"),l=y(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return y(a.description,y(a.summary,"World event"))}case"combat.attack":return y(a.summary,y(a.result,"Attack resolved"));case"combat.defense":return y(a.summary,y(a.result,"Defense resolved"));case"session.outcome":return y(a.summary,y(a.outcome,"Session ended"));default:{const o=hc(a);return o?`${t}: ${o}`:t}}}function kc(t,e){const n=O(t)?t:{},a=y(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=y(n.actor_name,"").trim()||e[s]||y(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=y(n.ts,y(n.timestamp,new Date().toISOString())),u=y(n.phase,y(r.phase,"")),f=y(n.category,"");return{type:a,actor:o||s||y(r.actor_name,""),actor_id:s||y(r.actor_id,""),actor_name:o,seq:n.seq,room_id:y(n.room_id,""),phase:u||void 0,category:f||yc(a),visibility:y(n.visibility,y(r.visibility,"public")),event_id:y(n.event_id,""),content:bc(a,s,o,r),dice_roll:$c(a,r),timestamp:l}}function xc(t,e,n){var it,ot;const a=y(t.room_id,"")||n||"default",s=O(t.state)?t.state:{},o=O(s.party)?s.party:{},r=O(s.actor_control)?s.actor_control:{},l=O(s.join_gate)?s.join_gate:{},u=O(s.contribution_ledger)?s.contribution_ledger:{},f=Object.entries(o).map(([B,V])=>{const k=O(V)?V:{},Et=At(k,"max_hp",void 0,10),Zt=At(k,"hp",void 0,Et),pe=At(k,"max_mp",void 0,0),me=At(k,"mp",void 0,0),I=At(k,"level",void 0,1),It=At(k,"xp",void 0,0),ve=Qs(k.alive,Zt>0),en=r[B],nn=typeof en=="string"?en:void 0,Xn=fc(k.role,B,nn),g=mc(k.generation),E=ut(k.joined_at,k.joinedAt,k.started_at,k.startedAt),F=ut(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),rt=ut(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),q=ut(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),_t=ut(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:B,name:y(k.name,B),role:Xn,keeper:nn,archetype:y(k.archetype,""),persona:y(k.persona,""),portrait:y(k.portrait,"")||void 0,background:y(k.background,"")||void 0,traits:an(k.traits),skills:an(k.skills),stats_raw:gc(k),status:ve?"active":"dead",generation:g,joined_at:E||void 0,claimed_at:F||void 0,last_seen:rt||void 0,scene:q||void 0,location:_t||void 0,inventory:an(k.inventory),notes:an(k.notes),relationships:vc(k.relationships),stats:{hp:Zt,max_hp:Et,mp:me,max_mp:pe,level:I,xp:It,strength:At(k,"strength","str",10),dexterity:At(k,"dexterity","dex",10),constitution:At(k,"constitution","con",10),intelligence:At(k,"intelligence","int",10),wisdom:At(k,"wisdom","wis",10),charisma:At(k,"charisma","cha",10)}}}),m=f.filter(B=>B.status!=="dead"),c=pc(t,e),v={phase_open:Qs(l.phase_open,!0),min_points:j(l.min_points,3),window:y(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},h=Object.entries(u).map(([B,V])=>{const k=O(V)?V:{};return{actor_id:B,score:j(k.score,0),last_reason:y(k.last_reason,"")||null,reasons:an(k.reasons)}}),b=f.reduce((B,V)=>(B[V.id]=V.name,B),{}),w=e.map(B=>kc(B,b)),N=j(s.turn,1),P=y(s.phase,"round"),M=y(s.map,""),D=O(s.world)?s.world:{},L=M||y(D.ascii_map,y(D.map,"")),p=w.filter((B,V)=>{const k=e[V];if(!O(k))return!1;const Et=O(k.payload)?k.payload:{};return j(Et.turn,-1)===N}),H=(p.length>0?p:w).slice(-12),U=y(s.status,"active");return{session:{id:a,room:a,status:U==="ended"?"ended":U==="paused"?"paused":"active",round:N,actors:m,created_at:((it=w[0])==null?void 0:it.timestamp)??new Date().toISOString()},current_round:{round_number:N,phase:P,events:H,timestamp:((ot=w[w.length-1])==null?void 0:ot.timestamp)??new Date().toISOString()},map:L||void 0,join_gate:v,contribution_ledger:h,outcome:c,party:m,story_log:w,history:[]}}async function Sc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await tt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ac(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([tt(`/api/v1/trpg/state${e}`),Sc(t)]);return xc(n,a,t)}function wc(t){return Ut("/api/v1/trpg/rounds/run",{room_id:t})}function Cc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Tc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ut("/api/v1/trpg/dice/roll",e)}function Nc(t,e){const n=Cc();return Ut("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Rc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ut("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Lc(t,e,n){return Ut("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Pc(t,e,n){const a=await kt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Dc(t){const e=await kt("trpg.mid_join.request",t);return JSON.parse(e)}async function nr(t,e){await kt("masc_broadcast",{agent_name:t,message:e})}async function Ec(t,e,n=1){await kt("masc_add_task",{title:t,description:e,priority:n})}async function Ic(t){return kt("masc_join",{agent_name:t})}async function ar(t){await kt("masc_leave",{agent_name:t})}async function Mc(t){await kt("masc_heartbeat",{agent_name:t})}async function Oc(t=40){return(await kt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function zc(t,e=20){return kt("masc_task_history",{task_id:t,limit:e})}async function qc(){return Ye("fetchDebates",async()=>{const t=await tt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=y(e.id,"").trim(),a=y(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:y(e.status,"open"),argument_count:j(e.argument_count,0),created_at:Be(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function jc(){return Ye("fetchCouncilSessions",async()=>{const t=await tt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=y(e.id,"").trim(),a=y(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:y(e.initiator,"system"),votes:j(e.votes,0),quorum:j(e.quorum,0),state:y(e.state,"open"),created_at:Be(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Fc(t){const e=await kt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Kc(t){return Ye("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await tt(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=y(n.id,"").trim();return a?{id:a,topic:y(n.topic,""),status:y(n.status,"open"),support_count:j(n.support_count,0),oppose_count:j(n.oppose_count,0),neutral_count:j(n.neutral_count,0),total_arguments:j(n.total_arguments,0),created_at:Be(n.created_at_iso??n.created_at),summary_text:y(n.summary_text,"")}:null})}function Hc(t,e,n){return kt("masc_keeper_msg",{name:t,message:e})}async function Uc(){try{const t=await kt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const mn=_(""),Jt=_({}),mt=_({}),Ys=_({}),Xs=_({}),Zs=_({}),ti=_({}),Vt=_({});function dt(t,e,n){t.value={...t.value,[e]:n}}function Yt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function G(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Pt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Me(t){return typeof t=="boolean"?t:void 0}function ei(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function ni(t){return Array.isArray(t)?t.map(e=>G(e)).filter(e=>!!e):[]}function Bc(t){var n;const e=(n=G(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Wc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function fs(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Yt(a))continue;const s=G(a.name);if(!s)continue;const o=G(a[e]);e==="summary"?n.push({name:s,summary:o}):n.push({name:s,reason:o})}return n}function Gc(t){if(!Yt(t))return null;const e=G(t.name);return e?{name:e,trigger:G(t.trigger),outcome:G(t.outcome),summary:G(t.summary),reason:G(t.reason)}:null}function Jc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Vc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function sr(t,e,n){return G(t)??Vc(e,n)}function ir(t,e){return typeof t=="boolean"?t:e==="recover"}function wa(t){if(!Yt(t))return null;const e=G(t.health_state),n=G(t.next_action_path),a=G(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:G(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:ei(t.last_reply_at),last_reply_preview:G(t.last_reply_preview)??null,last_error:G(t.last_error)??null,next_eligible_at_s:Pt(t.next_eligible_at_s)??null,recoverable:ir(t.recoverable,n),summary:sr(t.summary,e,G(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ii(t){return Yt(t)?{hour:Pt(t.hour),checked:Pt(t.checked)??0,acted:Pt(t.acted)??0,acted_names:ni(t.acted_names),activity_report:G(t.activity_report),quiet_hours_overridden:Me(t.quiet_hours_overridden),skipped_reason:G(t.skipped_reason),acted_rows:fs(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:fs(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:fs(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Gc).filter(e=>e!==null):[]}:null}function Qc(t){return Yt(t)?{enabled:Me(t.enabled)??!1,interval_s:Pt(t.interval_s)??0,quiet_start:Pt(t.quiet_start),quiet_end:Pt(t.quiet_end),quiet_active:Me(t.quiet_active),use_planner:Me(t.use_planner),delegate_llm:Me(t.delegate_llm),agent_count:Pt(t.agent_count),agents:ni(t.agents),last_tick_ago_s:Pt(t.last_tick_ago_s)??null,last_tick_ago:G(t.last_tick_ago),total_ticks:Pt(t.total_ticks),total_checkins:Pt(t.total_checkins),last_skip_reason:G(t.last_skip_reason)??null,last_tick_result:Ii(t.last_tick_result),active_self_heartbeats:ni(t.active_self_heartbeats)}:null}function Yc(t){return Yt(t)?{status:t.status,diagnostic:wa(t.diagnostic)}:null}function Xc(t){return Yt(t)?{recovered:Me(t.recovered)??!1,skipped_reason:G(t.skipped_reason)??null,before:wa(t.before),after:wa(t.after),down:t.down,up:t.up}:null}function Zc(t,e){var M,D;if(!(t!=null&&t.name))return null;const n=G((M=t.agent)==null?void 0:M.status)??G(t.status)??"unknown",a=G((D=t.agent)==null?void 0:D.error)??null,s=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,u=t.proactive_enabled??!1,f=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,c=u&&m!=null?Math.max(0,f-m):null,v=r<=0||l==null?"never":l>900?"stale":"fresh",h=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,b=a??(s&&!o?"keeper keepalive is not running":null),w=n==="offline"||n==="inactive"?"offline":b?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",N=b?Jc(b):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":s&&!o?"disabled":r<=0?"never_started":c!=null&&c>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",P=w==="offline"||w==="degraded"||w==="stale"?"recover":N==="quiet_hours"?"manual_lodge_poke":N==="unknown"?"probe":"direct_message";return{health_state:w,quiet_reason:N,next_action_path:P,last_reply_status:v,last_reply_at:h,last_reply_preview:null,last_error:b,next_eligible_at_s:c!=null&&c>0?c:null,recoverable:ir(void 0,P),summary:sr(void 0,w,N),keepalive_running:o}}function td(t,e){if(!Yt(t))return null;const n=Bc(t.role),a=G(t.content)??G(t.preview);if(!a)return null;const s=ei(t.ts_unix)??ei(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:Wc(n),text:a,timestamp:s,delivery:"history"}}function ed(t,e,n){const a=Yt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>td(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:wa(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function ao(t,e){const n=mt.value[t]??[];mt.value={...mt.value,[t]:[...n,e].slice(-50)}}function nd(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function ad(t,e){const a=(mt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(o=>nd(s,o)));mt.value={...mt.value,[t]:[...e,...a].slice(-50)}}function os(t,e){Jt.value={...Jt.value,[t]:e},ad(t,e.history)}function so(t,e){const n=Jt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};os(t,{...n,diagnostic:{...a,...e}})}async function Mi(){We();try{await re()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function pa(t){mn.value=t.trim()}async function or(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Jt.value[n])return Jt.value[n];dt(Ys,n,!0),dt(Vt,n,null);try{const a=await kt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const o=ed(n,a,s);return os(n,o),o}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return dt(Vt,n,s),null}finally{dt(Ys,n,!1)}}async function sd(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;ao(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),dt(Xs,n,!0),dt(Vt,n,null);try{const o=await Hc(n,a);mt.value={...mt.value,[n]:(mt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},ao(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),so(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Mi()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw mt.value={...mt.value,[n]:(mt.value[n]??[]).map(l=>l.id===s?{...l,delivery:"error",error:r}:l)},so(n,{last_reply_status:"error",last_error:r}),dt(Vt,n,r),o}finally{dt(Xs,n,!1)}}async function id(t,e){const n=t.trim();if(!n)return null;dt(Zs,n,!0),dt(Vt,n,null);try{const a=await Jn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Yc(a.result),o=(s==null?void 0:s.diagnostic)??null;if(o){const r=Jt.value[n];os(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??mt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Mi(),o}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw dt(Vt,n,s),a}finally{dt(Zs,n,!1)}}async function od(t,e){const n=t.trim();if(!n)return null;dt(ti,n,!0),dt(Vt,n,null);try{const a=await Jn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Xc(a.result),o=(s==null?void 0:s.after)??null;if(o){const r=Jt.value[n];os(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??mt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Mi(),o}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw dt(Vt,n,s),a}finally{dt(ti,n,!1)}}function fe(t){return(t??"").trim().toLowerCase()}function gt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ma(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Zn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function sn(t){return t.last_heartbeat??Zn(t.last_turn_ago_s)??Zn(t.last_proactive_ago_s)??Zn(t.last_handoff_ago_s)??Zn(t.last_compaction_ago_s)}function rd(t){const e=t.title.trim();return e||ma(t.content)}function ld(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function cd(t,e,n,a,s={}){var D;const o=fe(t),r=e.filter(L=>fe(L.assignee)===o&&(L.status==="claimed"||L.status==="in_progress")).length,l=n.filter(L=>fe(L.from)===o).sort((L,p)=>gt(p.timestamp)-gt(L.timestamp))[0],u=a.filter(L=>fe(L.agent)===o||fe(L.author)===o).sort((L,p)=>gt(p.timestamp)-gt(L.timestamp))[0],f=(s.boardPosts??[]).filter(L=>fe(L.author)===o).sort((L,p)=>gt(p.updated_at||p.created_at)-gt(L.updated_at||L.created_at))[0],m=(s.keepers??[]).filter(L=>fe(L.name)===o&&sn(L)!==null).sort((L,p)=>gt(sn(p)??0)-gt(sn(L)??0))[0],c=l?gt(l.timestamp):0,v=u?gt(u.timestamp):0,h=f?gt(f.updated_at||f.created_at):0,b=m?gt(sn(m)??0):0,w=s.lastSeen?gt(s.lastSeen):0,N=((D=s.currentTask)==null?void 0:D.trim())||(r>0?`${r} claimed tasks`:null);if(c===0&&v===0&&h===0&&b===0&&w===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:N};const M=[l?{timestamp:l.timestamp,ts:c,text:ma(l.content)}:null,f?{timestamp:f.updated_at||f.created_at,ts:h,text:`Post: ${ma(rd(f))}`}:null,m?{timestamp:sn(m),ts:b,text:ld(m)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:v,text:ma(u.text)}:null].filter(L=>L!==null).sort((L,p)=>p.ts-L.ts)[0];return M&&M.ts>=w?{activeAssignedCount:r,lastActivityAt:M.timestamp,lastActivityText:M.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:N??"Presence heartbeat"}}const Tt=_([]),bt=_([]),Rn=_([]),Xt=_([]),de=_(null),dn=_(null),ai=_(new Map),Xe=_([]),Ln=_("hot"),$e=_(!0),rr=_(null),Gt=_(""),Pn=_([]),Oe=_(!1),lr=_(new Map),si=_("unknown"),ii=_(null),oi=_(!1),Dn=_(!1),ri=_(!1),ze=_(!1),dd=_(null),li=_(null),cr=_(null),dr=_(null),ud=Nt(()=>Tt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),ur=Nt(()=>{const t=bt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),rs=Nt(()=>{const t=new Map,e=bt.value,n=Rn.value,a=Aa.value,s=Xe.value,o=Xt.value;for(const r of Tt.value)t.set(r.name.trim().toLowerCase(),cd(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:s,keepers:o}));return t});function pd(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const pr=Nt(()=>{const t=new Map;for(const e of Xt.value)t.set(e.name,pd(e));return t}),md=12e4;function vd(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof s=="number"?Date.now()-s*1e3:null}const mr=Nt(()=>{const t=Date.now(),e=new Set,n=ai.value;for(const a of Xt.value){const s=vd(a,n);s!=null&&t-s>md&&e.add(a.name)}return e}),Ca={},fd=5e3;let _s=null;function _d(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function We(){delete Ca.compact,delete Ca.full}function vt(t){return typeof t=="object"&&t!==null}function S(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function xe(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ci(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function vr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function gd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function fr(t){if(!vt(t))return null;const e=S(t.name);return e?{name:e,status:vr(t.status),current_task:S(t.current_task)??null,last_seen:S(t.last_seen),emoji:S(t.emoji),koreanName:S(t.koreanName)??S(t.korean_name),model:S(t.model),traits:xe(t.traits),interests:xe(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:S(t.primaryValue)??S(t.primary_value)}:null}function _r(t){if(!vt(t))return null;const e=S(t.id),n=S(t.title);return!e||!n?null:{id:e,title:n,status:gd(t.status),priority:C(t.priority),assignee:S(t.assignee),description:S(t.description),created_at:S(t.created_at),updated_at:S(t.updated_at)}}function gr(t){if(!vt(t))return null;const e=S(t.from)??S(t.from_agent)??"system",n=S(t.content)??"",a=S(t.timestamp)??new Date().toISOString();return{id:S(t.id),seq:C(t.seq),from:e,content:n,timestamp:a,type:S(t.type)}}function $d(t){return Array.isArray(t)?t.map(e=>{if(!vt(e))return null;const n=C(e.ts_unix);if(n==null)return null;const a=vt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?C(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function io(t){if(!vt(t))return null;const e=S(t.health_state),n=S(t.next_action_path),a=S(t.last_reply_status);if(!e||!n||!a)return null;const s=S(t.quiet_reason)??null,o=S(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:ci(t.last_reply_at)??S(t.last_reply_at)??null,last_reply_preview:S(t.last_reply_preview)??null,last_error:S(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function hd(t,e){return(Array.isArray(t)?t:vt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!vt(a))return null;const s=vt(a.agent)?a.agent:null,o=vt(a.context)?a.context:null,r=vt(a.metrics_window)?a.metrics_window:void 0,l=S(a.name);if(!l)return null;const u=C(a.context_ratio)??C(o==null?void 0:o.context_ratio),f=S(a.status)??S(s==null?void 0:s.status)??"offline",m=vr(f),c=S(a.model)??S(a.active_model)??S(a.primary_model),v=xe(a.skill_secondary),h=o?{source:S(o.source),context_ratio:C(o.context_ratio),context_tokens:C(o.context_tokens),context_max:C(o.context_max),message_count:C(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,b=s?{name:S(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:S(s.error),status:S(s.status),current_task:S(s.current_task)??null,last_seen:S(s.last_seen),last_seen_ago_s:C(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,w=$d(a.metrics_series),N={name:l,emoji:S(a.emoji),koreanName:S(a.koreanName)??S(a.korean_name),agent_name:S(a.agent_name),trace_id:S(a.trace_id),model:c,primary_model:S(a.primary_model),active_model:S(a.active_model),next_model_hint:S(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:C(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:C(a.proactive_idle_sec),proactive_cooldown_sec:C(a.proactive_cooldown_sec),last_heartbeat:S(a.last_heartbeat)??S(s==null?void 0:s.last_seen),generation:C(a.generation),turn_count:C(a.turn_count)??C(a.total_turns),keeper_age_s:C(a.keeper_age_s),last_turn_ago_s:C(a.last_turn_ago_s),last_handoff_ago_s:C(a.last_handoff_ago_s),last_compaction_ago_s:C(a.last_compaction_ago_s),last_proactive_ago_s:C(a.last_proactive_ago_s),context_ratio:u,context_tokens:C(a.context_tokens)??C(o==null?void 0:o.context_tokens),context_max:C(a.context_max)??C(o==null?void 0:o.context_max),context_source:S(a.context_source)??S(o==null?void 0:o.source),context:h,traits:xe(a.traits),interests:xe(a.interests),primaryValue:S(a.primaryValue)??S(a.primary_value),activityLevel:C(a.activityLevel)??C(a.activity_level),memory_recent_note:S(a.memory_recent_note)??null,conversation_tail_count:C(a.conversation_tail_count),k2k_count:C(a.k2k_count),handoff_count_total:C(a.handoff_count_total)??C(a.trace_history_count),compaction_count:C(a.compaction_count),last_compaction_saved_tokens:C(a.last_compaction_saved_tokens),diagnostic:io(a.diagnostic),skill_primary:S(a.skill_primary)??null,skill_secondary:v,skill_reason:S(a.skill_reason)??null,metrics_series:w.length>0?w:void 0,metrics_window:r,agent:b};return N.diagnostic=io(a.diagnostic)??Zc(N,(e==null?void 0:e.lodge)??null),N}).filter(a=>a!==null)}function yd(t){return vt(t)?{...t,lodge:Qc(t.lodge)??void 0}:null}function bd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function kd(t){if(!vt(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,a=C(t.metric_after)??n,s=vt(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:C(t.delta)??a-n,changes:S(t.changes)??"",failed_attempts:S(t.failed_attempts)??"",next_suggestion:S(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:S(s.worker_model)??"",tool_call_count:C(s.tool_call_count)??0,tool_names:xe(s.tool_names)??[],session_id:S(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function xd(t){var o,r;if(!vt(t))return null;const e=S(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(kd).filter(l=>l!==null):[],s=C(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:S(t.profile)??"unknown",status:bd(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:S(t.error_message)??S(t.error_reason)??null,stop_reason:S(t.stop_reason)??S(t.reason)??null,current_iteration:C(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:S(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:ci(t.updated_at)??null,stopped_at:ci(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:S(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:xe(t.latest_tool_names)??[],session_id:S(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function re(t="full"){var a,s,o;const e=Date.now(),n=Ca[t];if(!(n&&e-n.time<fd)){oi.value=!0;try{const r=await Kl(t);Ca[t]={data:r,time:e},Tt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(fr).filter(u=>u!==null),bt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(_r).filter(u=>u!==null),Rn.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(gr).filter(u=>u!==null);const l=yd(r.status);de.value=l,Xt.value=hd(r.keepers,l),dn.value=r.perpetual??null,dd.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{oi.value=!1}}}async function Sd(){try{const t=await Hl(),e=(Array.isArray(t.agents)?t.agents:[]).map(fr).filter(s=>s!==null),n=Tt.value,a=new Map(n.map(s=>[s.name,s]));Tt.value=e.map(s=>{const o=a.get(s.name);return o?{...o,status:s.status,current_task:s.current_task}:s})}catch(t){console.error("Agents selective fetch error:",t)}}async function Ad(){try{const t=await Ul({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(_r).filter(s=>s!==null),n=bt.value,a=new Map(n.map(s=>[s.id,s]));bt.value=e.map(s=>{const o=a.get(s.id);return o?{...o,status:s.status,priority:s.priority??o.priority,assignee:s.assignee??o.assignee}:s})}catch(t){console.error("Tasks selective fetch error:",t)}}async function wd(){try{const t=Rn.value,e=t.reduce((l,u)=>Math.max(l,u.seq??0),0),n=await Bl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(gr).filter(l=>l!==null);if(a.length===0)return;const s=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!s.has(l.seq);const u=`${l.timestamp}|${l.from}`;return o.has(u)?!1:(o.add(u),!0)});if(r.length>0){const l=[...t,...r];Rn.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function Ft(){Dn.value=!0;try{const t=await lc(Ln.value,{excludeSystem:$e.value});Xe.value=t.posts??[],li.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Dn.value=!1}}async function Kt(){var t;ri.value=!0;try{const e=Gt.value||((t=de.value)==null?void 0:t.room)||"default";Gt.value||(Gt.value=e);const n=await Ac(e);rr.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ri.value=!1}}async function En(){Oe.value=!0;try{const t=await Uc();Pn.value=Array.isArray(t)?t:[],cr.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Oe.value=!1}}async function Ge(){ze.value=!0;try{const t=await Wl(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=xd(a);s&&n.set(s.loop_id,s)}lr.value=n,dr.value=new Date().toISOString(),ii.value=null,si.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),si.value="error",ii.value=t instanceof Error?t.message:String(t)}finally{ze.value=!1}}let va=null;function Cd(t){va=t}let fa=null;function Td(t){fa=t}let _a=null;function Nd(t){_a=t}const he={};function _e(t,e,n=500){he[t]&&clearTimeout(he[t]),he[t]=setTimeout(()=>{e(),delete he[t]},n)}function Rd(){const t=Go.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(ai.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),ai.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&_e("agents",Sd),_d(e.type)&&(We(),_s||(_s=setTimeout(()=>{re(),fa==null||fa(),_a==null||_a(),_s=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&_e("tasks",Ad),e.type==="broadcast"&&_e("messages",wd),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&_e("dashboard",()=>{We(),re()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&_e("board",Ft),e.type.startsWith("decision_")&&_e("council",()=>va==null?void 0:va()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&_e("mdal",Ge,350)}});return()=>{t();for(const e of Object.keys(he))clearTimeout(he[e]),delete he[e]}}let vn=null;function Ld(){vn||(vn=setInterval(()=>{Ht.value||We(),re()},1e4))}function Pd(){vn&&(clearInterval(vn),vn=null)}function R({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Dt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Dd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const o=Math.floor(s/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function W({timestamp:t}){const e=Dd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}function X(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function lt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function ye(t){return(t??"").trim().toLowerCase()}function pt(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function qt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function Oi(t){const e=qt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let Ed=0;const be=_([]);function T(t,e="success",n=4e3){const a=++Ed;be.value=[...be.value,{id:a,message:t,type:e}],setTimeout(()=>{be.value=be.value.filter(s=>s.id!==a)},n)}function Id(t){be.value=be.value.filter(e=>e.id!==t)}function Md(){const t=be.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Id(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Od="masc_dashboard_agent_name",Ze=_(null),Ta=_(!1),In=_(""),Na=_([]),Mn=_([]),Fe=_(""),fn=_(!1);function Ke(t){Ze.value=t,zi()}function oo(){Ze.value=null,In.value="",Na.value=[],Mn.value=[],Fe.value=""}function zd(){const t=Ze.value;return t?Tt.value.find(e=>e.name===t)??null:null}function $r(t){return t?bt.value.filter(e=>e.assignee===t):[]}async function zi(){const t=Ze.value;if(t){Ta.value=!0,In.value="",Na.value=[],Mn.value=[];try{const e=await Oc(80);Na.value=e.filter(s=>s.includes(t)).slice(0,20);const n=$r(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const o=await zc(s.id,25);return{taskId:s.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Mn.value=a}catch(e){In.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ta.value=!1}}}async function ro(){var a;const t=Ze.value,e=Fe.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(Od))==null?void 0:a.trim())||"dashboard";fn.value=!0;try{await nr(n,`@${t} ${e}`),Fe.value="",T(`Mention sent to ${t}`,"success"),zi()}catch(s){const o=s instanceof Error?s.message:"Failed to send mention";T(o,"error")}finally{fn.value=!1}}function qd({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Dt} status=${t.status} />
    </div>
  `}function jd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Fd(){var s,o,r,l;const t=Ze.value;if(!t)return null;const e=zd(),n=$r(t),a=Na.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&oo()}}
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
                        <${Dt} status=${e.status} />
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
                ${(o=e==null?void 0:e.traits)==null?void 0:o.map(u=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(l=e==null?void 0:e.interests)==null?void 0:l.map(u=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?i`
                    ${e.current_task?i`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?i`<span>Last seen: <${W} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{zi()}} disabled=${Ta.value}>
              ${Ta.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${oo}>Close</button>
          </div>
        </div>

        ${In.value?i`<div class="council-error">${In.value}</div>`:null}

        <div class="agent-detail-grid">
          <${R} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(u=>i`<${qd} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${R} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((u,f)=>i`<div key=${f} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${R} title="Task History">
          ${Mn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Mn.value.map(u=>i`<${jd} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${R} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Fe.value}
              onInput=${u=>{Fe.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&ro()}}
              disabled=${fn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{ro()}}
              disabled=${fn.value||Fe.value.trim()===""}
            >
              ${fn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Ra=600*1e3,ga=1200*1e3;function hr(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function yr(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function Kd(t){return t.updated_at??t.created_at??null}function lo(t,e,n){var N,P;const a=ye(t.assignee),s=a?e.get(a)??null:null,o=s?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(s==null?void 0:s.last_seen)??null,l=r?Math.max(0,Date.now()-X(r)):Number.POSITIVE_INFINITY,u=pt(t.description),f=pt(s==null?void 0:s.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let c="ok",v="Fresh owner coverage",h=f??u??t.id,b=!1,w=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?(b=!0,c="bad",v="Assigned owner is offline",h="Queue item is blocked until ownership changes."):l>Ra?(c="warn",v="Owner exists but live signal is quiet",h=f??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(N=s.current_task)!=null&&N.trim()?(c="warn",v="Owner is already carrying active work",h=f??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(v="Ready and covered by a fresh operator",h=f??u??"This can be picked up immediately."):(b=!0,c="bad",v="Assigned owner is not present in the room",h="Reassign or bring the owner back online."):(b=!0,c=qt(t.priority)<=2?"bad":"warn",v=qt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",h="Assign an agent before this queue item slips."):m&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?(b=!0,c="bad",v="Assigned owner is offline",h=f??"Execution has no live operator right now."):l>ga?(w=!0,c="bad",v="Assigned owner has gone quiet",h=f??"Fresh operator signal is missing."):l>Ra?(w=!0,c="warn",v="Execution has been quiet for too long",h=f??"Check whether this work is blocked."):(P=s.current_task)!=null&&P.trim()?(v="Execution has fresh owner coverage",h=f??u??t.id):(c="warn",v=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",h=f??"Task state and agent focus are drifting apart."):(b=!0,c="bad",v="Assigned owner is not active in the room",h="Execution is orphaned until ownership is restored."):(b=!0,c="bad",v="Active work has no assignee",h="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:o,tone:c,note:v,focus:h,lastSignalAt:r,lastTouchedAt:Kd(t),ownerGap:b,quiet:w}}function Hd(t,e){var v;const n=e.get(ye(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-X(a)):Number.POSITIVE_INFINITY,o=!!((v=t.current_task)!=null&&v.trim()),r=n.activeAssignedCount,l=o||r>0;let u="loaded",f="ok",m="Healthy active load",c=pt(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(u="offline",f="bad",m="Agent is unavailable"):l&&s>ga?(u="quiet",f="bad",m="Working without a fresh signal"):r>0&&!o?(u="drift",f="warn",m="Claimed work exists but current_task is empty",c=`${r} active tasks need explicit focus.`):o&&r===0?(u="drift",f="warn",m="current_task has no matching claimed work",c=pt(t.current_task)??"Task metadata and operator state drifted."):!l&&s<=Ra?(u="dispatchable",f="ok",m="Fresh signal and no active load",c=n.lastActivityText??"Ready for assignment."):l?s>Ra&&(u="loaded",f="warn",m="Execution load is healthy but slightly quiet",c=pt(t.current_task)??`${r} active tasks in flight.`):(u="quiet",f=s>ga?"bad":"warn",m=s>ga?"No fresh signal while idle":"Reachable, but not freshly active",c=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:f,state:u,note:m,focus:c,lastSignalAt:a,activeTaskCount:r}}function on({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Ud({item:t}){return i`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?Oi(t.taskRow.task.priority):yr(t.agentRow.state)}
        </span>
        ${t.kind==="task"?i`<span>${hr(t.taskRow.task.status)}</span>`:i`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?i`<span><${W} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </div>
  `}function co({row:t}){var e;return i`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${Oi(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?i`<${Dt} status=${t.assigneeAgent.status} />`:i`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${hr(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?i`<span>Owner ${t.task.assignee}</span>`:i`<span>Unassigned</span>`}
        ${t.lastTouchedAt?i`<span>Touched <${W} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?i`<span>Signal <${W} timestamp=${t.lastSignalAt} /></span>`:i`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&pt(t.assigneeAgent.current_task)!==t.focus?i`<div class="monitor-footnote">Owner focus: ${pt(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function Bd({row:t}){const{agent:e}=t;return i`
    <button class="monitor-row ${t.tone}" onClick=${()=>Ke(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Dt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${yr(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${W} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function Wd(){const t=Tt.value,e=bt.value,n=new Map(t.map(c=>[ye(c.name),c])),a=rs.value,s=e.filter(c=>c.status==="claimed"||c.status==="in_progress").map(c=>lo(c,n,a)).sort((c,v)=>{const h=lt(v.tone)-lt(c.tone);return h!==0?h:X(v.lastSignalAt??v.lastTouchedAt)-X(c.lastSignalAt??c.lastTouchedAt)}),o=e.filter(c=>c.status==="todo").map(c=>lo(c,n,a)).sort((c,v)=>{const h=lt(v.tone)-lt(c.tone);if(h!==0)return h;const b=qt(c.task.priority)-qt(v.task.priority);return b!==0?b:X(c.lastTouchedAt)-X(v.lastTouchedAt)}),r=t.map(c=>Hd(c,a)).filter(c=>c.state==="dispatchable"||c.state==="drift"||c.state==="quiet").sort((c,v)=>{if(c.state==="dispatchable"&&v.state!=="dispatchable")return-1;if(v.state==="dispatchable"&&c.state!=="dispatchable")return 1;const h=lt(v.tone)-lt(c.tone);return h!==0?h:X(v.lastSignalAt)-X(c.lastSignalAt)}),l=[...s.filter(c=>c.tone!=="ok").map(c=>({kind:"task",key:`active-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt??c.lastTouchedAt,taskRow:c})),...o.filter(c=>c.tone==="bad").map(c=>({kind:"task",key:`ready-${c.task.id}`,tone:c.tone,title:c.task.title,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastTouchedAt,taskRow:c})),...r.filter(c=>c.state==="drift"||c.tone==="bad").map(c=>({kind:"agent",key:`agent-${c.agent.name}`,tone:c.tone,title:c.agent.name,subtitle:`${c.note} · ${c.focus}`,timestamp:c.lastSignalAt,agentRow:c}))].sort((c,v)=>{const h=lt(v.tone)-lt(c.tone);return h!==0?h:X(v.timestamp)-X(c.timestamp)}).slice(0,8),u=r.filter(c=>c.state==="dispatchable"),f=[...s,...o].filter(c=>c.ownerGap),m=s.filter(c=>c.quiet);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${on} label="Active work 진행중" value=${s.length} color="#fbbf24" caption="할당됨 + 진행중" />
        <${on} label="Needs intervention 개입 필요" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="정체 또는 드리프트 감지" />
        <${on} label="Ownership gaps 담당자 공백" value=${f.length} color=${f.length>0?"#fb7185":"#4ade80"} caption="활성 담당자 없는 작업" />
        <${on} label="Dispatchable agents 배치 가능" value=${u.length} color="#22d3ee" caption="부하 없는 대기 에이전트" />
        <${on} label="Quiet execution 조용한 실행" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="오래된 신호의 활성 작업" />
      </div>

      <${R} title="Intervention Queue 개입 필요" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?i`<div class="empty-state">No active execution risks right now</div>`:l.map(c=>i`<${Ud} key=${c.key} item=${c} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${R} title="Ready Queue 대기열" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?i`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(c=>i`<${co} key=${c.task.id} row=${c} />`)}
          </div>
        <//>

        <${R} title="Dispatch Window 배치 현황" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?i`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(c=>i`<${Bd} key=${c.agent.name} row=${c} />`)}
          </div>
        <//>
      </div>

      <${R} title="Active Execution Watch 실행 감시" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?i`<div class="empty-state">No active execution tasks</div>`:s.map(c=>i`<${co} key=${c.task.id} row=${c} />`)}
        </div>
      <//>
    </div>
  `}function Gd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Jd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Vd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function uo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function br(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Qd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function kr(t){if(!t)return null;const e=Jt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function xr({keeper:t,showRawStatus:e=!1}){if(st(()=>{t!=null&&t.name&&or(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Jt.value[t.name],a=kr(t),s=Ys.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Gd(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Jd((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?i` · ${br(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?i` · next eligible ${Qd(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?i`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Sr({keeperName:t,placeholder:e}){const[n,a]=is("");st(()=>{t&&or(t)},[t]);const s=mt.value[t]??[],o=Xs.value[t]??!1,r=Vt.value[t],l=async()=>{const u=n.trim();if(!(!t||!u)){a("");try{await sd(t,u)}catch(f){const m=f instanceof Error?f.message:`Failed to message ${t}`;T(m,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(u=>i`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${uo(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${uo(u)}`}>${Vd(u)}</span>
                  ${u.timestamp?i`<span class="keeper-conversation-time">${br(u.timestamp)}</span>`:null}
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
          onInput=${u=>{a(u.target.value)}}
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
  `}function Ar({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=kr(e),s=Zs.value[e.name]??!1,o=ti.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",l=(a==null?void 0:a.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{id(e.name,t).catch(u=>{const f=u instanceof Error?u.message:`Failed to probe ${e.name}`;T(f,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{od(e.name,t).catch(u=>{const f=u instanceof Error?u.message:`Failed to recover ${e.name}`;T(f,"error")})}}
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
  `}const qi=_(null);function La(t){qi.value=t,pa(t.name)}function po(){qi.value=null}const Ee=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Yd(t){if(!t)return 0;const e=Ee.findIndex(n=>n.level===t);return e>=0?e:0}function Xd({keeper:t}){const e=Yd(t.autonomy_level),n=Ee[e]??Ee[0];if(!n)return null;const a=(e+1)/Ee.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Ee.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Ee.map((s,o)=>i`
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
            <strong><${W} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function $a(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Zd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${s.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${$a(t.context_tokens)}</div>
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
  `}function tu({keeper:t}){var m,c;const e=t.metrics_series??[];if(e.length<2){const v=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,h=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,o=e.length,r=e.map((v,h)=>{const b=s+h/(o-1)*(n-2*s),w=a-s-(v.context_ratio??0)*(a-2*s);return{x:b,y:w,p:v}}),l=r.map(({x:v,y:h})=>`${v.toFixed(1)},${h.toFixed(1)}`).join(" "),u=(((c=e[e.length-1])==null?void 0:c.context_ratio)??0)*100,f=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${s}" x2="${v.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${f}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:h})=>i`
          <circle cx="${v.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const gs=_("");function eu({keeper:t}){var s,o,r,l;const e=gs.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${gs.value}
        onInput=${u=>{gs.value=u.target.value}}
      />
      ${a.map(u=>i`
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${$a(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${$a(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${$a(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function nu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function au({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function su({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function mo({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function $s(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function iu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:$s(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:$s(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:$s(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(a=>i`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function wr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function ou(){try{const t=await Jn({actor:wr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ii(t.result);We(),await re(),e!=null&&e.skipped_reason?T(e.skipped_reason,"warning"):T(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";T(e,"error")}}function ru({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${xr} keeper=${t} />
          <${Ar}
            actor=${wr()}
            keeper=${t}
            onPokeLodge=${()=>{ou()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Sr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function lu(){var e,n,a;const t=qi.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&po()}}
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
            <${Dt} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>po()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Zd} keeper=${t} />

        ${""}
        <${tu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${R} title="Field Dictionary">
            <${eu} keeper=${t} />
          <//>

          ${""}
          <${R} title="Profile">
            <${mo} traits=${t.traits??[]} label="Traits" />
            <${mo} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${W} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${R} title="Autonomy">
                <${Xd} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${R} title="TRPG Stats">
                <${nu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${R} title="Equipment (${t.inventory.length})">
                <${au} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${R} title="Relationships (${Object.keys(t.relationships).length})">
                <${su} rels=${t.relationships} />
              <//>
            `:null}

          <${R} title="Runtime Signals">
            <${iu} keeper=${t} />
          <//>

          <${R} title="Memory & Context">
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
        <${ru} keeper=${t} />
      </div>
    </div>
  `:null}const Je=_(!1);function cu(){Je.value=!0}function vo(){Je.value=!1}function du(){Je.value=!Je.value}const hs=600*1e3,ys=1200*1e3,fo=.8,bs=_("triage");function Le(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function ta(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function _o(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function go(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function uu(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ks(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function pu(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function mu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function vu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function fu(t){return t?t.enabled?t.quiet_active?`Quiet hours ${_o(t.quiet_start)}-${_o(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${go(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${go(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function $o(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function _u(t){return t==null||t===0?"":t>0?` +${t} ↑`:` ${t} ↓`}function gu(t){return t==null||t===0?"stat-delta neutral":t>0?"stat-delta up":"stat-delta down"}function $u({data:t}){if(!t||t.length<2)return null;const e=Math.max(...t),n=Math.min(...t),a=e-n||1,s=60,o=20,r=t.map((l,u)=>`${u/(t.length-1)*s},${o-(l-n)/a*o}`).join(" ");return i`
    <svg class="stat-sparkline" viewBox="0 0 ${s} ${o}" preserveAspectRatio="none">
      <polyline points=${r} fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  `}function Pe({label:t,value:e,color:n,caption:a,delta:s,spark:o}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value-row">
        <span class="stat-value" style=${n?`color: ${n}`:""}>${e}</span>
        ${s!=null&&s!==0?i`<span class=${gu(s)}>${_u(s)}</span>`:null}
        ${o?i`<${$u} data=${o} />`:null}
      </div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function hu({item:t}){return i`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?i`<span><${W} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function xs({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:o}){return i`
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
  `}function ho(){var H,U,xt,it,ot,B,V,k,Et,Zt,pe,me,I,It,ve,en,nn,Xn;const t=de.value,e=Tt.value,n=bt.value,a=Xt.value,s=ur.value,o=(H=t==null?void 0:t.monitoring)==null?void 0:H.board,r=(U=t==null?void 0:t.monitoring)==null?void 0:U.council,l=Ht.value,u=new Map(e.map(g=>[ye(g.name),g])),f=rs.value,m=e.map(g=>{var Qi;const E=f.get(ye(g.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},F=E.lastActivityAt??g.last_seen??null,rt=F?Math.max(0,Date.now()-X(F)):Number.POSITIVE_INFINITY,q=E.activeAssignedCount,_t=!!((Qi=g.current_task)!=null&&Qi.trim()),at=_t||q>0;let et="ok",St="Fresh and ready",Te=!1,Ne=!1;return g.status==="offline"||g.status==="inactive"?(et=at?"bad":"warn",St=at?"Load without an available owner":"Offline"):at&&rt>ys?(et="bad",St="Execution is stale"):q>0&&!_t?(et="warn",St="Claimed work has no current_task",Ne=!0):_t&&q===0?(et="warn",St="current_task has no claimed work",Ne=!0):!at&&rt<=hs?(et="ok",St="Dispatchable now",Te=!0):!at&&rt>ys?(et="warn",St="Idle but not freshly active"):at&&rt>hs&&(et="warn",St="Execution is getting quiet"),{agent:g,lastSignalAt:F,activeTaskCount:q,tone:et,note:St,focus:pt(g.current_task)??E.lastActivityText??(Te?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:Te,drift:Ne}}).sort((g,E)=>{const F=lt(E.tone)-lt(g.tone);return F!==0?F:X(E.lastSignalAt)-X(g.lastSignalAt)}),c=a.map(g=>{var et;const E=pr.value.get(g.name)??"idle",F=mr.value.has(g.name),rt=g.context_ratio??0,q=g.diagnostic??null;let _t="ok",at="Healthy keeper";return F||g.status==="offline"||E==="handoff-imminent"||(q==null?void 0:q.health_state)==="offline"||(q==null?void 0:q.health_state)==="degraded"?(_t="bad",at=pt(q==null?void 0:q.summary,56)??(F?"Heartbeat stale":E==="handoff-imminent"?"Handoff imminent":(q==null?void 0:q.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((q==null?void 0:q.health_state)==="stale"||rt>=fo||E==="preparing"||E==="compacting")&&(_t="warn",at=pt(q==null?void 0:q.summary,56)??(rt>=fo?"High context pressure":`Lifecycle ${E}`)),{keeper:g,tone:_t,note:at,focus:pt(q==null?void 0:q.summary,120)??pt((et=g.agent)==null?void 0:et.current_task)??g.skill_primary??g.last_proactive_reason??g.memory_recent_note??"No active focus",timestamp:g.last_heartbeat??null}}).sort((g,E)=>{const F=lt(E.tone)-lt(g.tone);return F!==0?F:X(E.timestamp)-X(g.timestamp)}),v=n.filter(g=>g.status==="todo"||g.status==="claimed"||g.status==="in_progress").map(g=>{var Te,Ne;const E=g.assignee?u.get(ye(g.assignee))??null:null,F=E?f.get(ye(E.name))??null:null,rt=(F==null?void 0:F.lastActivityAt)??(E==null?void 0:E.last_seen)??null,q=rt?Math.max(0,Date.now()-X(rt)):Number.POSITIVE_INFINITY,_t=g.status==="claimed"||g.status==="in_progress";let at="ok",et="Covered",St=!1;return g.assignee?!E||E.status==="offline"||E.status==="inactive"?(at="bad",et="Assigned owner is unavailable",St=!0):_t&&q>ys?(at="bad",et="Execution has lost a fresh signal"):_t&&q>hs?(at="warn",et="Execution is drifting quiet"):g.status==="todo"&&qt(g.priority)<=2&&!((Te=E.current_task)!=null&&Te.trim())&&((F==null?void 0:F.activeAssignedCount)??0)===0?(at="ok",et="Ready for dispatch"):_t&&!((Ne=E.current_task)!=null&&Ne.trim())&&(at="warn",et="Owner focus is not explicit"):(at=qt(g.priority)<=2?"bad":"warn",et=_t?"Active work has no owner":"Ready work has no owner",St=!0),{task:g,owner:E,lastSignalAt:rt,tone:at,note:et,focus:pt(E==null?void 0:E.current_task)??(F==null?void 0:F.lastActivityText)??pt(g.description)??"Needs operator attention.",ownerGap:St}}).sort((g,E)=>{const F=lt(E.tone)-lt(g.tone);if(F!==0)return F;const rt=qt(g.task.priority)-qt(E.task.priority);return rt!==0?rt:X(E.lastSignalAt??E.task.updated_at??E.task.created_at)-X(g.lastSignalAt??g.task.updated_at??g.task.created_at)}),h=v.filter(g=>g.task.status==="todo"&&qt(g.task.priority)<=2),b=v.filter(g=>g.ownerGap).length,w=m.filter(g=>g.dispatchable),N=m.filter(g=>g.drift||g.tone!=="ok"),P=c.filter(g=>g.tone!=="ok"),M=t!=null&&t.paused?"bad":((xt=t==null?void 0:t.data_quality)==null?void 0:xt.board_contract_ok)===!1||((it=t==null?void 0:t.data_quality)==null?void 0:it.council_feed_ok)===!1?"warn":l?"ok":"warn",D=[];t!=null&&t.paused&&D.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((ot=t.data_quality)==null?void 0:ot.last_sync_at)??null,action:()=>ht("ops")}),l||D.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:cu}),Le(o==null?void 0:o.alert_level)!=="ok"&&D.push({key:"board-monitor",tone:Le(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${ks(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>ht("board")}),Le(r==null?void 0:r.alert_level)!=="ok"&&D.push({key:"council-monitor",tone:Le(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${ks(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>ht("board")}),(((B=t==null?void 0:t.data_quality)==null?void 0:B.board_contract_ok)===!1||((V=t==null?void 0:t.data_quality)==null?void 0:V.council_feed_ok)===!1)&&D.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((k=t.data_quality)==null?void 0:k.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Et=t.data_quality)==null?void 0:Et.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Zt=t.data_quality)==null?void 0:Zt.last_sync_at)??null,action:()=>ht("ops")});const L=[...D,...v.filter(g=>g.tone!=="ok").slice(0,3).map(g=>({key:`task-${g.task.id}`,tone:g.tone,title:g.task.title,detail:`${g.note} · ${g.focus}`,timestamp:g.lastSignalAt??g.task.updated_at??g.task.created_at??null,action:()=>ht("overview")})),...P.slice(0,2).map(g=>({key:`keeper-${g.keeper.name}`,tone:g.tone,title:g.keeper.name,detail:`${g.note} · ${g.focus}`,timestamp:g.timestamp,action:()=>La(g.keeper)})),...N.slice(0,2).map(g=>({key:`agent-${g.agent.name}`,tone:g.tone,title:g.agent.name,detail:`${g.note} · ${g.focus}`,timestamp:g.lastSignalAt,action:()=>Ke(g.agent.name)}))].sort((g,E)=>{const F=lt(E.tone)-lt(g.tone);return F!==0?F:X(E.timestamp)-X(g.timestamp)}).slice(0,8),p=bs.value;return i`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${p==="triage"?"active":""}"
        onClick=${()=>{bs.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${p==="dispatch"?"active":""}"
        onClick=${()=>{bs.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${p==="dispatch"?i`<${Wd} />`:i`<div class="stats-grid">
      <${Pe}
        label="Room State 방 상태"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${ta(M)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${Pe}
        label="Urgent Queue 긴급 대기"
        value=${h.length}
        color=${h.length>0?"#fb7185":"#4ade80"}
        caption="P1/P2 우선순위 대기 작업"
      />
      <${Pe}
        label="Active Work 진행중"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="할당됨 + 진행중인 작업"
      />
      <${Pe}
        label="Dispatchable 배치 가능"
        value=${w.length}
        color="#22d3ee"
        caption="부하 없는 대기 에이전트"
      />
      <${Pe}
        label="Keeper Pressure 키퍼 부하"
        value=${P.length}
        color=${P.length>0?"#fbbf24":"#4ade80"}
        caption="오래되거나 컨텍스트 과부하 키퍼"
      />
      <${Pe}
        label="Owner Gaps 담당자 공백"
        value=${b}
        color=${b>0?"#fb7185":"#4ade80"}
        caption="활성 담당자 없는 작업"
      />
    </div>

    <${R} title="Room Health" class="section">
      <div class="health-strip">
        <span class="health-dot" style=${`color:${l?"#4ade80":"#fbbf24"}`} title=${`Live Feed: ${l?"Online":"Retrying"} · ${Wn.value} events`}>● Live</span>
        <span class="health-dot" style=${`color:${ta(Le(o==null?void 0:o.alert_level))}`} title=${`Board: ${$o(o==null?void 0:o.alert_level)} · Freshness ${ks(o==null?void 0:o.last_activity_age_s)}`}>● Board</span>
        <span class="health-dot" style=${`color:${ta(Le(r==null?void 0:r.alert_level))}`} title=${`Council: ${$o(r==null?void 0:r.alert_level)} · ${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum`}>● Council</span>
        <span class="health-dot" style=${`color:${ta(M)}`} title=${`Runtime: ${t!=null&&t.paused?"Paused":"Stable"}`}>● Runtime</span>
        <span class="health-uptime">Uptime ${uu((t==null?void 0:t.uptime_seconds)??0)}</span>
      </div>
      <details class="runtime-collapsible">
        <summary class="runtime-summary">Sync and tempo details</summary>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            ${(pe=t==null?void 0:t.data_quality)!=null&&pe.last_sync_at?i`Last sync <${W} timestamp=${t.data_quality.last_sync_at} />`:i`No sync metadata yet`}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
          </div>
          <div class="overview-inline-note">${fu(t==null?void 0:t.lodge)}</div>
          ${(me=t==null?void 0:t.lodge)!=null&&me.last_skip_reason?i`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
        </div>
      </details>
    <//>

    <div class="overview-workbench">
      <div class="overview-column">
        <${R} title="Intervention Queue 개입 필요" class="section">
          <div class="monitor-alert-list">
            ${L.length===0?i`<div class="empty-state">No immediate intervention required</div>`:L.map(g=>i`<${hu} key=${g.key} item=${g} />`)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${R} title="Dispatch Window 배치 현황" class="section">
          <div class="monitor-list">
            ${w.length===0?i`<div class="empty-state">No fully dispatchable agents right now</div>`:w.slice(0,5).map(g=>i`
                  <${xs}
                    key=${g.agent.name}
                    tone=${g.tone}
                    title=${g.agent.name}
                    subtitle=${g.note}
                    meta=${[g.lastSignalAt?`Signal ${new Date(g.lastSignalAt).toLocaleTimeString()}`:"No recent signal",g.agent.model??"model n/a",g.agent.koreanName??"room agent"]}
                    focus=${g.focus}
                    onClick=${()=>Ke(g.agent.name)}
                  />
                `)}
          </div>
        <//>

        <${R} title="Agent Watch 에이전트 감시" class="section">
          <div class="monitor-list">
            ${N.length===0?i`<div class="empty-state">No agent drift or stale load right now</div>`:N.slice(0,4).map(g=>i`
                  <button class="monitor-row ${g.tone}" onClick=${()=>Ke(g.agent.name)}>
                    <div class="monitor-row-header">
                      <div class="monitor-row-title">
                        <div class="monitor-name-line">
                          <span class="monitor-title">${g.agent.name}</span>
                          ${g.agent.koreanName?i`<span class="monitor-sub">${g.agent.koreanName}</span>`:null}
                        </div>
                        <div class="monitor-note">${g.note}</div>
                      </div>
                      <${Dt} status=${g.agent.status} />
                      <span class="monitor-pill ${g.tone}">${g.dispatchable?"Ready":g.drift?"Drift":"Watch"}</span>
                    </div>
                    <div class="monitor-meta">
                      ${g.lastSignalAt?i`<span>Signal <${W} timestamp=${g.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
                      <span>${g.activeTaskCount>0?`${g.activeTaskCount} active tasks`:"No active tasks"}</span>
                      ${g.agent.model?i`<span>${g.agent.model}</span>`:null}
                    </div>
                    <div class="monitor-focus">${g.focus}</div>
                  </button>
                `)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${R} title="Keeper Pressure 키퍼 부하" class="section">
          <div class="monitor-list">
            ${P.length===0?i`<div class="empty-state">No keeper pressure signals right now</div>`:P.slice(0,4).map(g=>{var E;return i`
                  <${xs}
                    key=${g.keeper.name}
                    tone=${g.tone}
                    title=${g.keeper.name}
                    subtitle=${(E=g.keeper.diagnostic)!=null&&E.health_state?`${g.note} · ${g.keeper.diagnostic.health_state}`:g.note}
                    meta=${[g.timestamp?`Heartbeat ${new Date(g.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof g.keeper.context_ratio=="number"?Math.round(g.keeper.context_ratio*100):0}%`,g.keeper.model?`Model ${g.keeper.model}`:"model n/a",g.keeper.diagnostic?`${mu(g.keeper.diagnostic.quiet_reason)} · next ${vu(g.keeper.diagnostic.next_action_path)} · reply ${g.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                    focus=${g.focus}
                    onClick=${()=>La(g.keeper)}
                  />
                `})}
          </div>
        <//>

        <${R} title="Runtime Notes 런타임 메모" class="section">
          <details class="runtime-collapsible">
            <summary class="runtime-summary">Runtime context (${5+((I=t==null?void 0:t.lodge)!=null&&I.last_skip_reason?1:0)} items)</summary>
            <div class="overview-note-stack">
              <div class="overview-inline-note">
                Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
              </div>
              <div class="overview-inline-note">
                ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${ud.value.length} · Total tasks ${n.length}
              </div>
              <div class="overview-inline-note">
                ${dn.value?`Perpetual runtime ${dn.value.running?"running":"stopped"}${dn.value.goal?` · ${pt(dn.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
              </div>
              <div class="overview-inline-note">
                Lodge ${(It=t==null?void 0:t.lodge)!=null&&It.enabled?"enabled":"disabled"} · Last tick ${((ve=t==null?void 0:t.lodge)==null?void 0:ve.last_tick_ago)??"never"} · Self heartbeats ${((nn=(en=t==null?void 0:t.lodge)==null?void 0:en.active_self_heartbeats)==null?void 0:nn.length)??0}${(Xn=t==null?void 0:t.lodge)!=null&&Xn.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
              </div>
              <div class="overview-inline-note">
                ${a.length>0?`Hot keepers: ${P.length} · Highest context ${pu(Math.max(...a.map(g=>g.context_tokens??0)))}`:"No keepers registered"}
              </div>
            </div>
          </details>
        <//>
      </div>
    </div>

    <${R} title="Execution Pulse" class="section">
        <div class="monitor-list">
          ${v.length===0?i`<div class="empty-state">No active or ready tasks</div>`:v.slice(0,6).map(g=>i`
                <${xs}
                  key=${g.task.id}
                  tone=${g.tone}
                  title=${g.task.title}
                  subtitle=${`${Oi(g.task.priority)} · ${g.note}`}
                  meta=${[g.task.assignee?`Owner ${g.task.assignee}`:"Unassigned",g.lastSignalAt?`Signal ${new Date(g.lastSignalAt).toLocaleTimeString()}`:"No live signal",g.task.updated_at?`Touched ${new Date(g.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${g.focus}
                  onClick=${()=>ht("overview")}
                />
              `)}
        </div>
    <//>`}
  `}const yu="modulepreload",bu=function(t){return"/dashboard/"+t},yo={},ku=function(e,n,a){let s=Promise.resolve();if(n&&n.length>0){let r=function(f){return Promise.all(f.map(m=>Promise.resolve(m).then(c=>({status:"fulfilled",value:c}),c=>({status:"rejected",reason:c}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),u=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));s=r(n.map(f=>{if(f=bu(f),f in yo)return;yo[f]=!0;const m=f.endsWith(".css"),c=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${f}"]${c}`))return;const v=document.createElement("link");if(v.rel=m?"stylesheet":yu,m||(v.as="script"),v.crossOrigin="",v.href=f,u&&v.setAttribute("nonce",u),document.head.appendChild(v),m)return new Promise((h,b)=>{v.addEventListener("load",h),v.addEventListener("error",()=>b(new Error(`Unable to preload CSS for ${f}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return s.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})},Cr=_(null),Bt=_(null),Pa=_(!1),Da=_(!1),Ea=_(null),Ia=_(null),di=_(null),Ma=_(null),Ct=_("summary"),Vn=_(null),ui=_(!1),Oa=_(null),ji=_(null),pi=_(!1),za=_(null),Fi=_(null),mi=_(!1),qa=_(null),On=_(null),ja=_(!1),zn=_(null),He=_(null);let un=null;function Ki(t){return t!=="summary"&&t!=="swarm"}function A(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function d(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Q(t){return typeof t=="boolean"?t:void 0}function ft(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function xu(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Su(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Au(t){if(A(t))return{policy_class:d(t.policy_class),approval_class:d(t.approval_class),tool_allowlist:ft(t.tool_allowlist),model_allowlist:ft(t.model_allowlist),requires_human_for:ft(t.requires_human_for),autonomy_level:d(t.autonomy_level),escalation_timeout_sec:$(t.escalation_timeout_sec),kill_switch:Q(t.kill_switch),frozen:Q(t.frozen)}}function wu(t){if(A(t))return{headcount_cap:$(t.headcount_cap),active_operation_cap:$(t.active_operation_cap),max_cost_usd:$(t.max_cost_usd),max_tokens:$(t.max_tokens)}}function Hi(t){if(!A(t))return null;const e=d(t.unit_id),n=d(t.label),a=d(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:d(t.parent_unit_id)??null,leader_id:d(t.leader_id)??null,roster:ft(t.roster),capability_profile:ft(t.capability_profile),source:d(t.source),created_at:d(t.created_at),updated_at:d(t.updated_at),policy:Au(t.policy),budget:wu(t.budget)}}function Tr(t){if(!A(t))return null;const e=Hi(t.unit);return e?{unit:e,leader_status:d(t.leader_status),roster_total:$(t.roster_total),roster_live:$(t.roster_live),active_operation_count:$(t.active_operation_count),health:d(t.health),reasons:ft(t.reasons),children:Array.isArray(t.children)?t.children.map(Tr).filter(n=>n!==null):[]}:null}function Cu(t){if(A(t))return{total_units:$(t.total_units),company_count:$(t.company_count),platoon_count:$(t.platoon_count),squad_count:$(t.squad_count),leaf_agent_unit_count:$(t.leaf_agent_unit_count),live_agent_count:$(t.live_agent_count),managed_unit_count:$(t.managed_unit_count),active_operation_count:$(t.active_operation_count)}}function Nr(t){const e=A(t)?t:{};return{version:d(e.version),generated_at:d(e.generated_at),source:d(e.source),summary:Cu(e.summary),units:Array.isArray(e.units)?e.units.map(Tr).filter(n=>n!==null):[]}}function Tu(t){if(!A(t))return null;const e=d(t.kind),n=d(t.status);return!e||!n?null:{kind:e,chain_id:d(t.chain_id)??null,goal:d(t.goal)??null,run_id:d(t.run_id)??null,status:n,viewer_path:d(t.viewer_path)??null,last_sync_at:d(t.last_sync_at)??null}}function ls(t){if(!A(t))return null;const e=d(t.operation_id),n=d(t.objective),a=d(t.assigned_unit_id),s=d(t.trace_id),o=d(t.status);return!e||!n||!a||!s||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:d(t.autonomy_level),policy_class:d(t.policy_class),budget_class:d(t.budget_class),detachment_session_id:d(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:d(t.checkpoint_ref)??null,active_goal_ids:ft(t.active_goal_ids),note:d(t.note)??null,created_by:d(t.created_by),source:d(t.source),status:o,chain:Tu(t.chain),created_at:d(t.created_at),updated_at:d(t.updated_at)}}function Nu(t){if(!A(t))return null;const e=ls(t.operation);return e?{operation:e,assigned_unit_label:d(t.assigned_unit_label)}:null}function rn(t){if(A(t))return{tone:d(t.tone),pending_ops:$(t.pending_ops),blocked_ops:$(t.blocked_ops),in_flight_ops:$(t.in_flight_ops),pipeline_stalls:$(t.pipeline_stalls),bus_traffic:$(t.bus_traffic),l1_hit_rate:$(t.l1_hit_rate),invalidation_count:$(t.invalidation_count),current_pending:$(t.current_pending),current_in_flight:$(t.current_in_flight),cdb_wakeups:$(t.cdb_wakeups),total_stolen:$(t.total_stolen),avg_best_score:$(t.avg_best_score),avg_candidate_count:$(t.avg_candidate_count),best_first_operations:$(t.best_first_operations),active_sessions:$(t.active_sessions),commit_rate:$(t.commit_rate),total_speculations:$(t.total_speculations)}}function Ru(t){if(!A(t))return;const e=A(t.pipeline)?t.pipeline:void 0,n=A(t.cache)?t.cache:void 0,a=A(t.ooo)?t.ooo:void 0,s=A(t.speculative)?t.speculative:void 0,o=A(t.search_fabric)?t.search_fabric:void 0,r=A(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:$(e.total_ops),completed_ops:$(e.completed_ops),stalled_cycles:$(e.stalled_cycles),hazards_detected:$(e.hazards_detected),forwarding_used:$(e.forwarding_used),pipeline_flushes:$(e.pipeline_flushes),ipc:$(e.ipc)}:void 0,cache:n?{total_reads:$(n.total_reads),total_writes:$(n.total_writes),l1_hit_rate:$(n.l1_hit_rate),invalidation_count:$(n.invalidation_count),writeback_count:$(n.writeback_count),bus_traffic:$(n.bus_traffic)}:void 0,ooo:a?{agent_count:$(a.agent_count),total_added:$(a.total_added),total_issued:$(a.total_issued),total_completed:$(a.total_completed),total_stolen:$(a.total_stolen),cdb_wakeups:$(a.cdb_wakeups),stall_cycles:$(a.stall_cycles),global_cdb_events:$(a.global_cdb_events),current_pending:$(a.current_pending),current_in_flight:$(a.current_in_flight)}:void 0,speculative:s?{total_speculations:$(s.total_speculations),total_commits:$(s.total_commits),total_aborts:$(s.total_aborts),commit_rate:$(s.commit_rate),total_fast_calls:$(s.total_fast_calls),total_cost_usd:$(s.total_cost_usd),active_sessions:$(s.active_sessions)}:void 0,search_fabric:o?{total_operations:$(o.total_operations),best_first_operations:$(o.best_first_operations),legacy_operations:$(o.legacy_operations),blocked_operations:$(o.blocked_operations),ready_operations:$(o.ready_operations),research_pipeline_operations:$(o.research_pipeline_operations),avg_candidate_count:$(o.avg_candidate_count),avg_best_score:$(o.avg_best_score),top_stage:d(o.top_stage)??null}:void 0,signals:r?{issue_pressure:rn(r.issue_pressure),cache_contention:rn(r.cache_contention),scheduler_efficiency:rn(r.scheduler_efficiency),routing_confidence:rn(r.routing_confidence),speculative_posture:rn(r.speculative_posture)}:void 0}}function Rr(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:d(e.version),generated_at:d(e.generated_at),summary:n?{total:$(n.total),active:$(n.active),paused:$(n.paused),managed:$(n.managed),projected:$(n.projected)}:void 0,microarch:Ru(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Nu).filter(a=>a!==null):[]}}function Lr(t){if(!A(t))return null;const e=d(t.detachment_id),n=d(t.operation_id),a=d(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:d(t.leader_id)??null,roster:ft(t.roster),session_id:d(t.session_id)??null,checkpoint_ref:d(t.checkpoint_ref)??null,runtime_kind:d(t.runtime_kind)??null,runtime_ref:d(t.runtime_ref)??null,source:d(t.source),status:d(t.status),last_event_at:d(t.last_event_at)??null,last_progress_at:d(t.last_progress_at)??null,heartbeat_deadline:d(t.heartbeat_deadline)??null,created_at:d(t.created_at),updated_at:d(t.updated_at)}}function Lu(t){if(!A(t))return null;const e=Lr(t.detachment);return e?{detachment:e,assigned_unit_label:d(t.assigned_unit_label),operation:ls(t.operation)}:null}function Pr(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:d(e.version),generated_at:d(e.generated_at),summary:n?{total:$(n.total),active:$(n.active),projected:$(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Lu).filter(a=>a!==null):[]}}function Pu(t){if(!A(t))return null;const e=d(t.decision_id),n=d(t.trace_id),a=d(t.requested_action),s=d(t.scope_type),o=d(t.scope_id);return!e||!n||!a||!s||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:o,operation_id:d(t.operation_id)??null,target_unit_id:d(t.target_unit_id)??null,requested_by:d(t.requested_by),status:d(t.status),reason:d(t.reason)??null,source:d(t.source),detail:t.detail,created_at:d(t.created_at),decided_at:d(t.decided_at)??null,expires_at:d(t.expires_at)??null}}function Dr(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:d(e.version),generated_at:d(e.generated_at),summary:n?{total:$(n.total),pending:$(n.pending),approved:$(n.approved),denied:$(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Pu).filter(a=>a!==null):[]}}function Du(t){if(!A(t))return null;const e=Hi(t.unit);return e?{unit:e,roster_total:$(t.roster_total),roster_live:$(t.roster_live),headcount_cap:$(t.headcount_cap),active_operations:$(t.active_operations),active_operation_cap:$(t.active_operation_cap),utilization:$(t.utilization)}:null}function Eu(t){const e=A(t)?t:{};return{version:d(e.version),generated_at:d(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Du).filter(n=>n!==null):[]}}function Iu(t){if(!A(t))return null;const e=d(t.alert_id);return e?{alert_id:e,severity:d(t.severity),kind:d(t.kind),scope_type:d(t.scope_type),scope_id:d(t.scope_id),title:d(t.title),detail:d(t.detail),timestamp:d(t.timestamp)}:null}function Er(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:d(e.version),generated_at:d(e.generated_at),summary:n?{total:$(n.total),bad:$(n.bad),warn:$(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Iu).filter(a=>a!==null):[]}}function Ir(t){if(!A(t))return null;const e=d(t.event_id),n=d(t.trace_id),a=d(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:d(t.operation_id)??null,unit_id:d(t.unit_id)??null,actor:d(t.actor)??null,source:d(t.source),timestamp:d(t.timestamp),detail:t.detail}}function Mu(t){const e=A(t)?t:{};return{version:d(e.version),generated_at:d(e.generated_at),events:Array.isArray(e.events)?e.events.map(Ir).filter(n=>n!==null):[]}}function Ou(t){if(!A(t))return null;const e=d(t.code),n=d(t.severity),a=d(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function zu(t){if(!A(t))return null;const e=d(t.lane_id),n=d(t.label),a=d(t.kind),s=d(t.phase),o=d(t.motion_state),r=d(t.source_of_truth),l=d(t.movement_reason),u=d(t.current_step);if(!e||!n||!a||!s||!o||!r||!l||!u)return null;const f=A(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Q(t.present)??!1,phase:s,motion_state:o,source_of_truth:r,last_movement_at:d(t.last_movement_at)??null,movement_reason:l,current_step:u,blockers:ft(t.blockers),counts:{operations:$(f.operations),detachments:$(f.detachments),workers:$(f.workers),approvals:$(f.approvals),alerts:$(f.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Ou).filter(m=>m!==null):[]}}function qu(t){if(!A(t))return null;const e=d(t.event_id),n=d(t.lane_id),a=d(t.kind),s=d(t.timestamp),o=d(t.title),r=d(t.detail),l=d(t.tone),u=d(t.source);return!e||!n||!a||!s||!o||!r||!l||!u?null:{event_id:e,lane_id:n,kind:a,timestamp:s,title:o,detail:r,tone:l,source:u}}function ju(t){if(!A(t))return null;const e=d(t.code),n=d(t.severity),a=d(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:ft(t.lane_ids),count:$(t.count)??0}}function Mr(t){if(!A(t))return;const e=A(t.overview)?t.overview:{},n=A(t.gaps)?t.gaps:{},a=A(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:d(t.generated_at),overview:{active_lanes:$(e.active_lanes),moving_lanes:$(e.moving_lanes),stalled_lanes:$(e.stalled_lanes),projected_lanes:$(e.projected_lanes),last_movement_at:d(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(zu).filter(s=>s!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(qu).filter(s=>s!==null):[],gaps:{count:$(n.count),items:Array.isArray(n.items)?n.items.map(ju).filter(s=>s!==null):[]},recommended_next_action:a?{tool:d(a.tool)??"masc_operator_snapshot",label:d(a.label)??"Observe operator state",reason:d(a.reason)??"",lane_id:d(a.lane_id)??null}:void 0}}function Fu(t){if(!A(t))return;const e=A(t.workers)?t.workers:{},n=Q(t.pass);return{status:d(t.status)??"missing",source:d(t.source)??"none",run_id:d(t.run_id)??null,captured_at:d(t.captured_at)??null,...n!==void 0?{pass:n}:{},...$(t.peak_hot_slots)!=null?{peak_hot_slots:$(t.peak_hot_slots)}:{},...$(t.ctx_per_slot)!=null?{ctx_per_slot:$(t.ctx_per_slot)}:{},workers:{expected:$(e.expected),joined:$(e.joined),current_task_bound:$(e.current_task_bound),fresh_heartbeats:$(e.fresh_heartbeats),done:$(e.done),final:$(e.final)},artifact_ref:d(t.artifact_ref)??null,missing_reason:d(t.missing_reason)??null}}function Ku(t){const e=A(t)?t:{};return{version:d(e.version),generated_at:d(e.generated_at),topology:Nr(e.topology),operations:Rr(e.operations),detachments:Pr(e.detachments),alerts:Er(e.alerts),decisions:Dr(e.decisions),capacity:Eu(e.capacity),traces:Mu(e.traces),swarm_status:Mr(e.swarm_status)}}function Hu(t){const e=A(t)?t:{},n=Nr(e.topology),a=Rr(e.operations),s=Pr(e.detachments),o=Er(e.alerts),r=Dr(e.decisions);return{version:d(e.version),generated_at:d(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:s.version,generated_at:s.generated_at,summary:s.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Mr(e.swarm_status),swarm_proof:Fu(e.swarm_proof)}}function Uu(t){return A(t)?{chain_id:d(t.chain_id)??null,started_at:$(t.started_at)??null,progress:$(t.progress)??null,elapsed_sec:$(t.elapsed_sec)??null}:null}function Or(t){if(!A(t))return null;const e=d(t.event);return e?{event:e,chain_id:d(t.chain_id)??null,timestamp:d(t.timestamp)??null,duration_ms:$(t.duration_ms)??null,message:d(t.message)??null,tokens:$(t.tokens)??null}:null}function Bu(t){if(!A(t))return null;const e=ls(t.operation);return e?{operation:e,runtime:Uu(t.runtime),history:Or(t.history),mermaid:d(t.mermaid)??null,preview_run:zr(t.preview_run)}:null}function Wu(t){const e=A(t)?t:{};return{status:d(e.status)??"disconnected",base_url:d(e.base_url)??null,message:d(e.message)??null}}function Gu(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:d(e.version),generated_at:d(e.generated_at),connection:Wu(e.connection),summary:n?{linked_operations:$(n.linked_operations),active_chains:$(n.active_chains),running_operations:$(n.running_operations),recent_failures:$(n.recent_failures),last_history_event_at:d(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Bu).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Or).filter(a=>a!==null):[]}}function Ju(t){if(!A(t))return null;const e=d(t.id);return e?{id:e,type:d(t.type),status:d(t.status),duration_ms:$(t.duration_ms)??null,error:d(t.error)??null}:null}function zr(t){if(!A(t))return null;const e=d(t.run_id),n=d(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:$(t.duration_ms),success:Q(t.success),mermaid:d(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Ju).filter(a=>a!==null):[]}:null}function Vu(t){const e=A(t)?t:{};return{run:zr(e.run)}}function Qu(t){if(!A(t))return null;const e=d(t.title),n=d(t.path);return!e||!n?null:{title:e,path:n}}function Yu(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Xu(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.tool),s=d(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:ft(t.success_signals),pitfalls:ft(t.pitfalls)}}function Zu(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.summary),s=d(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(Xu).filter(o=>o!==null):[]}}function tp(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:ft(t.tools)}}function ep(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.symptom),s=d(t.why),o=d(t.fix_tool),r=d(t.fix_summary);return!e||!n||!a||!s||!o||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:o,fix_summary:r}}function np(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.path_id),s=d(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:ft(t.notes)}}function ap(t){const e=A(t)?t:{};return{version:d(e.version),generated_at:d(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Qu).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Yu).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Zu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(tp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(ep).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(np).filter(n=>n!==null):[]}}function sp(t){if(!A(t))return null;const e=d(t.id),n=d(t.title),a=d(t.status),s=d(t.detail),o=d(t.next_tool);return!e||!n||!a||!s||!o?null:{id:e,title:n,status:a,detail:s,next_tool:o}}function ip(t){if(!A(t))return null;const e=d(t.code),n=d(t.severity),a=d(t.title),s=d(t.detail),o=d(t.next_tool);return!e||!n||!a||!s||!o?null:{code:e,severity:n,title:a,detail:s,next_tool:o}}function op(t){if(!A(t))return null;const e=d(t.from),n=d(t.content),a=d(t.timestamp),s=$(t.seq);return!e||!n||!a||s==null?null:{seq:s,from:e,content:n,timestamp:a}}function rp(t){if(!A(t))return null;const e=d(t.name),n=d(t.role),a=d(t.lane),s=d(t.status),o=d(t.claim_marker),r=d(t.done_marker),l=d(t.final_marker);if(!e||!n||!a||!s||!o||!r||!l)return null;const u=(()=>{if(!A(t.last_message))return null;const f=$(t.last_message.seq),m=d(t.last_message.content),c=d(t.last_message.timestamp);return f==null||!m||!c?null:{seq:f,content:m,timestamp:c}})();return{name:e,role:n,lane:a,joined:Q(t.joined)??!1,live_presence:Q(t.live_presence)??!1,completed:Q(t.completed)??!1,status:s,current_task:d(t.current_task)??null,bound_task_id:d(t.bound_task_id)??null,bound_task_title:d(t.bound_task_title)??null,bound_task_status:d(t.bound_task_status)??null,current_task_matches_run:Q(t.current_task_matches_run)??!1,squad_member:Q(t.squad_member)??!1,detachment_member:Q(t.detachment_member)??!1,last_seen:d(t.last_seen)??null,heartbeat_age_sec:$(t.heartbeat_age_sec)??null,heartbeat_fresh:Q(t.heartbeat_fresh)??!1,claim_marker_seen:Q(t.claim_marker_seen)??!1,done_marker_seen:Q(t.done_marker_seen)??!1,final_marker_seen:Q(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:u}}function lp(t){if(!A(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!A(n))return null;const a=d(n.timestamp),s=$(n.active_slots);if(!a||s==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:s,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:d(t.slot_url)??null,provider_base_url:d(t.provider_base_url)??null,provider_reachable:Q(t.provider_reachable)??null,provider_status_code:$(t.provider_status_code)??null,provider_model_id:d(t.provider_model_id)??null,actual_model_id:d(t.actual_model_id)??null,expected_slots:$(t.expected_slots),actual_slots:$(t.actual_slots),expected_ctx:$(t.expected_ctx),actual_ctx:$(t.actual_ctx),slot_reachable:Q(t.slot_reachable)??null,slot_status_code:$(t.slot_status_code)??null,runtime_blocker:d(t.runtime_blocker)??null,detail:d(t.detail)??null,checked_at:d(t.checked_at)??null,total_slots:$(t.total_slots),ctx_per_slot:$(t.ctx_per_slot),active_slots_now:$(t.active_slots_now),peak_active_slots:$(t.peak_active_slots),sample_count:$(t.sample_count),last_sample_at:d(t.last_sample_at)??null,timeline:e}}function cp(t){const e=A(t)?t:{},n=A(e.summary)?e.summary:void 0;return{version:d(e.version),generated_at:d(e.generated_at),run_id:d(e.run_id),room_id:d(e.room_id),operation_id:d(e.operation_id)??null,recommended_next_tool:d(e.recommended_next_tool),summary:n?{expected_workers:$(n.expected_workers),joined_workers:$(n.joined_workers),live_workers:$(n.live_workers),squad_roster_size:$(n.squad_roster_size),detachment_roster_size:$(n.detachment_roster_size),current_task_bound:$(n.current_task_bound),fresh_heartbeats:$(n.fresh_heartbeats),claim_markers_seen:$(n.claim_markers_seen),done_markers_seen:$(n.done_markers_seen),final_markers_seen:$(n.final_markers_seen),completed_workers:$(n.completed_workers),peak_hot_slots:$(n.peak_hot_slots),hot_window_ok:Q(n.hot_window_ok),pass_hot_concurrency:Q(n.pass_hot_concurrency),pass_end_to_end:Q(n.pass_end_to_end),pending_decisions:$(n.pending_decisions),pass:Q(n.pass)}:void 0,provider:lp(e.provider),operation:ls(e.operation),squad:Hi(e.squad),detachment:Lr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(rp).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(sp).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(ip).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(op).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Ir).filter(a=>a!==null):[],truth_notes:ft(e.truth_notes)}}function qn(t){Ct.value=t,Ki(t)&&dp()}async function qr(){Pa.value=!0,Ea.value=null;try{const t=await Vl();Cr.value=Hu(t)}catch(t){Ea.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Pa.value=!1}}function Ui(t){He.value=t}async function Bi(){Da.value=!0,Ia.value=null;try{const t=await Jl();Bt.value=Ku(t)}catch(t){Ia.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Da.value=!1}}async function dp(){Bt.value||Da.value||await Bi()}async function Se(){await qr(),Ki(Ct.value)&&await Bi()}async function ae(){var t;mi.value=!0,qa.value=null;try{const e=await Ql(),n=Gu(e);Fi.value=n;const a=He.value;n.operations.length===0?He.value=null:(!a||!n.operations.some(s=>s.operation.operation_id===a))&&(He.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){qa.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{mi.value=!1}}function up(){un=null,On.value=null,ja.value=!1,zn.value=null}async function pp(t){un=t,ja.value=!0,zn.value=null;try{const e=await Yl(t);if(un!==t)return;On.value=Vu(e)}catch(e){if(un!==t)return;On.value=null,zn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{un===t&&(ja.value=!1)}}async function mp(){ui.value=!0,Oa.value=null;try{const t=await Xl();Vn.value=ap(t)}catch(t){Oa.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{ui.value=!1}}async function Wt(t=xu(),e=Su()){pi.value=!0,za.value=null;try{const n=await Zl(t,e);ji.value=cp(n)}catch(n){za.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{pi.value=!1}}async function ue(t,e,n){di.value=t,Ma.value=null;try{await tc(e,n),await qr(),(Bt.value||Ki(Ct.value))&&await Bi(),await Wt(),await ae()}catch(a){throw Ma.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{di.value=null}}function vp(t){return ue(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function fp(t){return ue(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function _p(t){return ue(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function gp(t={}){return ue("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function $p(t){return ue(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function hp(t){return ue(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function yp(t,e){return ue(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function bp(t,e){return ue(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Td(()=>{Se(),ae(),(Ct.value==="swarm"||ji.value!==null)&&Wt()});function kp(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function xp(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Sp(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function z(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let bo=!1,Ap=0,Ss=null;async function wp(){Ss||(Ss=ku(()=>import("./mermaid.core-9KfCkUnZ.js").then(e=>e.bE),[]).then(e=>e.default));const t=await Ss;return bo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),bo=!0),t}function se(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function cs(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Cp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Qn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ge(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Qn(t/e*100)}function Tp(t,e){const n=Qn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function jr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Fr=[{id:"summary",label:"요약"},{id:"swarm",label:"스웜"},{id:"operations",label:"작전"},{id:"chains",label:"체인"},{id:"topology",label:"토폴로지"},{id:"alerts",label:"알림"},{id:"trace",label:"트레이스"},{id:"control",label:"제어"}],Np=Fr.map(t=>t.id),Rp=["chain_start","node_start","node_complete","chain_complete","chain_error"];function Lp(t){return!!t&&Np.includes(t)}function Pp(t){if(t==="summary")return{};if(t==="chains"){const e=He.value;return e?{surface:t,operation:e}:{surface:t}}return{surface:t}}function Dp(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Ep(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function ct(t){return di.value===t}function ds(){return Cr.value}function ea({label:t,value:e,subtext:n,percent:a,color:s}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Tp(a,s)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Qn(a))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function na({label:t,value:e,detail:n,percent:a,tone:s}){return i`
    <article class="command-signal-rail ${z(s)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${z(s)}" style=${`width: ${Math.max(8,Math.round(Qn(a)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Ip(){var it,ot,B,V;const t=ds(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.detachments.summary,s=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,r=(it=t==null?void 0:t.swarm_status)==null?void 0:it.overview,l=t==null?void 0:t.swarm_proof,u=t==null?void 0:t.operations.microarch,f=(e==null?void 0:e.managed_unit_count)??0,m=(e==null?void 0:e.total_units)??0,c=(n==null?void 0:n.active)??0,v=(a==null?void 0:a.active)??0,h=(r==null?void 0:r.moving_lanes)??0,b=(r==null?void 0:r.active_lanes)??0,w=(l==null?void 0:l.workers.done)??0,N=(l==null?void 0:l.workers.expected)??0,P=(o==null?void 0:o.bad)??0,M=(o==null?void 0:o.warn)??0,D=(s==null?void 0:s.pending)??0,L=(s==null?void 0:s.total)??0,p=c+v,H=((ot=u==null?void 0:u.cache)==null?void 0:ot.l1_hit_rate)??((V=(B=u==null?void 0:u.signals)==null?void 0:B.cache_contention)==null?void 0:V.l1_hit_rate)??0,U=c>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",xt=c>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${U}</h3>
        <p>${xt}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${z(c>0?"ok":"warn")}">활성 작전 ${c}</span>
          <span class="command-chip ${z(h>0?"ok":(b>0,"warn"))}">이동 레인 ${h}/${Math.max(b,h)}</span>
          <span class="command-chip ${z(P>0?"bad":M>0?"warn":"ok")}">치명 알림 ${P}</span>
          <span class="command-chip ${z(D>0?"warn":"ok")}">승인 대기 ${D}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${ea}
          label="관리 단위 범위"
          value=${`${f}/${Math.max(m,f)}`}
          subtext=${m>0?`${m-f}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ge(f,Math.max(m,f))}
          color="#67e8f9"
        />
        <${ea}
          label="실행 열도"
          value=${String(p)}
          subtext=${`${c}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ge(p,Math.max(f,p||1))}
          color="#4ade80"
        />
        <${ea}
          label="스웜 이동감"
          value=${`${h}/${Math.max(b,h)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Z(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ge(h,Math.max(b,h||1))}
          color="#fbbf24"
        />
        <${ea}
          label="증거 수집률"
          value=${`${w}/${Math.max(N,w)}`}
          subtext=${l!=null&&l.status?`증거 소스 ${l.source} · ${l.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ge(w,Math.max(N,w||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${na}
        label="승인 대기열"
        value=${`${D}건 대기`}
        detail=${`현재 정책 창에서 ${L}개 결정을 추적 중입니다`}
        percent=${ge(D,Math.max(L,D||1))}
        tone=${D>0?"warn":"ok"}
      />
      <${na}
        label="알림 압력"
        value=${`${P} bad / ${M} warn`}
        detail=${P>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ge(P*2+M,Math.max((P+M)*2,1))}
        tone=${P>0?"bad":M>0?"warn":"ok"}
      />
      <${na}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${f>0?`${f}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ge(v,Math.max(f,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${na}
        label="캐시 신뢰도"
        value=${H?cs(H):"n/a"}
        detail=${H?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Qn((H??0)*100)}
        tone=${H>=.75?"ok":H>=.4?"warn":"bad"}
      />
    </div>
  `}function Mp(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Kr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((s,o)=>{t.has(o)||t.set(o,s)}),t}function Op(){const e=Kr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function zp(){const e=Kr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function qp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function jp(t){return t.status==="claimed"||t.status==="in_progress"}function Fp(t){const e=Vn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function As(t){var e;return((e=Vn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Kp(t){const e=Vn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function ie(t){try{await t()}catch{}}function Hp(){var m,c,v,h,b;const t=ds(),e=Fi.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,s=(m=t==null?void 0:t.swarm_status)==null?void 0:m.overview,o=t==null?void 0:t.operations.microarch,r=t==null?void 0:t.decisions.summary,l=t==null?void 0:t.alerts.summary,u=(c=o==null?void 0:o.signals)==null?void 0:c.issue_pressure,f=o==null?void 0:o.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(a==null?void 0:a.active)??0}</strong><small>${((v=t==null?void 0:t.detachments.summary)==null?void 0:v.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(r==null?void 0:r.pending)??0}</strong><small>${(r==null?void 0:r.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card"><span>알림</span><strong>${(l==null?void 0:l.bad)??0}</strong><small>${(l==null?void 0:l.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((h=e==null?void 0:e.summary)==null?void 0:h.active_chains)??0}</strong><small>${((b=e==null?void 0:e.summary)==null?void 0:b.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card"><span>스웜</span><strong>${(s==null?void 0:s.active_lanes)??0}</strong><small>${s?`${s.stalled_lanes??0}개 정체 · ${Z(s.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${cs(f.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function Hr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Up({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const s of t){const o=s.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const a=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function Bp({total:t}){const n=Math.min(t,20),a=t>20?t-20:0,s=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${s.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${a>0?i`<span class="swarm-worker-count">+${a}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Wp({lane:t}){const e=t.counts??{},n=Hr(t),a=e.workers??0,s=e.operations??0,o=e.detachments??0,r=s+o,l=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
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
          <span class="command-chip">${Z(t.last_movement_at)}</span>
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
        ${a>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Bp} total=${a} />
              </div>
            `:null}
        ${r>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${r>0?Math.round(s/r*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${s} · 실행체 ${o}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?i`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?i`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(u=>i`<span class="command-chip ${z(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Gp({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const a=Hr(n),s=n.counts.workers??0,o=n.counts.operations??0,r=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${z(a)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${z(a)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${s}</span>
              <span>작전 ${o}</span>
              <span>실행체 ${r}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function Jp({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,a=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${z(t.tone)}"></span>
      <span class="swarm-event-time">${a}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Vp({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${z(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Qp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${z(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${z(e)}">${(t==null?void 0:t.status)??"missing"}</span>
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
  `}function Yp(){const t=ds(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(f=>f.present))??[],s=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,8))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action,u=a.length<=1;return i`
    <section class="card command-section">
      <div class="card-title">스웜</div>
      ${e?i`
            <${Gp} lanes=${a} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Z(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`스냅샷 ${Z(e.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(l==null?void 0:l.label)??"운영자 상태 확인"}</strong><small>${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${a.length>0?i`<${Up} lanes=${a} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${a.length>0?a.map(f=>i`<${Wp} lane=${f} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Qp} proof=${n} />

                <div class="command-guide-card ${s.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${z(s.some(f=>f.severity==="bad")?"bad":s.length>0?"warn":"ok")}">${s.length}</span>
                  </div>
                  ${s.length>0?i`<div class="swarm-event-rail">${s.slice(0,4).map(f=>i`<${Vp} gap=${f} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${o.length}</span>
                  </div>
                  ${o.length>0?i`<div class="swarm-event-rail">${o.map(f=>i`<${Jp} event=${f} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Xp(){return i`
    <div class="command-surface-tabs">
      ${Fr.map(t=>i`
        <button
          class="command-surface-tab ${Ct.value===t.id?"active":""}"
          onClick=${()=>{qn(t.id),ht("command",Pp(t.id))}}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function Zp(){var it,ot,B,V,k,Et,Zt,pe,me;const t=ds(),e=Bt.value,n=de.value,a=Mp(),s=a?Tt.value.find(I=>I.name===a)??null:null,o=a?bt.value.filter(I=>I.assignee===a&&jp(I)):[],r=((it=t==null?void 0:t.operations.summary)==null?void 0:it.active)??0,l=((ot=t==null?void 0:t.detachments.summary)==null?void 0:ot.total)??0,u=((B=t==null?void 0:t.decisions.summary)==null?void 0:B.pending)??0,f=e==null?void 0:e.detachments.detachments.find(I=>{const It=I.detachment.heartbeat_deadline,ve=It?Date.parse(It):Number.NaN;return I.detachment.status==="stalled"||!Number.isNaN(ve)&&ve<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(I=>I.severity==="bad"),c=!!(n!=null&&n.room||n!=null&&n.project),v=(s==null?void 0:s.current_task)??null,h=qp(s==null?void 0:s.last_seen),b=h!=null?h<=120:null,w=[c?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},a?s?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${a} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:bt.value.length>0?"masc_claim":"masc_add_task"}:v?b===!1?{title:"Task 준비도",tone:"warn",detail:`${a} current_task=${v} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${a} current_task=${v}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((V=t.topology.summary)==null?void 0:V.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Et=t.topology.summary)==null?void 0:Et.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:f||m?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${f?` · detachment ${f.detachment.detachment_id} 가 stalled 상태입니다`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!f&&!m?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${l}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],N=c?!a||!s?"masc_join":o.length===0?bt.value.length>0?"masc_claim":"masc_add_task":v?b===!1?"masc_heartbeat":!t||(((Zt=t.topology.summary)==null?void 0:Zt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":u>0?"masc_policy_approve":r>0&&l===0||f||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",P=Fp(N),D=Kp(N==="masc_set_room"?["repo-root-room"]:N==="masc_plan_set_task"?["claimed-not-current"]:N==="masc_heartbeat"?["heartbeat-stale"]:N==="masc_dispatch_tick"?["no-detachments"]:N==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),L=As("room_task_hygiene"),p=As("cpv2_benchmark"),H=As("supervisor_session"),U=((pe=Vn.value)==null?void 0:pe.docs)??[],xt=[L,p,H].filter(I=>I!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title">즉시 조치</div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(P==null?void 0:P.title)??N}</strong>
            <span class="command-chip ok">${N}</span>
          </div>
          <p>${(P==null?void 0:P.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(me=P==null?void 0:P.success_signals)!=null&&me.length?i`<div class="command-tag-row">
                ${P.success_signals.map(I=>i`<span class="command-tag ok">${I}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${w.map(I=>i`
            <article class="command-readiness-row ${z(I.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${I.title}</strong>
                  <span class="command-chip ${z(I.tone)}">${I.tone}</span>
                </div>
                <p>${I.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${I.tool}</div>
            </article>
          `)}
        </div>

        ${D.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${D.length}</span>
                </div>
                <div class="command-guide-list">
                  ${D.map(I=>i`
                    <article class="command-guide-inline">
                      <strong>${I.title}</strong>
                      <div>${I.symptom}</div>
                      <div class="command-card-sub">${I.fix_tool} 로 해결: ${I.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title">운영 경로</div>
        ${ui.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Oa.value?i`<div class="empty-state error">${Oa.value}</div>`:i`
                <div class="command-path-grid">
                  ${xt.map(I=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${I.title}</strong>
                        <span class="command-chip">${I.id}</span>
                      </div>
                      <p>${I.summary}</p>
                      <div class="command-card-sub">${I.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${I.steps.slice(0,4).map(It=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${It.tool}</span>
                            <span>${It.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${U.length>0?i`<div class="command-doc-links">
                      ${U.map(I=>i`<span class="command-tag">${I.title}: ${I.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function tm(){return i`
    <${Ip} />
    <${Hp} />
    <${Zp} />
  `}function em(){return Da.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ia.value?i`<div class="empty-state error">${Ia.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Ur({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Ep(t.unit.kind)}</span>
            <span class="command-chip ${z(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>i`<${Ur} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function nm({source:t}){const e=Ho(null),[n,a]=is(null);return st(()=>{let s=!1;const o=e.current;return o?(o.innerHTML="",a(null),(async()=>{try{const l=await wp(),{svg:u}=await l.render(`command-chain-${++Ap}`,t);if(s||!e.current)return;e.current.innerHTML=u}catch(l){if(s)return;a(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{s=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function am({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,s=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${se(a==null?void 0:a.status)}">${(a==null?void 0:a.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(a==null?void 0:a.kind)??"chain_dsl"}</span>
        ${a!=null&&a.chain_id?i`<span class="command-tag">${a.chain_id}</span>`:null}
        ${s?i`<span class="command-tag ${se(a==null?void 0:a.status)}">${cs(s.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${jr(t.history)}</div>
    </button>
  `}function sm({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${se(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${jr(t)}</div>
    </article>
  `}function im({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${se(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function om({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`,o=e.chain,r=(o==null?void 0:o.run_id)??null;return i`
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
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${se(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{qn("swarm"),ht("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ui(e.operation_id),qn("chains"),ht("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ie(()=>vp(e.operation_id))}>
                ${ct(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>ie(()=>_p(e.operation_id))}>
                ${ct(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ct(a)} onClick=${()=>ie(()=>fp(e.operation_id))}>
                ${ct(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function rm({card:t}){var n;const e=t.detachment;return i`
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
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Sp(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${xp(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function lm({alert:t}){return i`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Z(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Br({event:t}){return i`
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
      <pre class="command-trace-detail">${kp(t.detail)}</pre>
    </article>
  `}function cm({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return i`
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
        <span>Created</span><span>${Z(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ct(e)} onClick=${()=>ie(()=>$p(t.decision_id))}>
                ${ct(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ie(()=>hp(t.decision_id))}>
                ${ct(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function dm({row:t}){var l,u,f;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((l=e.policy)!=null&&l.frozen),o=!!((u=e.policy)!=null&&u.kill_switch),r=Math.round((t.utilization??0)*100);return i`
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
        <span>Autonomy</span><span>${((f=e.policy)==null?void 0:f.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ie(()=>yp(e.unit_id,!s))}>
          ${ct(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${ct(a)} onClick=${()=>ie(()=>bp(e.unit_id,!o))}>
          ${ct(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function um({item:t}){return i`
    <article class="command-guide-card ${z(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function pm({blocker:t}){return i`
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
  `}function mm({worker:t}){return i`
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
      ${t.last_message?i`<div class="command-card-foot">${Z(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function vm(){var u,f,m,c,v,h,b,w,N,P,M,D,L,p,H,U,xt,it,ot,B,V;const t=ji.value,e=Op(),n=zp(),a=(u=t==null?void 0:t.provider)!=null&&u.runtime_blocker?"blocked":(f=t==null?void 0:t.provider)!=null&&f.provider_reachable?"ready":"check",s=((m=t==null?void 0:t.provider)==null?void 0:m.actual_slots)??((c=t==null?void 0:t.provider)==null?void 0:c.total_slots)??0,o=((v=t==null?void 0:t.provider)==null?void 0:v.expected_slots)??"n/a",r=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((b=t==null?void 0:t.provider)==null?void 0:b.ctx_per_slot)??0,l=((w=t==null?void 0:t.provider)==null?void 0:w.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Yp} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title">스웜 라이브 런</div>
          ${pi.value?i`<div class="empty-state">Loading swarm live state…</div>`:za.value?i`<div class="empty-state error">${za.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((N=t.summary)==null?void 0:N.joined_workers)??0}/${((P=t.summary)==null?void 0:P.expected_workers)??0}</strong><small>${((M=t.summary)==null?void 0:M.live_workers)??0}개 가동 · ${((D=t.summary)==null?void 0:D.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${a}</strong><small>slots ${s}/${o} · ctx ${r}/${l}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(L=t.summary)!=null&&L.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((p=t.provider)==null?void 0:p.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(H=t.summary)!=null&&H.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((U=t.operation)==null?void 0:U.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((xt=t.squad)==null?void 0:xt.label)??"없음"}</span>
                      <span>실행체</span><span>${((it=t.detachment)==null?void 0:it.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((ot=t.summary)==null?void 0:ot.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((B=t.summary)==null?void 0:B.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((V=t.provider)==null?void 0:V.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(k=>i`<span class="command-tag">${k}</span>`)}
                        </div>`:null}
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">체크리스트</div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(k=>i`<${um} item=${k} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">워커</div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(k=>i`<${mm} worker=${k} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">런타임</div>
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
                      ${t.provider.timeline.slice(-12).map(k=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${k.active_slots} active</strong>
                              <span class="command-chip">${Z(k.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${k.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">막힘 요인</div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(k=>i`<${pm} blocker=${k} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 메시지</div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(k=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${k.from}</strong>
                        <span class="command-chip">${Z(k.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${k.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${k.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 트레이스 이벤트</div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(k=>i`<${Br} event=${k} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function fm(){const t=Bt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${om} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${rm} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function _m(){var l,u,f,m,c,v,h,b,w,N,P,M,D,L,p,H;const t=Fi.value,e=(t==null?void 0:t.operations)??[],n=He.value,a=e.find(U=>U.operation.operation_id===n)??e[0]??null,s=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((u=On.value)==null?void 0:u.run)??(a==null?void 0:a.preview_run)??null,r=!((f=On.value)!=null&&f.run)&&!!(a!=null&&a.preview_run);return st(()=>{s?pp(s):up()},[s]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title">Chains</div>
        <article class="command-guide-card ${se(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${se(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((m=t==null?void 0:t.summary)==null?void 0:m.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((c=t==null?void 0:t.summary)==null?void 0:c.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${qa.value?i`<div class="empty-state error">${qa.value}</div>`:null}

        ${mi.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(U=>i`
                    <${am}
                      overlay=${U}
                      selected=${(a==null?void 0:a.operation.operation_id)===U.operation.operation_id}
                      onSelect=${()=>Ui(U.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(U=>i`<${sm} item=${U} />`)}
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
                  <span class="command-chip ${se((b=a.operation.chain)==null?void 0:b.status)}">
                    ${((w=a.operation.chain)==null?void 0:w.status)??a.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((N=a.operation.chain)==null?void 0:N.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((P=a.operation.chain)==null?void 0:P.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${s??"not materialized"}</span>
                  <span>Progress</span><span>${cs((M=a.runtime)==null?void 0:M.progress)}</span>
                  <span>Elapsed</span><span>${Cp((D=a.runtime)==null?void 0:D.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((L=a.operation.chain)==null?void 0:L.last_sync_at)??a.operation.updated_at)}</span>
                </div>
                ${(p=a.operation.chain)!=null&&p.goal?i`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((H=a.operation.chain)==null?void 0:H.chain_id)??"graph"}</span>
                      </div>
                      <${nm} source=${a.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${ja.value?i`<div class="empty-state">Loading run detail…</div>`:zn.value?i`<div class="empty-state error">${zn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(U=>i`<${im} node=${U} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function gm(){const t=Bt.value;return i`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Ur} node=${e} />`)}`:i`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function $m(){const t=Bt.value;return i`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${lm} alert=${e} />`)}
          </div>`:i`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function hm(){const t=Bt.value;return i`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Br} event=${e} />`)}
          </div>`:i`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function ym(){const t=Bt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${cm} decision=${e} />`)}
            </div>`:i`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${dm} row=${e} />`)}
            </div>`:i`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function bm(){if(Ct.value==="summary")return i`<${tm} />`;if(Ct.value==="swarm")return i`<${vm} />`;if(!Bt.value)return i`<${em} />`;switch(Ct.value){case"chains":return i`<${_m} />`;case"topology":return i`<${gm} />`;case"alerts":return i`<${$m} />`;case"trace":return i`<${hm} />`;case"control":return i`<${ym} />`;case"operations":default:return i`<${fm} />`}}function km(){return st(()=>{Se(),ae(),mp(),Wt()},[]),st(()=>{if(nt.value.tab!=="command")return;const t=nt.value.params.surface,e=nt.value.params.operation;Lp(t)?qn(t):t||qn("summary"),e&&Ui(e),t==="swarm"&&Wt()},[nt.value.tab,nt.value.params.surface,nt.value.params.operation,nt.value.params.operation_id,nt.value.params.run_id]),st(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Se(),ae(),Ct.value==="swarm"&&Wt()},250))},n=new EventSource(Dp()),a=Rp.map(s=>{const o=()=>e();return n.addEventListener(s,o),{type:s,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:s,handler:o})=>{n.removeEventListener(s,o)}),n.close(),t&&window.clearTimeout(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면 / Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ie(()=>gp())}}
            disabled=${ct("dispatch:tick")}
          >
            ${ct("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Se(),ae(),Wt()}}
            disabled=${Pa.value}
          >
            ${Pa.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${Ea.value?i`<div class="empty-state error">${Ea.value}</div>`:null}
      ${Ma.value?i`<div class="empty-state error">${Ma.value}</div>`:null}
      <${Xp} />
      <${bm} />
    </section>
  `}const Yn=_(null),Wr=_(null),Qt=_(null),Fa=_(!1),le=_(null),jn=_(!1),Ve=_(null),J=_(!1),Ka=_([]);let xm=1;function K(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function Y(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function us(t){return typeof t=="boolean"?t:void 0}function Sm(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function jt(t,e=[]){if(Array.isArray(t))return t;if(!K(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Am(t){return K(t)?{id:x(t.id),seq:Y(t.seq),from:x(t.from)??x(t.from_agent)??"system",content:x(t.content)??"",timestamp:x(t.timestamp)??new Date().toISOString(),type:x(t.type)}:null}function wm(t){return K(t)?{room_id:x(t.room_id),current_room:x(t.current_room)??x(t.room),project:x(t.project),cluster:x(t.cluster),paused:us(t.paused),pause_reason:x(t.pause_reason)??null,paused_by:x(t.paused_by)??null,paused_at:x(t.paused_at)??null}:{}}function ko(t){if(!K(t))return;const e=Object.entries(t).map(([n,a])=>{const s=x(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Gr(t){if(!K(t))return null;const e=x(t.kind),n=x(t.summary),a=x(t.target_type);return!e||!n||!a?null:{kind:e,severity:x(t.severity)??"warn",summary:n,target_type:a,target_id:x(t.target_id)??null,actor:x(t.actor)??null,evidence:t.evidence}}function Jr(t){if(!K(t))return null;const e=x(t.action_type),n=x(t.target_type),a=x(t.reason);return!e||!n||!a?null:{action_type:e,target_type:n,target_id:x(t.target_id)??null,severity:x(t.severity)??"warn",reason:a,confirm_required:us(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Cm(t){return K(t)?{actor:x(t.actor)??null,spawn_agent:x(t.spawn_agent)??null,spawn_role:x(t.spawn_role)??null,spawn_model:x(t.spawn_model)??null,worker_class:x(t.worker_class)??null,parent_actor:x(t.parent_actor)??null,capsule_mode:x(t.capsule_mode)??null,runtime_pool:x(t.runtime_pool)??null,lane_id:x(t.lane_id)??null,controller_level:x(t.controller_level)??null,control_domain:x(t.control_domain)??null,supervisor_actor:x(t.supervisor_actor)??null,model_tier:x(t.model_tier)??null,task_profile:x(t.task_profile)??null,risk_level:x(t.risk_level)??null,routing_confidence:Y(t.routing_confidence)??null,routing_reason:x(t.routing_reason)??null,status:x(t.status)??"unknown",turn_count:Y(t.turn_count)??0,empty_note_turn_count:Y(t.empty_note_turn_count)??0,has_turn:us(t.has_turn)??!1,last_turn_ts_iso:x(t.last_turn_ts_iso)??null}:null}function Tm(t){if(!K(t))return null;const e=x(t.session_id);return e?{session_id:e,goal:x(t.goal),status:x(t.status),health:x(t.health),scale_profile:x(t.scale_profile),control_profile:x(t.control_profile),planned_worker_count:Y(t.planned_worker_count),active_agent_count:Y(t.active_agent_count),last_turn_age_sec:Y(t.last_turn_age_sec)??null,attention_count:Y(t.attention_count),recommended_action_count:Y(t.recommended_action_count),top_attention:Gr(t.top_attention),top_recommendation:Jr(t.top_recommendation)}:null}function Vr(t){const e=K(t)?t:{};return{trace_id:x(e.trace_id),target_type:x(e.target_type)??"room",target_id:x(e.target_id)??null,health:x(e.health),swarm_status:K(e.swarm_status)?e.swarm_status:void 0,attention_items:jt(e.attention_items).map(Gr).filter(n=>n!==null),recommended_actions:jt(e.recommended_actions).map(Jr).filter(n=>n!==null),session_cards:jt(e.session_cards).map(Tm).filter(n=>n!==null),worker_cards:jt(e.worker_cards).map(Cm).filter(n=>n!==null)}}function Nm(t){if(!K(t))return null;const e=K(t.status)?t.status:void 0,n=K(t.summary)?t.summary:K(e==null?void 0:e.summary)?e.summary:void 0,a=K(t.session)?t.session:K(e==null?void 0:e.session)?e.session:void 0,s=x(t.session_id)??x(n==null?void 0:n.session_id)??x(a==null?void 0:a.session_id);if(!s)return null;const o=ko(t.report_paths)??ko(e==null?void 0:e.report_paths),r=jt(t.recent_events,["events"]).filter(K);return{session_id:s,status:x(t.status)??x(n==null?void 0:n.status)??x(a==null?void 0:a.status),progress_pct:Y(t.progress_pct)??Y(n==null?void 0:n.progress_pct),elapsed_sec:Y(t.elapsed_sec)??Y(n==null?void 0:n.elapsed_sec),remaining_sec:Y(t.remaining_sec)??Y(n==null?void 0:n.remaining_sec),done_delta_total:Y(t.done_delta_total)??Y(n==null?void 0:n.done_delta_total),summary:n,team_health:K(t.team_health)?t.team_health:K(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:K(t.communication_metrics)?t.communication_metrics:K(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:K(t.orchestration_state)?t.orchestration_state:K(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:K(t.cascade_metrics)?t.cascade_metrics:K(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function Rm(t){if(!K(t))return null;const e=x(t.name);if(!e)return null;const n=K(t.context)?t.context:void 0;return{name:e,agent_name:x(t.agent_name),status:x(t.status),autonomy_level:x(t.autonomy_level),context_ratio:Y(t.context_ratio)??Y(n==null?void 0:n.context_ratio),generation:Y(t.generation),active_goal_ids:Sm(t.active_goal_ids),last_autonomous_action_at:x(t.last_autonomous_action_at)??null,last_turn_ago_s:Y(t.last_turn_ago_s),model:x(t.model)??x(t.active_model)??x(t.primary_model)}}function Lm(t){if(!K(t))return null;const e=x(t.confirm_token)??x(t.token);return e?{confirm_token:e,actor:x(t.actor),action_type:x(t.action_type),target_type:x(t.target_type),target_id:x(t.target_id)??null,delegated_tool:x(t.delegated_tool),created_at:x(t.created_at),preview:t.preview}:null}function Pm(t){const e=K(t)?t:{};return{room:wm(e.room),sessions:jt(e.sessions,["items","sessions"]).map(Nm).filter(n=>n!==null),keepers:jt(e.keepers,["items","keepers"]).map(Rm).filter(n=>n!==null),recent_messages:jt(e.recent_messages,["messages"]).map(Am).filter(n=>n!==null),pending_confirms:jt(e.pending_confirms,["items","confirms"]).map(Lm).filter(n=>n!==null),available_actions:jt(e.available_actions,["actions"]).filter(K).map(n=>({action_type:x(n.action_type)??"unknown",target_type:x(n.target_type)??"unknown",description:x(n.description),confirm_required:us(n.confirm_required)}))}}function aa(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function xo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ha(t){Ka.value=[{...t,id:xm++,at:new Date().toISOString()},...Ka.value].slice(0,20)}function Qr(t){return t.confirm_required?aa(t.preview)||"Confirmation required":aa(t.result)||aa(t.executed_action)||aa(t.delegated_tool_result)||t.status}async function we(){Fa.value=!0,le.value=null;try{const t=await Gl();Yn.value=Pm(t)}catch(t){le.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Fa.value=!1}}async function ce(){jn.value=!0,Ve.value=null;try{const t=await Zo({targetType:"room"});Wr.value=Vr(t)}catch(t){Ve.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{jn.value=!1}}async function Fn(t){if(!t){Qt.value=null;return}jn.value=!0,Ve.value=null;try{const e=await Zo({targetType:"team_session",targetId:t,includeWorkers:!0});Qt.value=Vr(e)}catch(e){Ve.value=e instanceof Error?e.message:"Failed to load session digest"}finally{jn.value=!1}}async function Dm(t){var e;J.value=!0,le.value=null;try{const n=await Jn(t);return Ha({actor:t.actor,action_type:t.action_type,target_label:xo(t),outcome:n.confirm_required?"preview":"executed",message:Qr(n),delegated_tool:n.delegated_tool}),await we(),await ce(),(e=Qt.value)!=null&&e.target_id&&await Fn(Qt.value.target_id),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";throw le.value=a,Ha({actor:t.actor,action_type:t.action_type,target_label:xo(t),outcome:"error",message:a}),n}finally{J.value=!1}}async function Em(t,e){var n;J.value=!0,le.value=null;try{const a=await nc(t,e);return Ha({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Qr(a),delegated_tool:a.delegated_tool}),await we(),await ce(),(n=Qt.value)!=null&&n.target_id&&await Fn(Qt.value.target_id),a}catch(a){const s=a instanceof Error?a.message:"Operator confirmation failed";throw le.value=s,Ha({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),a}finally{J.value=!1}}Nd(()=>{var t;we(),ce(),(t=Qt.value)!=null&&t.target_id&&Fn(Qt.value.target_id)});const Yr="masc_dashboard_agent_name";function Im(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Yr))==null?void 0:a.trim())||"dashboard"}const ps=_(Im()),_n=_(""),vi=_("Operator pause"),gn=_(""),Ua=_(""),fi=_("2"),Ba=_(""),Ue=_("note"),Wa=_(""),Ga=_(""),Ja=_(""),_i=_("2"),gi=_("Operator stop request"),$i=_(""),$n=_("");function Mm(t){const e=t.trim()||"dashboard";ps.value=e,localStorage.setItem(Yr,e)}function ws(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Om(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function Kn(t){return typeof t=="string"?t.trim().toLowerCase():""}function zm(t){var a;const e=Kn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Kn((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function So(t){const e=Kn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Ao(t){return t.some(e=>Kn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function qm(t){return t.target_type==="team_session"}function jm(t){return t.target_type==="keeper"}async function Ce(t){const e=ps.value.trim()||"dashboard";try{const n=await Dm({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?T("Confirmation queued","warning"):T(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return T(a,"error"),null}}async function wo(){const t=_n.value.trim();if(!t)return;await Ce({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(_n.value="")}async function Fm(){await Ce({action_type:"room_pause",target_type:"room",payload:{reason:vi.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function Km(){await Ce({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function Hm(){const t=gn.value.trim();if(!t)return;await Ce({action_type:"task_inject",target_type:"room",payload:{title:t,description:Ua.value.trim()||"Injected from Ops tab",priority:Number.parseInt(fi.value,10)||2},successMessage:"Task injection submitted"})&&(gn.value="",Ua.value="")}async function Um(){var o;const t=Yn.value,e=Ba.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){T("Select a team session first","warning");return}const n={turn_kind:Ue.value},a=Wa.value.trim();a&&(n.message=a),Ue.value==="task"&&(n.task_title=Ga.value.trim()||"Operator injected task",n.task_description=Ja.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(_i.value,10)||2),await Ce({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Wa.value="",Ue.value==="task"&&(Ga.value="",Ja.value=""))}async function Bm(){var n;const t=Yn.value,e=Ba.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){T("Select a team session first","warning");return}await Ce({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:gi.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Wm(){var s;const t=Yn.value,e=$i.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=$n.value.trim();if(!e){T("Select a keeper first","warning");return}if(!n)return;await Ce({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&($n.value="")}async function Co(t){const e=ps.value.trim()||"dashboard";try{await Em(e,t),T("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";T(a,"error")}}function Gm(){var P,M,D,L;const t=Yn.value,e=Wr.value,n=Qt.value,a=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],r=(t==null?void 0:t.pending_confirms)??[],l=(t==null?void 0:t.recent_messages)??[],u=s.find(p=>p.session_id===Ba.value)??s[0]??null,f=o.find(p=>p.name===$i.value)??o[0]??null,m=(e==null?void 0:e.attention_items)??[],c=m.filter(qm),v=m.filter(jm),h=s.filter(p=>zm(p)!=="ok"),b=o.filter(p=>So(p)!=="ok"),w=l.slice(0,5);st(()=>{ce()},[]),st(()=>{const p=(u==null?void 0:u.session_id)??null;Fn(p)},[u==null?void 0:u.session_id]);const N=[{key:"room",label:"Room Gate",value:a.paused?"Paused":"Open",detail:a.paused?`Resume gate armed${a.pause_reason?` · ${a.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:a.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:r.length,detail:r.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:r.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:c.length>0?c.length:s.length,detail:c.length>0?((P=c[0])==null?void 0:P.summary)??"Team sessions need steering, stop, or checkpoint attention":s.length===0?"No supervised team session is active right now":"No session-level attention items are currently active",tone:c.length>0?Ao(c):s.length===0?"warn":h.some(p=>Kn(p.status)==="paused")?"bad":h.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:v.length>0?v.length:b.length,detail:v.length>0?((M=v[0])==null?void 0:M.summary)??"At least one keeper needs direct intervention":b.length>0?"At least one keeper is stale, offline, or missing telemetry":"Keepers are available for direct intervention",tone:v.length>0?Ao(v):b.some(p=>So(p)==="bad")?"bad":b.length>0?"warn":"ok"}];return i`
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
            value=${ps.value}
            onInput=${p=>Mm(p.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{we(),ce(),Fn((u==null?void 0:u.session_id)??null)}}
            disabled=${Fa.value||J.value}
          >
            ${Fa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${le.value?i`
        <section class="ops-banner error">${le.value}</section>
      `:null}
      ${Ve.value?i`
        <section class="ops-banner error">${Ve.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${N.map(p=>i`
            <div key=${p.key} class="ops-priority-card ${p.tone}">
              <span class="ops-priority-label">${p.label}</span>
              <strong>${p.value}</strong>
              <div class="ops-priority-detail">${p.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title">Recommended Actions</div>
        <p class="ops-context-note">Digest-backed recommendations are the smallest next interventions the backend currently suggests.</p>
        ${jn.value&&!e?i`
          <div class="ops-empty">Loading operator digest…</div>
        `:e&&e.recommended_actions.length>0?i`
          <div class="ops-log-list">
            ${e.recommended_actions.map(p=>i`
              <article key=${`${p.action_type}:${p.target_type}:${p.target_id??"room"}`} class="ops-log-entry ${p.severity}">
                <div class="ops-log-head">
                  <strong>${p.action_type}</strong>
                  <span>${p.target_type}${p.target_id?`:${p.target_id}`:""}</span>
                  <span>${p.confirm_required?"confirm":"direct"}</span>
                </div>
                <div class="ops-log-body">${p.reason}</div>
              </article>
            `)}
          </div>
        `:i`
          <div class="ops-empty">No digest recommendations are active right now.</div>
        `}
      </section>

      ${r.length>0?i`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${r.map(p=>i`
              <article key=${p.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${p.action_type??"unknown"}</strong>
                  <span>${p.target_type??"target"}${p.target_id?`:${p.target_id}`:""}</span>
                  <span>${p.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${p.preview?i`<pre class="ops-code-block">${ws(p.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Co(p.confirm_token)}} disabled=${J.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${p.confirm_token}</span>
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
            ${r.length>0?i`
              <div class="ops-confirmation-list">
                ${r.map(p=>i`
                  <article key=${p.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${p.action_type??"unknown"}</strong>
                      <span>${p.target_type??"target"}${p.target_id?`:${p.target_id}`:""}</span>
                      <span>${p.delegated_tool??"delegated tool pending"}</span>
                    </div>
                    ${p.preview?i`<pre class="ops-code-block compact">${ws(p.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Co(p.confirm_token)}} disabled=${J.value}>
                        Confirm
                      </button>
                      <span class="ops-token">${p.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:i`<div class="ops-empty">No pending confirmations.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Operator Log</div>
            <div class="ops-log-list">
              ${Ka.value.length===0?i`
                <div class="ops-empty">No operator actions in this session yet.</div>
              `:Ka.value.map(p=>i`
                <article key=${p.id} class="ops-log-entry ${p.outcome}">
                  <div class="ops-log-head">
                    <strong>${p.action_type}</strong>
                    <span>${p.target_label}</span>
                    <span>${p.at}</span>
                  </div>
                  <div class="ops-log-body">${p.message}</div>
                </article>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Room Feed</div>
            <p class="ops-context-note">Recent chatter stays available for operator context, but it is secondary to the intervention queue.</p>
            ${w.length>0?i`
              <div class="ops-feed-list">
                ${w.map(p=>i`
                  <article key=${p.seq??p.id??p.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${p.from}</strong>
                      <span>${p.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${p.content}</div>
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
              ${s.length===0?i`<div class="ops-empty">No team sessions available.</div>`:s.map(p=>{var H;return i`
                <button
                  key=${p.session_id}
                  class="ops-entity-card ${(u==null?void 0:u.session_id)===p.session_id?"active":""}"
                  onClick=${()=>{Ba.value=p.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${p.session_id}</strong>
                    <span class="status-badge ${p.status??"idle"}">${p.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(p.progress_pct??0)}%</span>
                    <span>${p.done_delta_total??0} done</span>
                    <span>${(H=p.team_health)!=null&&H.status?String(p.team_health.status):"health n/a"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Session Digest</div>
            <p class="ops-context-note">Worker cards and attention items come from operator digest, not the lighter snapshot.</p>
            ${u&&n?i`
              <div class="ops-log-list">
                ${n.attention_items.length>0?n.attention_items.map(p=>i`
                  <article key=${`${p.kind}:${p.target_id??"session"}`} class="ops-log-entry ${p.severity}">
                    <div class="ops-log-head">
                      <strong>${p.kind}</strong>
                      <span>${p.target_type}${p.target_id?`:${p.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${p.summary}</div>
                  </article>
                `):i`<div class="ops-empty">No session-specific attention items.</div>`}
                ${n.worker_cards.length>0?n.worker_cards.map(p=>i`
                  <article key=${`${p.actor??p.spawn_role??"worker"}:${p.spawn_agent??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${p.actor??p.spawn_role??"worker"}</strong>
                      <span>${p.status}</span>
                      <span>${p.spawn_agent??p.runtime_pool??"runtime n/a"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${p.worker_class??"worker"}${p.lane_id?` · ${p.lane_id}`:""}${p.routing_reason?` · ${p.routing_reason}`:""}
                    </div>
                  </article>
                `):null}
              </div>
            `:i`
              <div class="ops-empty">Select a team session to load digest-backed worker cards.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title">Keeper Queue</div>
            <p class="ops-context-note">Keepers are long-lived operators. Pick one when you need recovery, course correction, or a direct probe.</p>
            <div class="ops-entity-list">
              ${o.length===0?i`<div class="ops-empty">No keepers available.</div>`:o.map(p=>i`
                <button
                  key=${p.name}
                  class="ops-entity-card ${(f==null?void 0:f.name)===p.name?"active":""}"
                  onClick=${()=>{$i.value=p.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${p.name}</strong>
                    <span class="status-badge ${p.status??"idle"}">${p.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${p.model??"model n/a"}</span>
                    <span>${typeof p.context_ratio=="number"?`${Math.round(p.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                    <span>${Om(p.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title">Available Actions</div>
            <p class="ops-context-note">These are the actions the backend currently advertises, even if they are not all wired into inline controls yet.</p>
            <div class="ops-log-list">
              ${(D=t==null?void 0:t.available_actions)!=null&&D.length?t.available_actions.map(p=>i`
                    <article key=${`${p.action_type}:${p.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${p.action_type}</strong>
                        <span>${p.target_type}</span>
                        <span>${p.confirm_required?"confirm":"direct"}</span>
                      </div>
                      <div class="ops-log-body">${p.description??"No description"}</div>
                    </article>
                  `):i`<div class="ops-empty">No available action descriptors.</div>`}
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
                  <strong>${a.current_room??a.room_id??"default"}</strong>
                </div>
                <div class="ops-stat">
                  <span>Project</span>
                  <strong>${a.project??"n/a"}</strong>
                </div>
                <div class="ops-stat">
                  <span>Cluster</span>
                  <strong>${a.cluster??"n/a"}</strong>
                </div>
                <div class="ops-stat ${a.paused?"warn":"ok"}">
                  <span>Status</span>
                  <strong>${a.paused?"Paused":"Running"}</strong>
                </div>
              </div>

              <label class="control-label" for="ops-broadcast">Room Broadcast</label>
              <div class="control-row">
                <input
                  id="ops-broadcast"
                  class="control-input"
                  type="text"
                  placeholder="@agent or room-wide operator update"
                  value=${_n.value}
                  onInput=${p=>{_n.value=p.target.value}}
                  onKeyDown=${p=>{p.key==="Enter"&&wo()}}
                  disabled=${J.value}
                />
                <button class="control-btn" onClick=${()=>{wo()}} disabled=${J.value||_n.value.trim()===""}>
                  Send
                </button>
              </div>

              <label class="control-label" for="ops-pause-reason">Pause or Resume</label>
              <div class="control-row ops-split-row">
                <input
                  id="ops-pause-reason"
                  class="control-input"
                  type="text"
                  value=${vi.value}
                  onInput=${p=>{vi.value=p.target.value}}
                  disabled=${J.value}
                />
                <button class="control-btn ghost" onClick=${()=>{Fm()}} disabled=${J.value}>
                  Pause
                </button>
                <button class="control-btn ghost" onClick=${()=>{Km()}} disabled=${J.value}>
                  Resume
                </button>
              </div>

              <div class="ops-section-head">Inject Work</div>
              <input
                class="control-input"
                type="text"
                placeholder="Task title"
                value=${gn.value}
                onInput=${p=>{gn.value=p.target.value}}
                disabled=${J.value}
              />
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Task description"
                value=${Ua.value}
                onInput=${p=>{Ua.value=p.target.value}}
                disabled=${J.value}
              ></textarea>
              <div class="control-row ops-split-row">
                <select
                  class="control-input ops-select"
                  value=${fi.value}
                  onChange=${p=>{fi.value=p.target.value}}
                  disabled=${J.value}
                >
                  <option value="1">P1</option>
                  <option value="2">P2</option>
                  <option value="3">P3</option>
                  <option value="4">P4</option>
                  <option value="5">P5</option>
                </select>
                <button class="control-btn" onClick=${()=>{Hm()}} disabled=${J.value||gn.value.trim()===""}>
                  Inject
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Session</div>
              ${u?i`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${u.session_id}</div>
                  <div class="ops-detail-meta">
                    <span>Status: ${u.status??"unknown"}</span>
                    <span>Elapsed: ${u.elapsed_sec??0}s</span>
                    <span>Remaining: ${u.remaining_sec??0}s</span>
                  </div>
                  ${u.recent_events&&u.recent_events.length>0?i`
                    <pre class="ops-code-block compact">${ws(u.recent_events.slice(-3))}</pre>
                  `:null}
                </div>
              `:i`<div class="ops-empty">Select a team session to edit notes, inject tasks, or stop the run.</div>`}

              <label class="control-label" for="ops-turn-kind">Session Action</label>
              <div class="control-row ops-split-row">
                <select
                  id="ops-turn-kind"
                  class="control-input ops-select"
                  value=${Ue.value}
                  onChange=${p=>{Ue.value=p.target.value}}
                  disabled=${J.value||!u}
                >
                  <option value="note">Note</option>
                  <option value="broadcast">Broadcast</option>
                  <option value="task">Task</option>
                  <option value="checkpoint">Checkpoint</option>
                </select>
                <button class="control-btn" onClick=${()=>{Um()}} disabled=${J.value||!u}>
                  Apply
                </button>
              </div>
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Session message"
                value=${Wa.value}
                onInput=${p=>{Wa.value=p.target.value}}
                disabled=${J.value||!u}
              ></textarea>
              ${Ue.value==="task"?i`
                <input
                  class="control-input"
                  type="text"
                  placeholder="Injected task title"
                  value=${Ga.value}
                  onInput=${p=>{Ga.value=p.target.value}}
                  disabled=${J.value||!u}
                />
                <textarea
                  class="control-textarea"
                  rows=${2}
                  placeholder="Injected task description"
                  value=${Ja.value}
                  onInput=${p=>{Ja.value=p.target.value}}
                  disabled=${J.value||!u}
                ></textarea>
                <select
                  class="control-input ops-select"
                  value=${_i.value}
                  onChange=${p=>{_i.value=p.target.value}}
                  disabled=${J.value||!u}
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
                  value=${gi.value}
                  onInput=${p=>{gi.value=p.target.value}}
                  disabled=${J.value||!u}
                />
                <button class="control-btn ghost" onClick=${()=>{Bm()}} disabled=${J.value||!u}>
                  Stop
                </button>
              </div>
            </div>

            <div class="ops-studio-group">
              <div class="ops-section-head">Selected Keeper</div>
              ${f?i`
                <div class="ops-detail-card">
                  <div class="ops-detail-title">${f.name}</div>
                  <div class="ops-detail-meta">
                    <span>Autonomy: ${f.autonomy_level??"n/a"}</span>
                    <span>Generation: ${f.generation??0}</span>
                    <span>Goals: ${((L=f.active_goal_ids)==null?void 0:L.length)??0}</span>
                  </div>
                </div>
              `:i`<div class="ops-empty">Select a keeper to send a direct intervention.</div>`}

              <label class="control-label" for="ops-keeper-message">Keeper Message</label>
              <textarea
                id="ops-keeper-message"
                class="control-textarea"
                rows=${6}
                placeholder="Send a structured intervention or course correction"
                value=${$n.value}
                onInput=${p=>{$n.value=p.target.value}}
                disabled=${J.value||!f}
              ></textarea>
              <div class="control-row">
                <button class="control-btn" onClick=${()=>{Wm()}} disabled=${J.value||!f||$n.value.trim()===""}>
                  Send Keeper Message
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function Jm({text:t}){if(!t)return null;const e=Vm(t);return i`<div class="markdown-content">${e}</div>`}function Vm(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],l=s.slice(r.length).trim(),u=[];for(a++;a<e.length&&!e[a].startsWith(r);)u.push(e[a]),a++;a++,n.push(i`<pre><code class=${l?`language-${l}`:""}>${u.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],l=s.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const f=e[a].replace("</think>","").trim();f&&r.push(f),a++}const u=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Cs(u)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(i`<blockquote>${Cs(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(i`<p>${Cs(o.join(`
`))}</p>`)}return n}function Cs(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const o=s[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(s[2]){const o=s[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(s[3]){const o=s[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else s[4]&&s[5]&&e.push(i`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const pn=_("posts"),hi=_([]),yi=_([]),hn=_(""),Va=_(!1),yn=_(!1),Hn=_(""),Qa=_(null),Lt=_(null),bi=_(!1),ne=_(null),ha=_(null);async function ms(){Va.value=!0,Hn.value="";try{const[t,e]=await Promise.all([qc(),jc()]);hi.value=t,yi.value=e,ne.value=!0,ha.value=Date.now()}catch(t){Hn.value=t instanceof Error?t.message:"Failed to load council data",ne.value=!1}finally{Va.value=!1}}Cd(ms);async function To(){const t=hn.value.trim();if(t){yn.value=!0;try{const e=await Fc(t);hn.value="",T(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await ms()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";T(n,"error")}finally{yn.value=!1}}}async function Qm(t){Qa.value=t,bi.value=!0,Lt.value=null;try{Lt.value=await Kc(t)}catch(e){Hn.value=e instanceof Error?e.message:"Failed to load debate status",Lt.value=null}finally{bi.value=!1}}const Xr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ya=_(null),bn=_([]),Ae=_(!1),ke=_(null),kn=_("");function Ym(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Xm=_(Ym()),xn=_(!1);async function Wi(t){ke.value=t,ya.value=null,bn.value=[],Ae.value=!0;try{const e=await cc(t);if(ke.value!==t)return;ya.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},bn.value=e.comments??[]}catch{ke.value===t&&(ya.value=null,bn.value=[])}finally{ke.value===t&&(Ae.value=!1)}}async function No(t){const e=kn.value.trim();if(e){xn.value=!0;try{await dc(t,Xm.value,e),kn.value="",T("Comment posted","success"),await Wi(t),Ft()}catch{T("Failed to post comment","error")}finally{xn.value=!1}}}function Zm(){const t=Ln.value;return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Xr.map(e=>i`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Ln.value=e.id,Ft()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${$e.value?"is-active":""}"
          onClick=${()=>{$e.value=!$e.value,Ft()}}
        >
          ${$e.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ft} disabled=${Dn.value}>
          ${Dn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function ki(){var e;const t=(e=de.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:i`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?i`<span class="feed-health-meta">Last sync: <${W} timestamp=${t.last_sync_at} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Zr({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function tv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Ro(t){return t.updated_at!==t.created_at}function xi(){var n;const t=((n=Xr.find(a=>a.id===Ln.value))==null?void 0:n.label)??Ln.value,e=Xe.value.length;return i`
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
        <strong>${$e.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${li.value?i`<${W} timestamp=${li.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function ev({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await er(t.id,n),Ft()}catch{T("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>xl(t.id)}>
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
              <${Zr} flair=${t.flair} />
              ${Ro(t)?i`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${W} timestamp=${t.created_at} /></span>
            ${Ro(t)?i`<span>Updated <${W} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${tv(t.content)}</div>
      </div>
    </div>
  `}function nv({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${W} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function av({postId:t}){return i`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${kn.value}
        onInput=${e=>{kn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&No(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${xn.value}
      />
      <button
        onClick=${()=>No(t)}
        disabled=${xn.value||kn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${xn.value?"...":"Post"}
      </button>
    </div>
  `}function sv({post:t}){ke.value!==t.id&&!Ae.value&&Wi(t.id);const e=async n=>{try{await er(t.id,n),Ft()}catch{T("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>ht("board")}>← Back to Board</button>
      <${R} title=${i`${t.title} <${Zr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Jm} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${W} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${R} title="Comments (${Ae.value?"...":bn.value.length})">
        ${Ae.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${nv} comments=${bn.value} />`}
        <${av} postId=${t.id} />
      <//>
    </div>
  `}function iv({debate:t}){const e=Qa.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Qm(t.id)}
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
  `}function ov({session:t}){return i`
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
  `}function tl(){return ne.value===null||ne.value&&!ha.value?null:i`
    <div class="feed-health-banner ${ne.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${ne.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${ha.value?i`<span class="feed-health-meta">Last sync: <${W} timestamp=${ha.value} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function rv(){const t=ne.value===!1;return i`
    <div>
      <${tl} />
      <${R} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${hn.value}
            onInput=${e=>{hn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&To()}}
            disabled=${yn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${To}
            disabled=${yn.value||hn.value.trim()===""}
          >
            ${yn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ms} disabled=${Va.value}>
            ${Va.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Hn.value?i`<div class="council-error">${Hn.value}</div>`:null}
      <//>

      <${R} title="Debates" class="section">
        <div class="council-list">
          ${hi.value.length===0?i`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:hi.value.map(e=>i`<${iv} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${R} title=${Qa.value?`Debate Detail (${Qa.value})`:"Debate Detail"} class="section">
        ${bi.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Lt.value?i`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Lt.value.status}</span>
                  <span>Total arguments: ${Lt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Lt.value.support_count}</span>
                  <span>Oppose: ${Lt.value.oppose_count}</span>
                  <span>Neutral: ${Lt.value.neutral_count}</span>
                </div>
                ${Lt.value.summary_text?i`<pre class="council-detail">${Lt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function lv(){const t=ne.value===!1;return i`
    <div>
      <${tl} />
      <${R} title="Voting Sessions" class="section">
        <div class="council-list">
          ${yi.value.length===0?i`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:yi.value.map(e=>i`<${ov} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function cv(){const t=pn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{pn.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{pn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{pn.value="voting"}}>Voting</button>
    </div>
  `}function dv(){var a,s;const t=Xe.value,e=Dn.value,n=((s=(a=de.value)==null?void 0:a.data_quality)==null?void 0:s.board_contract_ok)===!1;return i`
    <div>
      <${ki} />
      <${xi} />
      <${Zm} />
      ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":$e.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:i`<div class="board-post-list">
              ${t.map(o=>i`<${ev} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function uv(){var s,o;const t=Xe.value,e=nt.value.postId,n=((o=(s=de.value)==null?void 0:s.data_quality)==null?void 0:o.board_contract_ok)===!1,a=pn.value;if(st(()=>{(a==="debates"||a==="voting")&&ms()},[a]),e){const r=t.find(l=>l.id===e)??(ke.value===e?ya.value:null);return!r&&ke.value!==e&&!Ae.value&&Wi(e),r?i`
          <${ki} />
          <${xi} />
          <${sv} post=${r} />
        `:i`
          <div>
            <${ki} />
            <${xi} />
            <button class="back-btn" onClick=${()=>ht("board")}>← Back to Board</button>
            ${Ae.value?i`<div class="loading-indicator">Loading post...</div>`:i`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return i`
    <${cv} />
    ${a==="debates"?i`<${rv} />`:a==="voting"?i`<${lv} />`:i`<${dv} />`}
  `}const pv=40;function mv({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:s,className:o=""}){const r=Ho(null),[l,u]=is({start:0,end:30}),f=t.length>pv;if(st(()=>{if(!f)return;const h=r.current;if(!h)return;let b=!1;const w=()=>{const{scrollTop:D,clientHeight:L}=h,p=Math.max(0,Math.floor(D/e)-n),H=Math.min(t.length,Math.ceil((D+L)/e)+n);u(U=>U.start===p&&U.end===H?U:{start:p,end:H})};let N=!1;const P=()=>{N||b||(N=!0,requestAnimationFrame(()=>{b||w(),N=!1}))},M=new ResizeObserver(()=>{b||w()});return w(),h.addEventListener("scroll",P,{passive:!0}),M.observe(h),()=>{b=!0,h.removeEventListener("scroll",P),M.disconnect()}},[f,t.length,e,n]),!f)return i`
      <div class=${o}>
        ${t.map((h,b)=>a(h,b))}
      </div>
    `;const m=t.length*e,c=l.start*e,v=t.slice(l.start,l.end);return i`
    <div ref=${r} class=${o}>
      <div class="virtual-list-spacer" style=${{height:`${m}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${c}px)`}}
        >
          ${v.map((h,b)=>{const w=l.start+b;return i`<div key=${s(h)}>${a(h,w)}</div>`})}
        </div>
      </div>
    </div>
  `}function vv(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function fv(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function _v(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const el=120,gv=12,$v=16,hv=12,Si=_("all"),yv={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},bv={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function kv(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function xv(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:vv(t),actor:fv(t),content:_v(t),timestamp:new Date(t.timestamp).toISOString()}}function Sv(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Av(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function sa(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ai(t){return t.last_heartbeat??sa(t.last_turn_ago_s)??sa(t.last_proactive_ago_s)??sa(t.last_handoff_ago_s)??sa(t.last_compaction_ago_s)}function wv(t,e){const n=Ai(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Mt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const wi=Nt(()=>{const t=Rn.value.map(kv),e=Aa.value.map(xv),n=[...bt.value].sort((o,r)=>Mt(r.updated_at??r.created_at??0)-Mt(o.updated_at??o.created_at??0)).slice(0,gv).map(Sv).filter(o=>o!==null),a=[...Xe.value].sort((o,r)=>Mt(r.updated_at||r.created_at)-Mt(o.updated_at||o.created_at)).slice(0,$v).map(Av),s=[...Xt.value].sort((o,r)=>Mt(Ai(r)??0)-Mt(Ai(o)??0)).slice(0,hv).map(wv).filter(o=>o!==null);return[...t,...e,...n,...a,...s].sort((o,r)=>Mt(r.timestamp)-Mt(o.timestamp))}),Cv=Nt(()=>{const t=wi.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Tv=Nt(()=>{const t=Si.value;return(t==="all"?wi.value:wi.value.filter(n=>n.kind===t)).slice(0,el)}),Nv=Nt(()=>{const t=rs.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return Tt.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const s=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return s!==0?s:Mt(a.motion.lastActivityAt??0)-Mt(n.motion.lastActivityAt??0)})});function Rv(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function ln({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Lv({row:t}){return i`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Rv(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${bv[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Pv(){const t=Cv.value,e=Tv.value,n=e[0],a=Nv.value;return i`
    <div class="stats-grid">
      <${ln} label="Visible rows 표시 행" value=${e.length} />
      <${ln} label="Tracked messages 추적 메시지" value=${t.messages} color="#47b8ff" />
      <${ln} label="Keeper signals 키퍼 신호" value=${t.keepers} color="#4ade80" />
      <${ln} label="Board signals 보드 신호" value=${t.board} color="#fbbf24" />
      <${ln} label="SSE events SSE 이벤트" value=${Wn.value} color="#c084fc" />
    </div>

    <${R} title="Unified Activity 통합 활동" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>i`
            <button
              class="goal-filter-btn ${Si.value===s?"active":""}"
              onClick=${()=>{Si.value=s}}
            >
              ${yv[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ht.value?"":"pill-stale"}">
            ${Ht.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?i`Latest: <${W} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${el} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?i`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:i`<${mv}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${s=>s.id}
            renderItem=${s=>i`<${Lv} row=${s} />`}
            className="terminal-feed"
          />`}
    <//>

    <${R} title="Agent Motion 에이전트 동향" class="section">
      <div class="activity-motion-list">
        ${a.length===0?i`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:o})=>i`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${o.activeAssignedCount>0?`${o.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${o.lastActivityAt?i` · <${W} timestamp=${o.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${o.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function nl({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),i`
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
  `}const Ts=600*1e3,Dv=1200*1e3,Lo=.8;function te(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function De(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Ev(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Iv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Mv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Ov(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function zv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function qv(t){var u,f;const e=rs.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-te(n)):Number.POSITIVE_INFINITY,s=!!((u=t.current_task)!=null&&u.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>Dv?(o="quiet",r="bad",l=s?"Working without a fresh signal":"No fresh agent signal"):s?(o="working",r=a>Ts?"warn":"ok",l=a>Ts?"Execution looks quiet for too long":"Task and live signal aligned"):a>Ts?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((f=t.current_task)==null?void 0:f.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function jv(t){const e=pr.value.get(t.name)??"idle",n=mr.value.has(t.name),a=t.context_ratio??0;let s="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Lo)&&(s="warning",o="warn",r=a>=Lo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:o,focus:Ov(t),note:r}}function cn({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Fv({item:t}){const e=t.kind==="agent"?()=>Ke(t.agent.name):()=>La(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${W} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function Po({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ke(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${nl} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Dt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Ev(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${W} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${W} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Kv({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>La(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${nl} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Dt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Iv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${W} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${zv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Mv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Hv(){const t=[...Tt.value].map(qv).sort((m,c)=>{const v=De(c.tone)-De(m.tone);if(v!==0)return v;const h=c.activeTaskCount-m.activeTaskCount;return h!==0?h:te(c.lastSignalAt)-te(m.lastSignalAt)}),e=[...Xt.value].map(jv).sort((m,c)=>{const v=De(c.tone)-De(m.tone);if(v!==0)return v;const h=(c.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return h!==0?h:te(c.keeper.last_heartbeat)-te(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),s=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-te(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),u=e.filter(m=>m.tone!=="ok"),f=[...u.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,c)=>{const v=De(c.tone)-De(m.tone);return v!==0?v:te(c.timestamp)-te(m.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${cn} label="Agents online 온라인" value=${s} color="#4ade80" caption="활성 + 대기 에이전트" />
        <${cn} label="Working now 작업중" value=${o} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${cn} label="Fresh signals 최신 신호" value=${r} color="#22d3ee" caption="최근 2분 이내" />
        <${cn} label="Agent alerts 에이전트 경고" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="비활성 또는 오프라인" />
        <${cn} label="Keeper alerts 키퍼 경고" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="오래되거나 높은 부하" />
      </div>

      <${R} title="Attention Queue 주의 필요" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${f.length===0?i`<div class="empty-state">No agent or keeper alerts right now</div>`:f.map(m=>i`<${Fv} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${R} title="Active Agents 활성 에이전트" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active agents visible</div>`:n.map(m=>i`<${Po} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>

        <${R} title="Keeper Watch 키퍼 감시" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(m=>i`<${Kv} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

        <${R} title="Offline Agents 오프라인" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${a.length===0?i`<div class="empty-state">No offline agents right now</div>`:a.map(m=>i`<${Po} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ya=_("all"),Xa=_("all"),Ci=Nt(()=>{let t=Pn.value;return Ya.value!=="all"&&(t=t.filter(e=>e.horizon===Ya.value)),Xa.value!=="all"&&(t=t.filter(e=>e.status===Xa.value)),t}),Uv=Nt(()=>{const t={short:[],mid:[],long:[]};for(const e of Ci.value){const n=t[e.horizon];n&&n.push(e)}return t}),Bv=Nt(()=>{const t=Array.from(lr.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Wv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Gi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ba(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Gv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Do(t){return t.toFixed(4)}function Eo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Jv({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ba(t.horizon)}">
            ${Gi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Wv(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${W} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Dt} status=${t.status} />
        <div class="goal-updated">
          <${W} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Io({label:t,timestamp:e,source:n,note:a}){return i`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?i`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?i`<${W} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Ns({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return i`
    <${R} title="${Gi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>i`<${Jv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Vv(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ya.value===t?"active":""}"
            onClick=${()=>{Ya.value=t}}
          >
            ${t==="all"?"All":Gi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Xa.value===t?"active":""}"
            onClick=${()=>{Xa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Qv(){const t=Pn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${ba("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ba("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ba("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Yv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Dt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Do(t.baseline_metric)}</span>
          <span>Current ${Do(t.current_metric)}</span>
          <span class=${Eo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Eo(t)}
          </span>
          <span>Elapsed ${Gv(t.elapsed_seconds)}</span>
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
  `}function Rs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return i`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?i`<${W} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Xv(){const{todo:t,inProgress:e,done:n}=ur.value;return i`
    <${R} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>i`<${Rs} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>i`<${Rs} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>i`<${Rs} key=${a.id} task=${a} />`)}
          ${n.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Zv(){const t=Uv.value,e=Bv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,s=Pn.value.filter(l=>l.status==="active").length,o=si.value,r=o==="idle"?"No loop running":o==="error"?ii.value??"MDAL snapshot unavailable":"Current loop snapshot";return i`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ci.value.length}</div>
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

      <${R} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>/api/v1/mdal/loops</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${En} disabled=${Oe.value}>
              ${Oe.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ge} disabled=${ze.value}>
              ${ze.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{En(),Ge()}}
              disabled=${Oe.value||ze.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Io} label="Goals" timestamp=${cr.value} source="masc_goal_list" />
          <${Io}
            label="MDAL loops"
            timestamp=${dr.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${R} title="Goal Pipeline" class="section">
        <${Qv} />
        <${Vv} />
      <//>

      ${Oe.value&&Pn.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Ci.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
              <${Ns} horizon="short" items=${t.short??[]} />
              <${Ns} horizon="mid" items=${t.mid??[]} />
              <${Ns} horizon="long" items=${t.long??[]} />
            `}

      <${R} title="MDAL Loops" class="section">
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
                  ${e.map(l=>i`<${Yv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${Xv} />
    </div>
  `}const Ie=_(""),Ls=_("ability_check"),Ps=_("10"),Ds=_("12"),ia=_(""),oa=_("idle"),ee=_(""),ra=_("keeper-late"),Es=_("player"),Is=_(""),wt=_("idle"),Ms=_(null),la=_(""),Os=_(""),zs=_("player"),qs=_(""),js=_(""),Fs=_(""),Sn=_("20"),Ks=_("20"),Hs=_(""),ca=_("idle"),Ti=_(null),al=_("overview"),Us=_("all"),Bs=_("all"),Ws=_("all"),tf=12e4,vs=_(null),Mo=_(Date.now());function ef(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function nf(t,e){return e>0?Math.round(t/e*100):0}const af={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},sf={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function da(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function of(t){const e=t.trim().toLowerCase();return af[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function rf(t){const e=t.trim().toLowerCase();return sf[e]??"상황에 따라 선택되는 전술 액션입니다."}function oe(t){return typeof t=="object"&&t!==null}function $t(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Ot(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function Un(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const lf=new Set(["str","dex","con","int","wis","cha"]);function cf(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!oe(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,o])=>{const r=s.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function df(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(Sn.value.trim(),10);Number.isFinite(a)&&a>n&&(Sn.value=String(n))}function Ni(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function uf(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function pf(t){al.value=t}function sl(t){const e=vs.value;return e==null||e<=t}function mf(t){const e=vs.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Za(){vs.value=null}function il(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function vf(t,e){il(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(vs.value=Date.now()+tf,T("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ka(t){return sl(t)?(T("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ri(t,e,n){return il([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function ff({hp:t,max:e}){const n=nf(t,e),a=ef(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function _f({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function gf({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function ol({actor:t}){var u,f,m,c;const e=(u=t.archetype)==null?void 0:u.trim(),n=(f=t.persona)==null?void 0:f.trim(),a=(m=t.portrait)==null?void 0:m.trim(),s=(c=t.background)==null?void 0:c.trim(),o=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([v,h])=>Number.isFinite(h)).filter(([v])=>!lf.has(v.toLowerCase()));return i`
    <div class="trpg-actor">
      ${a?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${v=>{const h=v.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Dt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${gf} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${ff} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${_f} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${da(e)}</div>`:null}
      ${s?i`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([v,h])=>i`
                <span class="trpg-custom-stat-chip">${da(v)} ${h}</span>
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
                  <span class="trpg-annot-name">${da(v)}</span>
                  <span class="trpg-annot-desc">${of(v)}</span>
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
                  <span class="trpg-annot-name">${da(v)}</span>
                  <span class="trpg-annot-desc">${rf(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function $f({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function rl({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return i`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${uf(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ni(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${W} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function hf({events:t}){const e="__none__",n=Us.value,a=Bs.value,s=Ws.value,o=Array.from(new Set(t.map(Ni).map(c=>c.trim()).filter(c=>c!==""))).sort((c,v)=>c.localeCompare(v)),r=Array.from(new Set(t.map(c=>(c.type??"").trim()).filter(c=>c!==""))).sort((c,v)=>c.localeCompare(v)),l=t.some(c=>(c.type??"").trim()===""),u=Array.from(new Set(t.map(c=>(c.phase??"").trim()).filter(c=>c!==""))).sort((c,v)=>c.localeCompare(v)),f=t.some(c=>(c.phase??"").trim()===""),m=t.filter(c=>{if(n!=="all"&&Ni(c)!==n)return!1;const v=(c.type??"").trim(),h=(c.phase??"").trim();if(a===e){if(v!=="")return!1}else if(a!=="all"&&v!==a)return!1;if(s===e){if(h!=="")return!1}else if(s!=="all"&&h!==s)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${c=>{Us.value=c.target.value}}>
          <option value="all">all</option>
          ${o.map(c=>i`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${c=>{Bs.value=c.target.value}}>
          <option value="all">all</option>
          ${l?i`<option value=${e}>(none)</option>`:null}
          ${r.map(c=>i`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${c=>{Ws.value=c.target.value}}>
          <option value="all">all</option>
          ${f?i`<option value=${e}>(none)</option>`:null}
          ${u.map(c=>i`<option value=${c}>${c}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Us.value="all",Bs.value="all",Ws.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${rl} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function yf({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function ll({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function bf({state:t,nowMs:e}){var f;const n=Gt.value||((f=t.session)==null?void 0:f.room)||"",a=oa.value,s=t.party??[];if(!s.find(m=>m.id===Ie.value)&&s.length>0){const m=s[0];m&&(Ie.value=m.id)}const r=async()=>{var c,v;if(!n){T("Room ID가 비어 있습니다.","error");return}if(!ka(e))return;const m=((c=t.current_round)==null?void 0:c.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(Ri("라운드 실행",n,m)){oa.value="running";try{const h=await wc(n);Ti.value=h,oa.value="ok";const b=oe(h.summary)?h.summary:null,w=b?Un(b,"advanced",!1):!1,N=b?$t(b,"progress_reason",""):"";T(w?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${N?`: ${N}`:""}`,w?"success":"warning"),Kt()}catch(h){Ti.value=null,oa.value="error";const b=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";T(b,"error")}finally{Za()}}},l=async()=>{var c,v;if(!n||!ka(e))return;const m=((c=t.current_round)==null?void 0:c.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(Ri("턴 강제 진행",n,m))try{await Nc(n),T("턴을 다음 단계로 이동했습니다.","success"),Kt()}catch{T("턴 이동에 실패했습니다.","error")}finally{Za()}},u=async()=>{if(!n||!ka(e))return;const m=Ie.value.trim();if(!m){T("먼저 Actor를 선택하세요.","warning");return}const c=Number.parseInt(Ps.value,10),v=Number.parseInt(Ds.value,10);if(Number.isNaN(c)||Number.isNaN(v)){T("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(ia.value,10),b=ia.value.trim()===""||Number.isNaN(h)?void 0:h;try{await Tc({roomId:n,actorId:m,action:Ls.value.trim()||"ability_check",statValue:c,dc:v,rawD20:b}),T("주사위 판정을 기록했습니다.","success"),Kt()}catch{T("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{Gt.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ie.value}
            onChange=${m=>{Ie.value=m.target.value}}
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
              value=${Ls.value}
              onInput=${m=>{Ls.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ps.value}
              onInput=${m=>{Ps.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ds.value}
              onInput=${m=>{Ds.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ia.value}
              onInput=${m=>{ia.value=m.target.value}}
              onKeyDown=${m=>{m.key==="Enter"&&u()}}
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
  `}function kf({state:t}){var s;const e=Gt.value||((s=t.session)==null?void 0:s.room)||"",n=ca.value,a=async()=>{if(!e){T("Room ID가 비어 있습니다.","warning");return}const o=la.value.trim(),r=Os.value.trim();if(!r&&!o){T("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(Sn.value.trim(),10),u=Number.parseInt(Ks.value.trim(),10),f=Number.isFinite(u)?Math.max(1,u):20,m=Number.isFinite(l)?Math.max(0,Math.min(f,l)):f;let c={};try{c=cf(Hs.value)}catch(v){T(v instanceof Error?v.message:"능력치 JSON 오류","error");return}ca.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await Rc(e,{actor_id:o||void 0,name:r||void 0,role:zs.value,idempotencyKey:v,portrait:js.value.trim()||void 0,background:Fs.value.trim()||void 0,hp:m,max_hp:f,alive:m>0,stats:Object.keys(c).length>0?c:void 0}),b=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const w=qs.value.trim();w&&await Lc(e,b,w),Ie.value=b,ee.value=b,o||(la.value=""),ca.value="ok",T(`Actor 생성 완료: ${b}`,"success"),await Kt()}catch(v){ca.value="error",T(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Os.value}
            onInput=${o=>{Os.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${zs.value}
            onChange=${o=>{zs.value=o.target.value}}
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
            value=${qs.value}
            onInput=${o=>{qs.value=o.target.value}}
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
              value=${la.value}
              onInput=${o=>{la.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${js.value}
              onInput=${o=>{js.value=o.target.value}}
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
              value=${Sn.value}
              onInput=${o=>{Sn.value=o.target.value}}
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
              value=${Ks.value}
              onInput=${o=>{const r=o.target.value;Ks.value=r,df(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Fs.value}
              onInput=${o=>{Fs.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Hs.value}
              onInput=${o=>{Hs.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function xf({state:t,nowMs:e}){var v;const n=Gt.value||((v=t.session)==null?void 0:v.room)||"",a=t.join_gate,s=Ms.value,o=oe(s)?s:null,r=(t.party??[]).filter(h=>h.role!=="dm"),l=ee.value.trim(),u=r.some(h=>h.id===l),f=u?l:l?"__manual__":"",m=async()=>{const h=ee.value.trim(),b=ra.value.trim();if(!n||!h){T("Room/Actor가 필요합니다.","warning");return}wt.value="checking";try{const w=await Pc(n,h,b||void 0);Ms.value=w,wt.value="ok",T("참가 가능 여부를 갱신했습니다.","success")}catch(w){wt.value="error";const N=w instanceof Error?w.message:"참가 가능 여부 확인에 실패했습니다.";T(N,"error")}},c=async()=>{var P,M;const h=ee.value.trim(),b=ra.value.trim(),w=Is.value.trim();if(!n||!h||!b){T("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ka(e))return;const N=((P=t.current_round)==null?void 0:P.phase)??((M=t.session)==null?void 0:M.status)??"unknown";if(Ri("Mid-Join 승인 요청",n,N)){wt.value="requesting";try{const D=await Dc({room_id:n,actor_id:h,keeper_name:b,role:Es.value,...w?{name:w}:{}});Ms.value=D;const L=oe(D)?Un(D,"granted",!1):!1,p=oe(D)?$t(D,"reason_code",""):"";L?T("Mid-Join이 승인되었습니다.","success"):T(`Mid-Join이 거절되었습니다${p?`: ${p}`:""}`,"warning"),wt.value=L?"ok":"error",Kt()}catch(D){wt.value="error";const L=D instanceof Error?D.message:"Mid-Join 요청에 실패했습니다.";T(L,"error")}finally{Za()}}};return i`
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
            value=${f}
            onChange=${h=>{const b=h.target.value;if(b==="__manual__"){(u||!l)&&(ee.value="");return}ee.value=b}}
          >
            <option value="">Actor 선택</option>
            ${r.map(h=>i`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${f==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ee.value}
                onInput=${h=>{ee.value=h.target.value}}
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
            value=${ra.value}
            onInput=${h=>{ra.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Es.value}
            onChange=${h=>{Es.value=h.target.value}}
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
            value=${Is.value}
            onInput=${h=>{Is.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${wt.value==="checking"||wt.value==="requesting"}>
              ${wt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${c} disabled=${wt.value==="checking"||wt.value==="requesting"}>
              ${wt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Un(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ot(o,"effective_score",0)}/${Ot(o,"required_points",0)}</span>
            ${$t(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${$t(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function cl({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function dl({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function ul(){const t=Ti.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=oe(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(oe).slice(-8),o=t.canon_check,r=oe(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(p=>typeof p=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(p=>typeof p=="string").slice(0,3):[],f=n?Un(n,"advanced",!1):!1,m=n?$t(n,"progress_reason",""):"",c=n?$t(n,"progress_detail",""):"",v=n?Ot(n,"player_successes",0):0,h=n?Ot(n,"player_required_successes",0):0,b=n?Un(n,"dm_success",!1):!1,w=n?Ot(n,"timeouts",0):0,N=n?Ot(n,"unavailable",0):0,P=n?Ot(n,"reprompts",0):0,M=n?Ot(n,"npc_attacks",0):0,D=n?Ot(n,"keeper_timeout_sec",0):0,L=n?Ot(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${f?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${f?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${v}/${h}
          </span>
        </div>
        ${m?i`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${c?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${c}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${P}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${M}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${D||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${L}</div></div>
      </div>

      ${s.length>0?i`
          <div class="trpg-round-list">
            ${s.map(p=>{const H=$t(p,"status","unknown"),U=$t(p,"actor_id","-"),xt=$t(p,"role","-"),it=$t(p,"reason",""),ot=$t(p,"action_type",""),B=$t(p,"reply","");return i`
                <div class="trpg-round-item ${H.includes("fallback")||H.includes("timeout")?"failed":"active"}">
                  <span>${U} (${xt})</span>
                  <span style="margin-left:auto; font-size:11px;">${H}</span>
                  ${ot?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ot}</div>`:null}
                  ${it?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${it}</div>`:null}
                  ${B?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${B.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${$t(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(p=>i`<div>violation: ${p}</div>`)}
                </div>`:null}
            ${l.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${l.map(p=>i`<div>warning: ${p}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Sf({state:t,nowMs:e}){var r,l,u;const n=Gt.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((u=t.session)==null?void 0:u.status)??"unknown",s=sl(e),o=mf(e);return i`
    <${R} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?i`<button class="trpg-run-btn recommend" onClick=${()=>vf(n,a)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Za(),T("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Af({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>pf(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function wf({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${R} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${rl} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${R} title="맵" style="margin-top:16px;">
              <${$f} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${R} title="현재 라운드">
          <${dl} state=${t} />
        <//>

        <${R} title="기여도" style="margin-top:16px;">
          <${cl} state=${t} />
        <//>

        <${R} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>i`<${ol} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${ll} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Cf({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title=${`이벤트 타임라인 (${e.length})`}>
          <${hf} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${R} title="최근 라운드 결과">
          <${ul} />
        <//>

        <${R} title="현재 라운드" style="margin-top:16px;">
          <${dl} state=${t} />
        <//>
      </div>
    </div>
  `}function Tf({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${Sf} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${R} title="조작 패널">
            <${bf} state=${t} nowMs=${e} />
          <//>

          <${R} title="Actor Spawn" style="margin-top:16px;">
            <${kf} state=${t} />
          <//>

          <${R} title="Mid-Join Gate" style="margin-top:16px;">
            <${xf} state=${t} nowMs=${e} />
          <//>

          <${R} title="최근 라운드 결과" style="margin-top:16px;">
            <${ul} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${R} title="기여도" style="margin-top:0;">
            <${cl} state=${t} />
          <//>

          <${R} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>i`<${ol} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${ll} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Nf(){var l,u,f,m,c;const t=rr.value,e=ri.value;if(st(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{Mo.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Kt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,o=al.value,r=Mo.value;return i`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Gt.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((f=t.session)==null?void 0:f.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Kt()}>새로고침</button>
      </div>

      <${yf} outcome=${s} />

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

      <${Af} active=${o} />

      ${o==="overview"?i`<${wf} state=${t} />`:o==="timeline"?i`<${Cf} state=${t} />`:i`<${Tf} state=${t} nowMs=${r} />`}
    </div>
  `}const Ji="masc_dashboard_agent_name";function Rf(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Ji);return e??n??"dashboard"}const yt=_(Rf()),An=_(""),wn=_(""),ts=_(""),pl=_(null),es=_(null),Cn=_(!1),qe=_(!1),Bn=_(null),Tn=_(!1),Nn=_(!1),ns=_(!1),as=_(!1),Qe=_(!1);function ss(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function xa(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function ml(t){return!t||t.length===0?"none":t.join(", ")}function Lf(t){return t?t.enabled?t.quiet_active?`Quiet hours ${ss(t.quiet_start)}-${ss(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${xa(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${xa(t.interval_s)}.`:`Lodge ticks every ${xa(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function tn(){We();try{await re()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function Vi(t){const e=t.trim();yt.value=e,e&&localStorage.setItem(Ji,e)}function Pf(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Li(){if(Qe.value)return;const t=yt.value.trim();if(t){Tn.value=!0;try{const e=await Ic(t),n=Pf(e);n&&Vi(n),Bn.value=n??t,Qe.value=!0,await tn(),T(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";T(n,"error")}finally{Tn.value=!1}}}async function Oo(){if(!Qe.value)return;const t=Bn.value??yt.value.trim();if(t){Nn.value=!0;try{await ar(t),Bn.value=null,Qe.value=!1,await tn(),T(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";T(n,"error")}finally{Nn.value=!1}}}async function Df(){const t=Bn.value??yt.value.trim();if(t)try{await ar(t)}catch{}Bn.value=null,localStorage.removeItem(Ji),Vi("dashboard"),Qe.value=!1,await Li()}async function Ef(){const t=yt.value.trim();if(t){ns.value=!0;try{await Mc(t),await tn(),T("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";T(n,"error")}finally{ns.value=!1}}}async function zo(){const t=yt.value.trim(),e=An.value.trim();if(!(!t||!e)){Cn.value=!0;try{await nr(t,e),An.value="",await tn(),T("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";T(a,"error")}finally{Cn.value=!1}}}async function If(){const t=wn.value.trim(),e=ts.value.trim()||"Created from dashboard";if(t){qe.value=!0;try{await Ec(t,e,1),wn.value="",ts.value="",await tn(),T("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";T(a,"error")}finally{qe.value=!1}}}async function qo(){const t=yt.value.trim()||"dashboard";as.value=!0,es.value=null;try{const e=await Jn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=Ii(e.result);pl.value=n,await tn(),n!=null&&n.skipped_reason?T(n.skipped_reason,"warning"):T(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";es.value=n,T(n,"error")}finally{as.value=!1}}function Mf({runtime:t}){var s,o;const e=pl.value??(t==null?void 0:t.last_tick_result)??null;if(es.value)return i`<div class="control-result-box is-error">${es.value}</div>`;if(!e)return i`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?i`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${ml(e.acted_names)}</div>
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
  `}function Of(t){return t.find(n=>n.name===mn.value)??t[0]??null}function zf(){var a,s;const t=Xt.value,e=((a=de.value)==null?void 0:a.lodge)??null,n=Of(t);return st(()=>(Li(),()=>{Oo()}),[]),st(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!mn.value&&o){pa(o);return}mn.value&&!t.some(l=>l.name===mn.value)&&pa(o)},[t.map(o=>o.name).join("|")]),i`
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
          value=${yt.value}
          onInput=${o=>Vi(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Li()}}
            disabled=${Tn.value||yt.value.trim()===""}
          >
            ${Tn.value?"Joining...":Qe.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Oo()}}
            disabled=${Nn.value||yt.value.trim()===""}
          >
            ${Nn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Df()}}
            disabled=${Tn.value||Nn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ef()}}
            disabled=${ns.value||yt.value.trim()===""}
          >
            ${ns.value?"Pinging...":"Heartbeat"}
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
            value=${An.value}
            onInput=${o=>{An.value=o.target.value}}
            onKeyDown=${o=>{o.key==="Enter"&&zo()}}
            disabled=${Cn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{zo()}}
            disabled=${Cn.value||An.value.trim()===""||yt.value.trim()===""}
          >
            ${Cn.value?"Sending...":"Send"}
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
          onInput=${o=>{pa(o.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?i`<option value="">No keepers available</option>`:t.map(o=>i`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${xr} keeper=${n} />
        <${Ar}
          actor=${yt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{qo()}}
        />
        <${Sr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${Lf(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${xa(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${ss(e==null?void 0:e.quiet_start)}-${ss(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${ml((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?i`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{qo()}}
            disabled=${as.value}
          >
            ${as.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${Mf} runtime=${e} />
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
          value=${wn.value}
          onInput=${o=>{wn.value=o.target.value}}
          disabled=${qe.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${ts.value}
          onInput=${o=>{ts.value=o.target.value}}
          disabled=${qe.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{If()}}
          disabled=${qe.value||wn.value.trim()===""}
        >
          ${qe.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const jo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],Pi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],Fo="masc_dashboard_quick_actions_open";function qf(){const t=Ht.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Wn.value} events</span>
    </div>
  `}function jf({currentTab:t,currentSectionLabel:e}){const n=Ht.value;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${Tt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${Xt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${bt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Wn.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{re(),t==="command"&&(Se(),ae(),Ct.value==="swarm"&&Wt()),t==="ops"&&(we(),ce()),t==="board"&&Ft(),t==="trpg"&&Kt(),t==="goals"&&(En(),Ge())}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ht("ops")}>
          Open Ops
        </button>
      </div>
    </section>
  `}function Ff(){const t=nt.value.tab,e=Pi.find(o=>o.id===t),n=jo.find(o=>o.id===(e==null?void 0:e.group)),[a,s]=is(()=>{const o=localStorage.getItem(Fo);return o!=="0"});return st(()=>{localStorage.setItem(Fo,a?"1":"0")},[a]),i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${jo.map(o=>i`
          <div class="rail-nav-group" key=${o.id}>
            <div class="rail-group-label">${o.label}</div>
            <div class="rail-group-copy">${o.description}</div>
            <div class="rail-tab-list">
              ${Pi.filter(r=>r.group===o.id).map(r=>i`
                  <button
                    class="rail-tab-btn ${t===r.id?"active":""}"
                    onClick=${()=>ht(r.id)}
                  >
                    <span class="rail-tab-icon">${r.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${r.label}</strong>
                      <span>${r.description}</span>
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

      <${jf} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${a?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>s(o=>!o)}>
          <span>${a?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${a?i`<div class="rail-fold-body"><${zf} /></div>`:i`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function Kf(){switch(nt.value.tab){case"command":return i`<${km} />`;case"overview":return i`<${ho} />`;case"ops":return i`<${Gm} />`;case"board":return i`<${uv} />`;case"agents":return i`<${Hv} />`;case"goals":return i`<${Zv} />`;case"trpg":return i`<${Nf} />`;default:return i`<${ho} />`}}function Hf(){st(()=>{Sl(),Vo(),re();const n=Rd();return Ld(),()=>{Pl(),n(),Pd()}},[]),st(()=>{const n=setInterval(()=>{const a=nt.value.tab;a==="command"?(Se(),ae(),Ct.value==="swarm"&&Wt()):a==="ops"?(we(),ce()):a==="board"?Ft():a==="trpg"?Kt():a==="goals"&&(En(),Ge())},15e3);return()=>{clearInterval(n)}},[]),st(()=>{const n=nt.value.tab;n==="command"&&(Se(),ae(),Ct.value==="swarm"&&Wt()),n==="ops"&&(we(),ce()),n==="board"&&Ft(),n==="trpg"&&Kt(),n==="goals"&&(En(),Ge())},[nt.value.tab]);const t=nt.value.tab,e=Pi.find(n=>n.id===t);return i`
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
            class="activity-panel-toggle ${Je.value?"active":""}"
            onClick=${du}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${qf} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Ff} />
        <main class="dashboard-main">
          ${oi.value&&!Ht.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Kf} />`}
        </main>
      </div>

      ${Je.value?i`
        <div class="activity-panel-backdrop" onClick=${vo} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${vo}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${Pv} />
          </div>
        </aside>
      `:null}

      <${lu} />
      <${Fd} />
      <${Md} />
    </div>
  `}const Ko=document.getElementById("app");Ko&&$l(i`<${Hf} />`,Ko);export{ku as _};
