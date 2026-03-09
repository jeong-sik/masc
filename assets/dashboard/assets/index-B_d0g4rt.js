var Zr=Object.defineProperty;var tl=(t,e,n)=>e in t?Zr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Se=(t,e,n)=>tl(t,typeof e!="symbol"?e+"":e,n);import{e as el,_ as nl,c as g,b as Tt,y as ct,d as Qa,A as Po,G as al}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const o of s)if(o.type==="childList")for(const r of o.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const o={};return s.integrity&&(o.integrity=s.integrity),s.referrerPolicy&&(o.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?o.credentials="include":s.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function a(s){if(s.ep)return;s.ep=!0;const o=n(s);fetch(s.href,o)}})();var i=el.bind(nl);const sl=["command","overview","board","goals","agents","ops","trpg"],Do={tab:"overview",params:{},postId:null},il={journal:"overview",mdal:"goals",tasks:"goals",execution:"overview",council:"board",activity:"overview"};function Ki(t){return!!t&&sl.includes(t)}function Hi(t){if(t)return il[t]??t}function ea(t){try{return decodeURIComponent(t)}catch{return t}}function zs(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function ol(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Mo(t,e){if(t[0]==="chains"){const r={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(r.operation=ea(t[2])),{tab:"command",params:r,postId:null}}const n=Hi(t[0]),a=Hi(e.tab),s=Ki(n)?n:Ki(a)?a:"overview";let o=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?o=ea(t[2]):t[0]==="post"&&t[1]&&(o=ea(t[1]))),{tab:s,params:e,postId:o}}function ma(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Do;const n=ea(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const l=n.indexOf("?");l>=0&&(a=n.slice(0,l),s=n.slice(l+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const o=zs(s),r=ol(a);return Mo(r,o)}function rl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Do,params:zs(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=zs(e.replace(/^\?/,""));return Mo(a,s)}function Eo(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const st=g(ma(window.location.hash));window.addEventListener("hashchange",()=>{st.value=ma(window.location.hash)});function wt(t,e){const n={tab:t,params:e??{},postId:null};window.location.hash=Eo(n)}function ll(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function cl(){if(window.location.hash&&window.location.hash!=="#"){st.value=ma(window.location.hash);return}const t=rl(window.location.pathname,window.location.search);if(t){st.value=t;const e=Eo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",st.value=ma(window.location.hash)}const Ui="masc_dashboard_sse_session_id",dl=1e3,ul=15e3,Ft=g(!1),In=g(0),Io=g(null),va=g([]);function pl(){let t=sessionStorage.getItem(Ui);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Ui,t)),t}const ml=200;function vl(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};va.value=[s,...va.value].slice(0,ml)}function js(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Bi(t,e){const n=js(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Nt(t,e,n,a,s={}){vl(t,e,n,{eventType:a,...s})}let Ot=null,Ee=null,qs=0;function Oo(){Ee&&(clearTimeout(Ee),Ee=null)}function fl(){if(Ee)return;qs++;const t=Math.min(qs,5),e=Math.min(ul,dl*Math.pow(2,t));Ee=setTimeout(()=>{Ee=null,zo()},e)}function zo(){Oo(),Ot&&(Ot.close(),Ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",pl());const s=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(s);Ot=o,o.onopen=()=>{Ot===o&&(qs=0,Ft.value=!0)},o.onerror=()=>{Ot===o&&(Ft.value=!1,o.close(),Ot=null,fl())},o.onmessage=r=>{try{const l=JSON.parse(r.data);In.value++,Io.value=l,_l(l)}catch{}}}function _l(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Nt(n,"Joined","system","agent_joined");break;case"agent_left":Nt(n,"Left","system","agent_left");break;case"broadcast":Nt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Nt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Nt(n,Bi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:js(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Nt(n,Bi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:js(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Nt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Nt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Nt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Nt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Nt(n,e,"system","unknown")}}function gl(){Oo(),Ot&&(Ot.close(),Ot=null),Ft.value=!1}function jo(){return new URLSearchParams(window.location.search)}function qo(){const t=jo(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Fo(){return{...qo(),"Content-Type":"application/json"}}const $l=15e3,Si=3e4,hl=6e4,Wi=new Set([408,425,429,500,502,503,504]);class On extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,o=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Se(this,"method");Se(this,"path");Se(this,"status");Se(this,"statusText");Se(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function Ai(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new On({method:r,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(s)}}function yl(){var e,n;const t=jo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function tt(t){const e=await Ai(t,{headers:qo()},$l);if(!e.ok)throw new On({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function bl(t){return new Promise(e=>setTimeout(e,t))}function kl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function xl(t){if(t instanceof On)return t.timeout||typeof t.status=="number"&&Wi.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=kl(t.message);return e!==null&&Wi.has(e)}async function We(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!xl(s)||a>=n)throw s;const o=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${o}ms`,s),await bl(o),a+=1}}async function Kt(t,e,n,a=Si){const s=await Ai(t,{method:"POST",headers:{...Fo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new On({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function Sl(t,e,n,a=Si){const s=await Ai(t,{method:"POST",headers:{...Fo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new On({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function Al(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function wl(t){var e,n,a,s,o,r,l;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(p)}return((l=(r=(o=t.result)==null?void 0:o.content)==null?void 0:r[0])==null?void 0:l.text)??""}async function bt(t,e){const n=await Sl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},hl),a=Al(n);return wl(a)}function Cl(t="compact"){return tt(`/api/v1/dashboard?mode=${t}`)}function Tl(){return tt("/api/v1/agents?limit=100")}function Nl(t){const e=new URLSearchParams({limit:"200"});return e.set("include_done","true"),e.set("include_cancelled","true"),tt(`/api/v1/tasks?${e}`)}function Rl(t){const e=new URLSearchParams({limit:"50"});return t!=null&&t>0&&e.set("since_seq",String(t)),tt(`/api/v1/messages?${e}`)}function Ll(t={}){return We("fetchMdalLoops",async()=>{const e=new URLSearchParams;t.limit!=null&&e.set("limit",String(t.limit)),t.historyLimit!=null&&e.set("history_limit",String(t.historyLimit)),t.status&&e.set("status",t.status);const n=e.toString();return tt(`/api/v1/mdal/loops${n?`?${n}`:""}`)})}function Pl(){return tt("/api/v1/operator")}function Dl(){return tt("/api/v1/command-plane")}function Ml(){return tt("/api/v1/command-plane/summary")}function El(){return tt("/api/v1/chains/summary")}function Il(t){return tt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Ol(){return tt("/api/v1/command-plane/help")}function zl(t){const e=new URLSearchParams;t&&e.set("run_id",t);const n=e.toString();return tt(`/api/v1/command-plane/swarm${n?`?${n}`:""}`)}function jl(t,e){return Kt(t,e)}function ql(t){switch(t.action_type){case"keeper_msg":case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return Si}}function zn(t){return Kt("/api/v1/operator/action",t,void 0,ql(t))}function Fl(t,e){return Kt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const Kl=new Set(["lodge-system","team-session"]);function Fe(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Hl(t){return Kl.has(t.trim().toLowerCase())}function Ul(t){return t.filter(e=>!Hl(e.author))}function Bl(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Ko(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const s=F(t.score,0),o=F(t.votes_up,0),r=F(t.votes_down,0),l=F(t.votes,s||o-r),p=F(t.comment_count,F(t.reply_count,0)),f=(()=>{const y=t.flair;if(typeof y=="string"&&y.trim())return y.trim();if(O(y)){const T=h(y.name,"").trim();if(T)return T}return h(t.flair_name,"").trim()||void 0})(),m=h(t.created_at_iso,"").trim()||Fe(t.created_at),d=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Fe(t.updated_at):m),c=h(t.title,"").trim()||Bl(a);return{id:e,author:n,title:c,content:a,tags:[],votes:l,vote_balance:s,comment_count:p,created_at:m,updated_at:d,flair:f,hearth_count:F(t.hearth_count,0)}}function Wl(t){if(!O(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:Fe(t.created_at)}}async function Gl(t,e){return We("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await tt(`/api/v1/board${a?`?${a}`:""}`),o=Array.isArray(s.posts)?s.posts.map(Ko).filter(l=>l!==null):[];return{posts:e!=null&&e.excludeSystem?Ul(o):o}})}async function Jl(t){return We("fetchBoardPost",async()=>{const e=await tt(`/api/v1/board/${t}?format=flat`),n=O(e.post)?e.post:e,a=Ko(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},o=(Array.isArray(e.comments)?e.comments:[]).map(Wl).filter(r=>r!==null);return{...a,comments:o}})}function Ho(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:yl()})}function Vl(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Ql(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function dt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Gi(t){const e=Ql(dt(t.outcome,t.result,t.result_code));if(!e)return;const n=dt(t.reason,t.reason_code,t.description,t.detail),a=dt(t.summary,t.summary_ko,t.summary_en,t.note),s=dt(t.details,t.details_text,t.text,t.note),o=dt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=dt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),l=dt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const d=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof d=="string"?[d]:Array.isArray(d)?d.map(v=>{if(typeof v=="string")return v.trim();if(O(v)){const c=h(v.summary,"").trim();if(c)return c;const y=h(v.text,"").trim();if(y)return y;const x=h(v.type,"").trim();return x||h(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),f=(()=>{const d=F(t.turn,Number.NaN);if(Number.isFinite(d))return d;const v=F(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const c=F(t.current_turn,Number.NaN);if(Number.isFinite(c))return c;const y=F(t.round,Number.NaN);return Number.isFinite(y)?y:void 0})(),m=dt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:o||void 0,winner_actor_id:r||void 0,evidence:p.length>0?p:void 0,raw_reason:l||void 0,turn:f,phase:m||void 0}}function Yl(t,e){const n=O(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>O(r)?h(r.type,"")==="session.outcome":!1),o=O(n.session_outcome)?n.session_outcome:{};if(O(o)&&Object.keys(o).length>0){const r=Gi(o);if(r)return r}if(O(s))return Gi(O(s.payload)?s.payload:{})}function O(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function F(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Xl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Fs(t,e=!1){return typeof t=="boolean"?t:e}function Xe(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(O(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),s=h(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Zl(t){const e={};if(!O(t)&&!Array.isArray(t))return e;if(O(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),o=h(a,"").trim();!s||!o||(e[s]=o)}),e;for(const n of t){if(!O(n))continue;const a=dt(n.to,n.target,n.actor_id,n.name,n.id),s=dt(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function tc(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function St(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return a}const ec=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function nc(t){const e=O(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const o=a.trim();o&&(ec.has(o.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[o]=s))}),n}function ac(t,e){if(t!=="dice.rolled")return;const n=F(e.raw_d20,0),a=F(e.total,0),s=F(e.bonus,0),o=h(e.action,"roll"),r=F(e.dc,0);return{notation:r>0?`${o} (DC ${r})`:o,rolls:n>0?[n]:[],total:a,modifier:s}}function sc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ic(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function oc(t,e,n,a){const s=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const o=h(a.proposed_action,h(a.reply,""));return o?`${s||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=h(a.reply,h(a.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const o=h(a.action,"roll"),r=F(a.total,0),l=F(a.dc,0),p=h(a.label,""),f=s||"actor",m=l>0?` vs DC ${l}`:"",d=p?` (${p})`:"";return`${f} ${o}: ${r}${m}${d}`}case"turn.started":return`Turn ${F(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,O(a.actor)?h(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${F(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${F(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const o=O(a.entity_refs)?a.entity_refs:{},r=h(o.requested_tier,""),l=h(o.effective_tier,""),p=Fs(o.guardrail_applied,!1),f=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!l)return f;const m=r&&l?`${r}->${l}`:l||r;return`${f} [${m}${p?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),l=h(a.contract_id,"n/a");return`Canon ${r}: ${l}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const o=sc(a);return o?`${t}: ${o}`:t}}}function rc(t,e){const n=O(t)?t:{},a=h(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=h(n.actor_name,"").trim()||e[s]||h(O(n.payload)?n.payload.actor_name:"",""),r=O(n.payload)?n.payload:{},l=h(n.ts,h(n.timestamp,new Date().toISOString())),p=h(n.phase,h(r.phase,"")),f=h(n.category,"");return{type:a,actor:o||s||h(r.actor_name,""),actor_id:s||h(r.actor_id,""),actor_name:o,seq:n.seq,room_id:h(n.room_id,""),phase:p||void 0,category:f||ic(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:oc(a,s,o,r),dice_roll:ac(a,r),timestamp:l}}function lc(t,e,n){var nt,at;const a=h(t.room_id,"")||n||"default",s=O(t.state)?t.state:{},o=O(s.party)?s.party:{},r=O(s.actor_control)?s.actor_control:{},l=O(s.join_gate)?s.join_gate:{},p=O(s.contribution_ledger)?s.contribution_ledger:{},f=Object.entries(o).map(([U,I])=>{const S=O(I)?I:{},Dt=St(S,"max_hp",void 0,10),Vt=St(S,"hp",void 0,Dt),oe=St(S,"max_mp",void 0,0),re=St(S,"mp",void 0,0),E=St(S,"level",void 0,1),Mt=St(S,"xp",void 0,0),le=Fs(S.alive,Vt>0),Qe=r[U],Ye=typeof Qe=="string"?Qe:void 0,Kn=tc(S.role,U,Ye),_=Xl(S.generation),D=dt(S.joined_at,S.joinedAt,S.started_at,S.startedAt),K=dt(S.claimed_at,S.claimedAt,S.assigned_at,S.assignedAt,S.assigned_time),it=dt(S.last_seen,S.lastSeen,S.last_seen_at,S.lastSeenAt,S.last_active,S.lastActive),q=dt(S.scene,S.current_scene,S.currentScene,S.world_scene,S.scene_name,S.sceneName),ft=dt(S.location,S.current_location,S.currentLocation,S.position,S.zone,S.area);return{id:U,name:h(S.name,U),role:Kn,keeper:Ye,archetype:h(S.archetype,""),persona:h(S.persona,""),portrait:h(S.portrait,"")||void 0,background:h(S.background,"")||void 0,traits:Xe(S.traits),skills:Xe(S.skills),stats_raw:nc(S),status:le?"active":"dead",generation:_,joined_at:D||void 0,claimed_at:K||void 0,last_seen:it||void 0,scene:q||void 0,location:ft||void 0,inventory:Xe(S.inventory),notes:Xe(S.notes),relationships:Zl(S.relationships),stats:{hp:Vt,max_hp:Dt,mp:re,max_mp:oe,level:E,xp:Mt,strength:St(S,"strength","str",10),dexterity:St(S,"dexterity","dex",10),constitution:St(S,"constitution","con",10),intelligence:St(S,"intelligence","int",10),wisdom:St(S,"wisdom","wis",10),charisma:St(S,"charisma","cha",10)}}}),m=f.filter(U=>U.status!=="dead"),d=Yl(t,e),v={phase_open:Fs(l.phase_open,!0),min_points:F(l.min_points,3),window:h(l.window,"round_boundary_only"),last_opened_turn:typeof l.last_opened_turn=="number"?l.last_opened_turn:null,last_closed_turn:typeof l.last_closed_turn=="number"?l.last_closed_turn:null},c=Object.entries(p).map(([U,I])=>{const S=O(I)?I:{};return{actor_id:U,score:F(S.score,0),last_reason:h(S.last_reason,"")||null,reasons:Xe(S.reasons)}}),y=f.reduce((U,I)=>(U[I.id]=I.name,U),{}),x=e.map(U=>rc(U,y)),T=F(s.turn,1),L=h(s.phase,"round"),z=h(s.map,""),P=O(s.world)?s.world:{},N=z||h(P.ascii_map,h(P.map,"")),R=x.filter((U,I)=>{const S=e[I];if(!O(S))return!1;const Dt=O(S.payload)?S.payload:{};return F(Dt.turn,-1)===T}),G=(R.length>0?R:x).slice(-12),H=h(s.status,"active");return{session:{id:a,room:a,status:H==="ended"?"ended":H==="paused"?"paused":"active",round:T,actors:m,created_at:((nt=x[0])==null?void 0:nt.timestamp)??new Date().toISOString()},current_round:{round_number:T,phase:L,events:G,timestamp:((at=x[x.length-1])==null?void 0:at.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:v,contribution_ledger:c,outcome:d,party:m,story_log:x,history:[]}}async function cc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await tt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function dc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([tt(`/api/v1/trpg/state${e}`),cc(t)]);return lc(n,a,t)}function uc(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function pc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function mc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function vc(t,e){const n=pc();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function fc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Kt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function _c(t,e,n){return Kt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function gc(t,e,n){const a=await bt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function $c(t){const e=await bt("trpg.mid_join.request",t);return JSON.parse(e)}async function Uo(t,e){await bt("masc_broadcast",{agent_name:t,message:e})}async function hc(t,e,n=1){await bt("masc_add_task",{title:t,description:e,priority:n})}async function yc(t){return bt("masc_join",{agent_name:t})}async function Bo(t){await bt("masc_leave",{agent_name:t})}async function bc(t){await bt("masc_heartbeat",{agent_name:t})}async function kc(t=40){return(await bt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function xc(t,e=20){return bt("masc_task_history",{task_id:t,limit:e})}async function Sc(){return We("fetchDebates",async()=>{const t=await tt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:h(e.status,"open"),argument_count:F(e.argument_count,0),created_at:Fe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Ac(){return We("fetchCouncilSessions",async()=>{const t=await tt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!O(e))return null;const n=h(e.id,"").trim(),a=h(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:h(e.initiator,"system"),votes:F(e.votes,0),quorum:F(e.quorum,0),state:h(e.state,"open"),created_at:Fe(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function wc(t){const e=await bt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Cc(t){return We("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await tt(`/api/v1/council/debates/${e}/summary`);if(!O(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:F(n.support_count,0),oppose_count:F(n.oppose_count,0),neutral_count:F(n.neutral_count,0),total_arguments:F(n.total_arguments,0),created_at:Fe(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function Tc(t,e,n){return bt("masc_keeper_msg",{name:t,message:e})}async function Nc(){try{const t=await bt("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const ln=g(""),Bt=g({}),pt=g({}),Ks=g({}),Hs=g({}),Us=g({}),Bs=g({}),Wt=g({});function lt(t,e,n){t.value={...t.value,[e]:n}}function Gt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function W(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function Lt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Le(t){return typeof t=="boolean"?t:void 0}function Ws(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Gs(t){return Array.isArray(t)?t.map(e=>W(e)).filter(e=>!!e):[]}function Rc(t){var n;const e=(n=W(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Lc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function os(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Gt(a))continue;const s=W(a.name);if(!s)continue;const o=W(a[e]);e==="summary"?n.push({name:s,summary:o}):n.push({name:s,reason:o})}return n}function Pc(t){if(!Gt(t))return null;const e=W(t.name);return e?{name:e,trigger:W(t.trigger),outcome:W(t.outcome),summary:W(t.summary),reason:W(t.reason)}:null}function Dc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Mc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Wo(t,e,n){return W(t)??Mc(e,n)}function Go(t,e){return typeof t=="boolean"?t:e==="recover"}function fa(t){if(!Gt(t))return null;const e=W(t.health_state),n=W(t.next_action_path),a=W(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:W(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Ws(t.last_reply_at),last_reply_preview:W(t.last_reply_preview)??null,last_error:W(t.last_error)??null,next_eligible_at_s:Lt(t.next_eligible_at_s)??null,recoverable:Go(t.recoverable,n),summary:Wo(t.summary,e,W(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function wi(t){return Gt(t)?{hour:Lt(t.hour),checked:Lt(t.checked)??0,acted:Lt(t.acted)??0,acted_names:Gs(t.acted_names),activity_report:W(t.activity_report),quiet_hours_overridden:Le(t.quiet_hours_overridden),skipped_reason:W(t.skipped_reason),acted_rows:os(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:os(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:os(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Pc).filter(e=>e!==null):[]}:null}function Ec(t){return Gt(t)?{enabled:Le(t.enabled)??!1,interval_s:Lt(t.interval_s)??0,quiet_start:Lt(t.quiet_start),quiet_end:Lt(t.quiet_end),quiet_active:Le(t.quiet_active),use_planner:Le(t.use_planner),delegate_llm:Le(t.delegate_llm),agent_count:Lt(t.agent_count),agents:Gs(t.agents),last_tick_ago_s:Lt(t.last_tick_ago_s)??null,last_tick_ago:W(t.last_tick_ago),total_ticks:Lt(t.total_ticks),total_checkins:Lt(t.total_checkins),last_skip_reason:W(t.last_skip_reason)??null,last_tick_result:wi(t.last_tick_result),active_self_heartbeats:Gs(t.active_self_heartbeats)}:null}function Ic(t){return Gt(t)?{status:t.status,diagnostic:fa(t.diagnostic)}:null}function Oc(t){return Gt(t)?{recovered:Le(t.recovered)??!1,skipped_reason:W(t.skipped_reason)??null,before:fa(t.before),after:fa(t.after),down:t.down,up:t.up}:null}function zc(t,e){var z,P;if(!(t!=null&&t.name))return null;const n=W((z=t.agent)==null?void 0:z.status)??W(t.status)??"unknown",a=W((P=t.agent)==null?void 0:P.error)??null,s=t.presence_keepalive??!0,o=t.keepalive_running??!1,r=t.turn_count??0,l=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,f=t.proactive_cooldown_sec??0,m=t.last_proactive_ago_s??null,d=p&&m!=null?Math.max(0,f-m):null,v=r<=0||l==null?"never":l>900?"stale":"fresh",c=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,y=a??(s&&!o?"keeper keepalive is not running":null),x=n==="offline"||n==="inactive"?"offline":y?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",T=y?Dc(y):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":s&&!o?"disabled":r<=0?"never_started":d!=null&&d>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",L=x==="offline"||x==="degraded"||x==="stale"?"recover":T==="quiet_hours"?"manual_lodge_poke":T==="unknown"?"probe":"direct_message";return{health_state:x,quiet_reason:T,next_action_path:L,last_reply_status:v,last_reply_at:c,last_reply_preview:null,last_error:y,next_eligible_at_s:d!=null&&d>0?d:null,recoverable:Go(void 0,L),summary:Wo(void 0,x,T),keepalive_running:o}}function jc(t,e){if(!Gt(t))return null;const n=Rc(t.role),a=W(t.content)??W(t.preview);if(!a)return null;const s=Ws(t.ts_unix)??Ws(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:Lc(n),text:a,timestamp:s,delivery:"history"}}function qc(t,e,n){const a=Gt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((o,r)=>jc(o,r)).filter(o=>o!==null):[];return{name:t,diagnostic:fa(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Ji(t,e){const n=pt.value[t]??[];pt.value={...pt.value,[t]:[...n,e].slice(-50)}}function Fc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Kc(t,e){const a=(pt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(o=>Fc(s,o)));pt.value={...pt.value,[t]:[...e,...a].slice(-50)}}function Ya(t,e){Bt.value={...Bt.value,[t]:e},Kc(t,e.history)}function Vi(t,e){const n=Bt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ya(t,{...n,diagnostic:{...a,...e}})}async function Ci(){Ke();try{await ne()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function na(t){ln.value=t.trim()}async function Jo(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Bt.value[n])return Bt.value[n];lt(Ks,n,!0),lt(Wt,n,null);try{const a=await bt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const o=qc(n,a,s);return Ya(n,o),o}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return lt(Wt,n,s),null}finally{lt(Ks,n,!1)}}async function Hc(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;Ji(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),lt(Hs,n,!0),lt(Wt,n,null);try{const o=await Tc(n,a);pt.value={...pt.value,[n]:(pt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},Ji(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Vi(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Ci()}catch(o){const r=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw pt.value={...pt.value,[n]:(pt.value[n]??[]).map(l=>l.id===s?{...l,delivery:"error",error:r}:l)},Vi(n,{last_reply_status:"error",last_error:r}),lt(Wt,n,r),o}finally{lt(Hs,n,!1)}}async function Uc(t,e){const n=t.trim();if(!n)return null;lt(Us,n,!0),lt(Wt,n,null);try{const a=await zn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Ic(a.result),o=(s==null?void 0:s.diagnostic)??null;if(o){const r=Bt.value[n];Ya(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??pt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Ci(),o}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw lt(Wt,n,s),a}finally{lt(Us,n,!1)}}async function Bc(t,e){const n=t.trim();if(!n)return null;lt(Bs,n,!0),lt(Wt,n,null);try{const a=await zn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Oc(a.result),o=(s==null?void 0:s.after)??null;if(o){const r=Bt.value[n];Ya(n,{name:n,diagnostic:o,history:(r==null?void 0:r.history)??pt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await Ci(),o}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw lt(Wt,n,s),a}finally{lt(Bs,n,!1)}}function ce(t){return(t??"").trim().toLowerCase()}function _t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function aa(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Hn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ze(t){return t.last_heartbeat??Hn(t.last_turn_ago_s)??Hn(t.last_proactive_ago_s)??Hn(t.last_handoff_ago_s)??Hn(t.last_compaction_ago_s)}function Wc(t){const e=t.title.trim();return e||aa(t.content)}function Gc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Jc(t,e,n,a,s={}){var P;const o=ce(t),r=e.filter(N=>ce(N.assignee)===o&&(N.status==="claimed"||N.status==="in_progress")).length,l=n.filter(N=>ce(N.from)===o).sort((N,R)=>_t(R.timestamp)-_t(N.timestamp))[0],p=a.filter(N=>ce(N.agent)===o||ce(N.author)===o).sort((N,R)=>_t(R.timestamp)-_t(N.timestamp))[0],f=(s.boardPosts??[]).filter(N=>ce(N.author)===o).sort((N,R)=>_t(R.updated_at||R.created_at)-_t(N.updated_at||N.created_at))[0],m=(s.keepers??[]).filter(N=>ce(N.name)===o&&Ze(N)!==null).sort((N,R)=>_t(Ze(R)??0)-_t(Ze(N)??0))[0],d=l?_t(l.timestamp):0,v=p?_t(p.timestamp):0,c=f?_t(f.updated_at||f.created_at):0,y=m?_t(Ze(m)??0):0,x=s.lastSeen?_t(s.lastSeen):0,T=((P=s.currentTask)==null?void 0:P.trim())||(r>0?`${r} claimed tasks`:null);if(d===0&&v===0&&c===0&&y===0&&x===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:T};const z=[l?{timestamp:l.timestamp,ts:d,text:aa(l.content)}:null,f?{timestamp:f.updated_at||f.created_at,ts:c,text:`Post: ${aa(Wc(f))}`}:null,m?{timestamp:Ze(m),ts:y,text:Gc(m)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:v,text:aa(p.text)}:null].filter(N=>N!==null).sort((N,R)=>R.ts-N.ts)[0];return z&&z.ts>=x?{activeAssignedCount:r,lastActivityAt:z.timestamp,lastActivityText:z.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:T??"Presence heartbeat"}}const Ct=g([]),yt=g([]),An=g([]),Jt=g([]),se=g(null),sn=g(null),Js=g(new Map),Ge=g([]),wn=g("hot"),pe=g(!0),Vo=g(null),Ut=g(""),Cn=g([]),Pe=g(!1),Qo=g(new Map),Vs=g("unknown"),Qs=g(null),Ys=g(!1),Tn=g(!1),Xs=g(!1),De=g(!1),Vc=g(null),Zs=g(null),Yo=g(null),Xo=g(null),Qc=Tt(()=>Ct.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle")),Zo=Tt(()=>{const t=yt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Xa=Tt(()=>{const t=new Map,e=yt.value,n=An.value,a=va.value,s=Ge.value,o=Jt.value;for(const r of Ct.value)t.set(r.name.trim().toLowerCase(),Jc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:s,keepers:o}));return t});function Yc(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const tr=Tt(()=>{const t=new Map;for(const e of Jt.value)t.set(e.name,Yc(e));return t}),Xc=12e4;function Zc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof s=="number"?Date.now()-s*1e3:null}const er=Tt(()=>{const t=Date.now(),e=new Set,n=Js.value;for(const a of Jt.value){const s=Zc(a,n);s!=null&&t-s>Xc&&e.add(a.name)}return e}),_a={},td=5e3;let rs=null;function ed(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Ke(){delete _a.compact,delete _a.full}function mt(t){return typeof t=="object"&&t!==null}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ge(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ti(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function nr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function nd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function ar(t){if(!mt(t))return null;const e=b(t.name);return e?{name:e,status:nr(t.status),current_task:b(t.current_task)??null,last_seen:b(t.last_seen),emoji:b(t.emoji),koreanName:b(t.koreanName)??b(t.korean_name),model:b(t.model),traits:ge(t.traits),interests:ge(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:b(t.primaryValue)??b(t.primary_value)}:null}function sr(t){if(!mt(t))return null;const e=b(t.id),n=b(t.title);return!e||!n?null:{id:e,title:n,status:nd(t.status),priority:A(t.priority),assignee:b(t.assignee),description:b(t.description),created_at:b(t.created_at),updated_at:b(t.updated_at)}}function ir(t){if(!mt(t))return null;const e=b(t.from)??b(t.from_agent)??"system",n=b(t.content)??"",a=b(t.timestamp)??new Date().toISOString();return{id:b(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:b(t.type)}}function ad(t){return Array.isArray(t)?t.map(e=>{if(!mt(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=mt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Qi(t){if(!mt(t))return null;const e=b(t.health_state),n=b(t.next_action_path),a=b(t.last_reply_status);if(!e||!n||!a)return null;const s=b(t.quiet_reason)??null,o=b(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:ti(t.last_reply_at)??b(t.last_reply_at)??null,last_reply_preview:b(t.last_reply_preview)??null,last_error:b(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function sd(t,e){return(Array.isArray(t)?t:mt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!mt(a))return null;const s=mt(a.agent)?a.agent:null,o=mt(a.context)?a.context:null,r=mt(a.metrics_window)?a.metrics_window:void 0,l=b(a.name);if(!l)return null;const p=A(a.context_ratio)??A(o==null?void 0:o.context_ratio),f=b(a.status)??b(s==null?void 0:s.status)??"offline",m=nr(f),d=b(a.model)??b(a.active_model)??b(a.primary_model),v=ge(a.skill_secondary),c=o?{source:b(o.source),context_ratio:A(o.context_ratio),context_tokens:A(o.context_tokens),context_max:A(o.context_max),message_count:A(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,y=s?{name:b(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:b(s.error),status:b(s.status),current_task:b(s.current_task)??null,last_seen:b(s.last_seen),last_seen_ago_s:A(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,x=ad(a.metrics_series),T={name:l,emoji:b(a.emoji),koreanName:b(a.koreanName)??b(a.korean_name),agent_name:b(a.agent_name),trace_id:b(a.trace_id),model:d,primary_model:b(a.primary_model),active_model:b(a.active_model),next_model_hint:b(a.next_model_hint)??null,status:m,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:b(a.last_heartbeat)??b(s==null?void 0:s.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:p,context_tokens:A(a.context_tokens)??A(o==null?void 0:o.context_tokens),context_max:A(a.context_max)??A(o==null?void 0:o.context_max),context_source:b(a.context_source)??b(o==null?void 0:o.source),context:c,traits:ge(a.traits),interests:ge(a.interests),primaryValue:b(a.primaryValue)??b(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:b(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:Qi(a.diagnostic),skill_primary:b(a.skill_primary)??null,skill_secondary:v,skill_reason:b(a.skill_reason)??null,metrics_series:x.length>0?x:void 0,metrics_window:r,agent:y};return T.diagnostic=Qi(a.diagnostic)??zc(T,(e==null?void 0:e.lodge)??null),T}).filter(a=>a!==null)}function id(t){return mt(t)?{...t,lodge:Ec(t.lodge)??void 0}:null}function od(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function rd(t){if(!mt(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,s=mt(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:b(t.changes)??"",failed_attempts:b(t.failed_attempts)??"",next_suggestion:b(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:b(s.worker_model)??"",tool_call_count:A(s.tool_call_count)??0,tool_names:ge(s.tool_names)??[],session_id:b(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ld(t){var o,r;if(!mt(t))return null;const e=b(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(rd).filter(l=>l!==null):[],s=A(t.current_metric)??((o=a[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:b(t.profile)??"unknown",status:od(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:b(t.error_message)??b(t.error_reason)??null,stop_reason:b(t.stop_reason)??b(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:b(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:ti(t.updated_at)??null,stopped_at:ti(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:b(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:ge(t.latest_tool_names)??[],session_id:b(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function ne(t="full"){var a,s,o;const e=Date.now(),n=_a[t];if(!(n&&e-n.time<td)){Ys.value=!0;try{const r=await Cl(t);_a[t]={data:r,time:e},Ct.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(ar).filter(p=>p!==null),yt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(sr).filter(p=>p!==null),An.value=(Array.isArray((o=r.messages)==null?void 0:o.messages)?r.messages.messages:[]).map(ir).filter(p=>p!==null);const l=id(r.status);se.value=l,Jt.value=sd(r.keepers,l),sn.value=r.perpetual??null,Vc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Ys.value=!1}}}async function cd(){try{const t=await Tl(),e=(Array.isArray(t.agents)?t.agents:[]).map(ar).filter(s=>s!==null),n=Ct.value,a=new Map(n.map(s=>[s.name,s]));Ct.value=e.map(s=>{const o=a.get(s.name);return o?{...o,status:s.status,current_task:s.current_task}:s})}catch(t){console.error("Agents selective fetch error:",t)}}async function dd(){try{const t=await Nl({includeDone:!0,includeCancelled:!0}),e=(Array.isArray(t.tasks)?t.tasks:[]).map(sr).filter(s=>s!==null),n=yt.value,a=new Map(n.map(s=>[s.id,s]));yt.value=e.map(s=>{const o=a.get(s.id);return o?{...o,status:s.status,priority:s.priority??o.priority,assignee:s.assignee??o.assignee}:s})}catch(t){console.error("Tasks selective fetch error:",t)}}async function ud(){try{const t=An.value,e=t.reduce((l,p)=>Math.max(l,p.seq??0),0),n=await Rl(e),a=(Array.isArray(n.messages)?n.messages:[]).map(ir).filter(l=>l!==null);if(a.length===0)return;const s=new Set(t.map(l=>l.seq).filter(l=>l!=null)),o=new Set(t.filter(l=>l.seq==null).map(l=>`${l.timestamp}|${l.from}`)),r=a.filter(l=>{if(l.seq!=null)return!s.has(l.seq);const p=`${l.timestamp}|${l.from}`;return o.has(p)?!1:(o.add(p),!0)});if(r.length>0){const l=[...t,...r];An.value=l.length>500?l.slice(-500):l}}catch(t){console.error("Messages selective fetch error:",t)}}async function jt(){Tn.value=!0;try{const t=await Gl(wn.value,{excludeSystem:pe.value});Ge.value=t.posts??[],Zs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Tn.value=!1}}async function qt(){var t;Xs.value=!0;try{const e=Ut.value||((t=se.value)==null?void 0:t.room)||"default";Ut.value||(Ut.value=e);const n=await dc(e);Vo.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Xs.value=!1}}async function Nn(){Pe.value=!0;try{const t=await Nc();Cn.value=Array.isArray(t)?t:[],Yo.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{Pe.value=!1}}async function He(){De.value=!0;try{const t=await Ll(),e=Array.isArray(t.loops)?t.loops:[],n=new Map;for(const a of e){const s=ld(a);s&&n.set(s.loop_id,s)}Qo.value=n,Xo.value=new Date().toISOString(),Qs.value=null,Vs.value=n.size===0?"idle":"ready"}catch(t){console.error("MDAL fetch error:",t),Vs.value="error",Qs.value=t instanceof Error?t.message:String(t)}finally{De.value=!1}}let sa=null;function pd(t){sa=t}let ia=null;function md(t){ia=t}const me={};function de(t,e,n=500){me[t]&&clearTimeout(me[t]),me[t]=setTimeout(()=>{e(),delete me[t]},n)}function vd(){const t=Io.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Js.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Js.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&de("agents",cd),ed(e.type)&&(Ke(),rs||(rs=setTimeout(()=>{ne(),ia==null||ia(),rs=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&de("tasks",dd),e.type==="broadcast"&&de("messages",ud),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&de("dashboard",()=>{Ke(),ne()}),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&de("board",jt),e.type.startsWith("decision_")&&de("council",()=>sa==null?void 0:sa()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&de("mdal",He,350)}});return()=>{t();for(const e of Object.keys(me))clearTimeout(me[e]),delete me[e]}}let cn=null;function fd(){cn||(cn=setInterval(()=>{Ft.value||Ke(),ne()},1e4))}function _d(){cn&&(clearInterval(cn),cn=null)}function C({title:t,class:e,children:n}){return i`
    <div class="card ${e??""}">
      ${t?i`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Pt({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function gd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const o=Math.floor(s/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function B({timestamp:t}){const e=gd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}function Y(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ot(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function ve(t){return(t??"").trim().toLowerCase()}function ut(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function zt(t){return typeof t!="number"||Number.isNaN(t)?3:t}function Ti(t){const e=zt(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}let $d=0;const fe=g([]);function w(t,e="success",n=4e3){const a=++$d;fe.value=[...fe.value,{id:a,message:t,type:e}],setTimeout(()=>{fe.value=fe.value.filter(s=>s.id!==a)},n)}function hd(t){fe.value=fe.value.filter(e=>e.id!==t)}function yd(){const t=fe.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>hd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const bd="masc_dashboard_agent_name",Je=g(null),ga=g(!1),Rn=g(""),$a=g([]),Ln=g([]),Ie=g(""),dn=g(!1);function Oe(t){Je.value=t,Ni()}function Yi(){Je.value=null,Rn.value="",$a.value=[],Ln.value=[],Ie.value=""}function kd(){const t=Je.value;return t?Ct.value.find(e=>e.name===t)??null:null}function or(t){return t?yt.value.filter(e=>e.assignee===t):[]}async function Ni(){const t=Je.value;if(t){ga.value=!0,Rn.value="",$a.value=[],Ln.value=[];try{const e=await kc(80);$a.value=e.filter(s=>s.includes(t)).slice(0,20);const n=or(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const o=await xc(s.id,25);return{taskId:s.id,text:o.trim()}}catch(o){const r=o instanceof Error?o.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Ln.value=a}catch(e){Rn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ga.value=!1}}}async function Xi(){var a;const t=Je.value,e=Ie.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(bd))==null?void 0:a.trim())||"dashboard";dn.value=!0;try{await Uo(n,`@${t} ${e}`),Ie.value="",w(`Mention sent to ${t}`,"success"),Ni()}catch(s){const o=s instanceof Error?s.message:"Failed to send mention";w(o,"error")}finally{dn.value=!1}}function xd({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Pt} status=${t.status} />
    </div>
  `}function Sd({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Ad(){var s,o,r,l;const t=Je.value;if(!t)return null;const e=kd(),n=or(t),a=$a.value;return i`
    <div
      class="agent-detail-overlay"
      onClick=${p=>{p.target.classList.contains("agent-detail-overlay")&&Yi()}}
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
                        <${Pt} status=${e.status} />
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
                    ${e.last_seen?i`<span>Last seen: <${B} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Ni()}} disabled=${ga.value}>
              ${ga.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Yi}>Close</button>
          </div>
        </div>

        ${Rn.value?i`<div class="council-error">${Rn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${C} title="Assigned Tasks">
            ${n.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${n.map(p=>i`<${xd} key=${p.id} task=${p} />`)}</div>`}
          <//>

          <${C} title="Recent Activity">
            ${a.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${a.map((p,f)=>i`<div key=${f} class="agent-activity-line">${p}</div>`)}</div>`}
          <//>
        </div>

        <${C} title="Task History">
          ${Ln.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Ln.value.map(p=>i`<${Sd} key=${p.taskId} row=${p} />`)}</div>`}
        <//>

        <${C} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ie.value}
              onInput=${p=>{Ie.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&Xi()}}
              disabled=${dn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Xi()}}
              disabled=${dn.value||Ie.value.trim()===""}
            >
              ${dn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ha=600*1e3,oa=1200*1e3;function rr(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function lr(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function wd(t){return t.updated_at??t.created_at??null}function Zi(t,e,n){var T,L;const a=ve(t.assignee),s=a?e.get(a)??null:null,o=s?n.get(a)??null:null,r=(o==null?void 0:o.lastActivityAt)??(s==null?void 0:s.last_seen)??null,l=r?Math.max(0,Date.now()-Y(r)):Number.POSITIVE_INFINITY,p=ut(t.description),f=ut(s==null?void 0:s.current_task)??(o==null?void 0:o.lastActivityText)??null,m=t.status==="claimed"||t.status==="in_progress";let d="ok",v="Fresh owner coverage",c=f??p??t.id,y=!1,x=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?(y=!0,d="bad",v="Assigned owner is offline",c="Queue item is blocked until ownership changes."):l>ha?(d="warn",v="Owner exists but live signal is quiet",c=f??"Owner may need a nudge before pickup."):((o==null?void 0:o.activeAssignedCount)??0)>0||(T=s.current_task)!=null&&T.trim()?(d="warn",v="Owner is already carrying active work",c=f??`${(o==null?void 0:o.activeAssignedCount)??0} active tasks already assigned.`):(v="Ready and covered by a fresh operator",c=f??p??"This can be picked up immediately."):(y=!0,d="bad",v="Assigned owner is not present in the room",c="Reassign or bring the owner back online."):(y=!0,d=zt(t.priority)<=2?"bad":"warn",v=zt(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",c="Assign an agent before this queue item slips."):m&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?(y=!0,d="bad",v="Assigned owner is offline",c=f??"Execution has no live operator right now."):l>oa?(x=!0,d="bad",v="Assigned owner has gone quiet",c=f??"Fresh operator signal is missing."):l>ha?(x=!0,d="warn",v="Execution has been quiet for too long",c=f??"Check whether this work is blocked."):(L=s.current_task)!=null&&L.trim()?(v="Execution has fresh owner coverage",c=f??p??t.id):(d="warn",v=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",c=f??"Task state and agent focus are drifting apart."):(y=!0,d="bad",v="Assigned owner is not active in the room",c="Execution is orphaned until ownership is restored."):(y=!0,d="bad",v="Active work has no assignee",c="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:o,tone:d,note:v,focus:c,lastSignalAt:r,lastTouchedAt:wd(t),ownerGap:y,quiet:x}}function Cd(t,e){var v;const n=e.get(ve(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-Y(a)):Number.POSITIVE_INFINITY,o=!!((v=t.current_task)!=null&&v.trim()),r=n.activeAssignedCount,l=o||r>0;let p="loaded",f="ok",m="Healthy active load",d=ut(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(p="offline",f="bad",m="Agent is unavailable"):l&&s>oa?(p="quiet",f="bad",m="Working without a fresh signal"):r>0&&!o?(p="drift",f="warn",m="Claimed work exists but current_task is empty",d=`${r} active tasks need explicit focus.`):o&&r===0?(p="drift",f="warn",m="current_task has no matching claimed work",d=ut(t.current_task)??"Task metadata and operator state drifted."):!l&&s<=ha?(p="dispatchable",f="ok",m="Fresh signal and no active load",d=n.lastActivityText??"Ready for assignment."):l?s>ha&&(p="loaded",f="warn",m="Execution load is healthy but slightly quiet",d=ut(t.current_task)??`${r} active tasks in flight.`):(p="quiet",f=s>oa?"bad":"warn",m=s>oa?"No fresh signal while idle":"Reachable, but not freshly active",d=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:f,state:p,note:m,focus:d,lastSignalAt:a,activeTaskCount:r}}function tn({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Td({item:t}){return i`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?Ti(t.taskRow.task.priority):lr(t.agentRow.state)}
        </span>
        ${t.kind==="task"?i`<span>${rr(t.taskRow.task.status)}</span>`:i`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?i`<span><${B} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </div>
  `}function to({row:t}){var e;return i`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${Ti(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?i`<${Pt} status=${t.assigneeAgent.status} />`:i`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${rr(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?i`<span>Owner ${t.task.assignee}</span>`:i`<span>Unassigned</span>`}
        ${t.lastTouchedAt?i`<span>Touched <${B} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?i`<span>Signal <${B} timestamp=${t.lastSignalAt} /></span>`:i`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ut(t.assigneeAgent.current_task)!==t.focus?i`<div class="monitor-footnote">Owner focus: ${ut(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function Nd({row:t}){const{agent:e}=t;return i`
    <button class="monitor-row ${t.tone}" onClick=${()=>Oe(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Pt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${lr(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${B} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function Rd(){const t=Ct.value,e=yt.value,n=new Map(t.map(d=>[ve(d.name),d])),a=Xa.value,s=e.filter(d=>d.status==="claimed"||d.status==="in_progress").map(d=>Zi(d,n,a)).sort((d,v)=>{const c=ot(v.tone)-ot(d.tone);return c!==0?c:Y(v.lastSignalAt??v.lastTouchedAt)-Y(d.lastSignalAt??d.lastTouchedAt)}),o=e.filter(d=>d.status==="todo").map(d=>Zi(d,n,a)).sort((d,v)=>{const c=ot(v.tone)-ot(d.tone);if(c!==0)return c;const y=zt(d.task.priority)-zt(v.task.priority);return y!==0?y:Y(d.lastTouchedAt)-Y(v.lastTouchedAt)}),r=t.map(d=>Cd(d,a)).filter(d=>d.state==="dispatchable"||d.state==="drift"||d.state==="quiet").sort((d,v)=>{if(d.state==="dispatchable"&&v.state!=="dispatchable")return-1;if(v.state==="dispatchable"&&d.state!=="dispatchable")return 1;const c=ot(v.tone)-ot(d.tone);return c!==0?c:Y(v.lastSignalAt)-Y(d.lastSignalAt)}),l=[...s.filter(d=>d.tone!=="ok").map(d=>({kind:"task",key:`active-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt??d.lastTouchedAt,taskRow:d})),...o.filter(d=>d.tone==="bad").map(d=>({kind:"task",key:`ready-${d.task.id}`,tone:d.tone,title:d.task.title,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastTouchedAt,taskRow:d})),...r.filter(d=>d.state==="drift"||d.tone==="bad").map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agentRow:d}))].sort((d,v)=>{const c=ot(v.tone)-ot(d.tone);return c!==0?c:Y(v.timestamp)-Y(d.timestamp)}).slice(0,8),p=r.filter(d=>d.state==="dispatchable"),f=[...s,...o].filter(d=>d.ownerGap),m=s.filter(d=>d.quiet);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${tn} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${tn} label="Needs intervention" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${tn} label="Ownership gaps" value=${f.length} color=${f.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${tn} label="Dispatchable agents" value=${p.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${tn} label="Quiet execution" value=${m.length} color=${m.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${C} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${l.length===0?i`<div class="empty-state">No active execution risks right now</div>`:l.map(d=>i`<${Td} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${C} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${o.length===0?i`<div class="empty-state">No ready tasks in the queue</div>`:o.slice(0,10).map(d=>i`<${to} key=${d.task.id} row=${d} />`)}
          </div>
        <//>

        <${C} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?i`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(d=>i`<${Nd} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>

      <${C} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?i`<div class="empty-state">No active execution tasks</div>`:s.map(d=>i`<${to} key=${d.task.id} row=${d} />`)}
        </div>
      <//>
    </div>
  `}function Ld(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Pd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Dd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function eo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function cr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Md(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function dr(t){if(!t)return null;const e=Bt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function ur({keeper:t,showRawStatus:e=!1}){if(ct(()=>{t!=null&&t.name&&Jo(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Bt.value[t.name],a=dr(t),s=Ks.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Ld(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Pd((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?i` · ${cr(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?i` · next eligible ${Md(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?i`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function pr({keeperName:t,placeholder:e}){const[n,a]=Qa("");ct(()=>{t&&Jo(t)},[t]);const s=pt.value[t]??[],o=Hs.value[t]??!1,r=Wt.value[t],l=async()=>{const p=n.trim();if(!(!t||!p)){a("");try{await Hc(t,p)}catch(f){const m=f instanceof Error?f.message:`Failed to message ${t}`;w(m,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${eo(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${eo(p)}`}>${Dd(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${cr(p.timestamp)}</span>`:null}
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
  `}function mr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=dr(e),s=Us.value[e.name]??!1,o=Bs.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",l=(a==null?void 0:a.recoverable)??r==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Uc(e.name,t).catch(p=>{const f=p instanceof Error?p.message:`Failed to probe ${e.name}`;w(f,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Bc(e.name,t).catch(p=>{const f=p instanceof Error?p.message:`Failed to recover ${e.name}`;w(f,"error")})}}
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
  `}const Ri=g(null);function ya(t){Ri.value=t,na(t.name)}function no(){Ri.value=null}const Te=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Ed(t){if(!t)return 0;const e=Te.findIndex(n=>n.level===t);return e>=0?e:0}function Id({keeper:t}){const e=Ed(t.autonomy_level),n=Te[e]??Te[0];if(!n)return null;const a=(e+1)/Te.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Te.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Te.map((s,o)=>i`
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
            <strong><${B} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ra(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Od({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${s.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ra(t.context_tokens)}</div>
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
  `}function zd({keeper:t}){var m,d;const e=t.metrics_series??[];if(e.length<2){const v=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,c=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${c}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,o=e.length,r=e.map((v,c)=>{const y=s+c/(o-1)*(n-2*s),x=a-s-(v.context_ratio??0)*(a-2*s);return{x:y,y:x,p:v}}),l=r.map(({x:v,y:c})=>`${v.toFixed(1)},${c.toFixed(1)}`).join(" "),p=(((d=e[e.length-1])==null?void 0:d.context_ratio)??0)*100,f=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${s}" x2="${v.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${l}" fill="none" stroke="${f}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:c})=>i`
          <circle cx="${v.toFixed(1)}" cy="${c.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const ls=g("");function jd({keeper:t}){var s,o,r,l;const e=ls.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],a=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ls.value}
        onInput=${p=>{ls.value=p.target.value}}
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ra(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ra(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ra(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function qd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function Fd({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Kd({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function ao({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function cs(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Hd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:cs(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:cs(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:cs(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(a=>i`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function vr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Ud(){try{const t=await zn({actor:vr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=wi(t.result);Ke(),await ne(),e!=null&&e.skipped_reason?w(e.skipped_reason,"warning"):w(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";w(e,"error")}}function Bd({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${ur} keeper=${t} />
          <${mr}
            actor=${vr()}
            keeper=${t}
            onPokeLodge=${()=>{Ud()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${pr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Wd(){var e,n,a;const t=Ri.value;return t?i`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&no()}}
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
            <${Pt} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>no()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Od} keeper=${t} />

        ${""}
        <${zd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${C} title="Field Dictionary">
            <${jd} keeper=${t} />
          <//>

          ${""}
          <${C} title="Profile">
            <${ao} traits=${t.traits??[]} label="Traits" />
            <${ao} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${B} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${C} title="Autonomy">
                <${Id} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${C} title="TRPG Stats">
                <${qd} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${C} title="Equipment (${t.inventory.length})">
                <${Fd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${C} title="Relationships (${Object.keys(t.relationships).length})">
                <${Kd} rels=${t.relationships} />
              <//>
            `:null}

          <${C} title="Runtime Signals">
            <${Hd} keeper=${t} />
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
        <${Bd} keeper=${t} />
      </div>
    </div>
  `:null}const Ue=g(!1);function Gd(){Ue.value=!0}function so(){Ue.value=!1}function Jd(){Ue.value=!Ue.value}const ds=600*1e3,us=1200*1e3,io=.8,ps=g("triage");function Ae(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Un(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function oo(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function ro(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Vd(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ms(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Qd(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Yd(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Xd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Zd(t){return t?t.enabled?t.quiet_active?`Quiet hours ${oo(t.quiet_start)}-${oo(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${ro(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${ro(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function lo(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function tu(t){return t==null||t===0?"":t>0?` +${t} ↑`:` ${t} ↓`}function eu(t){return t==null||t===0?"stat-delta neutral":t>0?"stat-delta up":"stat-delta down"}function nu({data:t}){if(!t||t.length<2)return null;const e=Math.max(...t),n=Math.min(...t),a=e-n||1,s=60,o=20,r=t.map((l,p)=>`${p/(t.length-1)*s},${o-(l-n)/a*o}`).join(" ");return i`
    <svg class="stat-sparkline" viewBox="0 0 ${s} ${o}" preserveAspectRatio="none">
      <polyline points=${r} fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  `}function we({label:t,value:e,color:n,caption:a,delta:s,spark:o}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value-row">
        <span class="stat-value" style=${n?`color: ${n}`:""}>${e}</span>
        ${s!=null&&s!==0?i`<span class=${eu(s)}>${tu(s)}</span>`:null}
        ${o?i`<${nu} data=${o} />`:null}
      </div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function au({item:t}){return i`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?i`<span><${B} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function vs({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:o}){return i`
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
  `}function co(){var G,H,kt,nt,at,U,I,S,Dt,Vt,oe,re,E,Mt,le,Qe,Ye,Kn;const t=se.value,e=Ct.value,n=yt.value,a=Jt.value,s=Zo.value,o=(G=t==null?void 0:t.monitoring)==null?void 0:G.board,r=(H=t==null?void 0:t.monitoring)==null?void 0:H.council,l=Ft.value,p=new Map(e.map(_=>[ve(_.name),_])),f=Xa.value,m=e.map(_=>{var Fi;const D=f.get(ve(_.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},K=D.lastActivityAt??_.last_seen??null,it=K?Math.max(0,Date.now()-Y(K)):Number.POSITIVE_INFINITY,q=D.activeAssignedCount,ft=!!((Fi=_.current_task)!=null&&Fi.trim()),et=ft||q>0;let Z="ok",xt="Fresh and ready",ke=!1,xe=!1;return _.status==="offline"||_.status==="inactive"?(Z=et?"bad":"warn",xt=et?"Load without an available owner":"Offline"):et&&it>us?(Z="bad",xt="Execution is stale"):q>0&&!ft?(Z="warn",xt="Claimed work has no current_task",xe=!0):ft&&q===0?(Z="warn",xt="current_task has no claimed work",xe=!0):!et&&it<=ds?(Z="ok",xt="Dispatchable now",ke=!0):!et&&it>us?(Z="warn",xt="Idle but not freshly active"):et&&it>ds&&(Z="warn",xt="Execution is getting quiet"),{agent:_,lastSignalAt:K,activeTaskCount:q,tone:Z,note:xt,focus:ut(_.current_task)??D.lastActivityText??(ke?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:ke,drift:xe}}).sort((_,D)=>{const K=ot(D.tone)-ot(_.tone);return K!==0?K:Y(D.lastSignalAt)-Y(_.lastSignalAt)}),d=a.map(_=>{var Z;const D=tr.value.get(_.name)??"idle",K=er.value.has(_.name),it=_.context_ratio??0,q=_.diagnostic??null;let ft="ok",et="Healthy keeper";return K||_.status==="offline"||D==="handoff-imminent"||(q==null?void 0:q.health_state)==="offline"||(q==null?void 0:q.health_state)==="degraded"?(ft="bad",et=ut(q==null?void 0:q.summary,56)??(K?"Heartbeat stale":D==="handoff-imminent"?"Handoff imminent":(q==null?void 0:q.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((q==null?void 0:q.health_state)==="stale"||it>=io||D==="preparing"||D==="compacting")&&(ft="warn",et=ut(q==null?void 0:q.summary,56)??(it>=io?"High context pressure":`Lifecycle ${D}`)),{keeper:_,tone:ft,note:et,focus:ut(q==null?void 0:q.summary,120)??ut((Z=_.agent)==null?void 0:Z.current_task)??_.skill_primary??_.last_proactive_reason??_.memory_recent_note??"No active focus",timestamp:_.last_heartbeat??null}}).sort((_,D)=>{const K=ot(D.tone)-ot(_.tone);return K!==0?K:Y(D.timestamp)-Y(_.timestamp)}),v=n.filter(_=>_.status==="todo"||_.status==="claimed"||_.status==="in_progress").map(_=>{var ke,xe;const D=_.assignee?p.get(ve(_.assignee))??null:null,K=D?f.get(ve(D.name))??null:null,it=(K==null?void 0:K.lastActivityAt)??(D==null?void 0:D.last_seen)??null,q=it?Math.max(0,Date.now()-Y(it)):Number.POSITIVE_INFINITY,ft=_.status==="claimed"||_.status==="in_progress";let et="ok",Z="Covered",xt=!1;return _.assignee?!D||D.status==="offline"||D.status==="inactive"?(et="bad",Z="Assigned owner is unavailable",xt=!0):ft&&q>us?(et="bad",Z="Execution has lost a fresh signal"):ft&&q>ds?(et="warn",Z="Execution is drifting quiet"):_.status==="todo"&&zt(_.priority)<=2&&!((ke=D.current_task)!=null&&ke.trim())&&((K==null?void 0:K.activeAssignedCount)??0)===0?(et="ok",Z="Ready for dispatch"):ft&&!((xe=D.current_task)!=null&&xe.trim())&&(et="warn",Z="Owner focus is not explicit"):(et=zt(_.priority)<=2?"bad":"warn",Z=ft?"Active work has no owner":"Ready work has no owner",xt=!0),{task:_,owner:D,lastSignalAt:it,tone:et,note:Z,focus:ut(D==null?void 0:D.current_task)??(K==null?void 0:K.lastActivityText)??ut(_.description)??"Needs operator attention.",ownerGap:xt}}).sort((_,D)=>{const K=ot(D.tone)-ot(_.tone);if(K!==0)return K;const it=zt(_.task.priority)-zt(D.task.priority);return it!==0?it:Y(D.lastSignalAt??D.task.updated_at??D.task.created_at)-Y(_.lastSignalAt??_.task.updated_at??_.task.created_at)}),c=v.filter(_=>_.task.status==="todo"&&zt(_.task.priority)<=2),y=v.filter(_=>_.ownerGap).length,x=m.filter(_=>_.dispatchable),T=m.filter(_=>_.drift||_.tone!=="ok"),L=d.filter(_=>_.tone!=="ok"),z=t!=null&&t.paused?"bad":((kt=t==null?void 0:t.data_quality)==null?void 0:kt.board_contract_ok)===!1||((nt=t==null?void 0:t.data_quality)==null?void 0:nt.council_feed_ok)===!1?"warn":l?"ok":"warn",P=[];t!=null&&t.paused&&P.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((at=t.data_quality)==null?void 0:at.last_sync_at)??null,action:()=>wt("ops")}),l||P.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:Gd}),Ae(o==null?void 0:o.alert_level)!=="ok"&&P.push({key:"board-monitor",tone:Ae(o==null?void 0:o.alert_level),title:"Board feed needs attention",detail:`Freshness ${ms(o==null?void 0:o.last_activity_age_s)} · ${(o==null?void 0:o.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>wt("board")}),Ae(r==null?void 0:r.alert_level)!=="ok"&&P.push({key:"council-monitor",tone:Ae(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${ms(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>wt("board")}),(((U=t==null?void 0:t.data_quality)==null?void 0:U.board_contract_ok)===!1||((I=t==null?void 0:t.data_quality)==null?void 0:I.council_feed_ok)===!1)&&P.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((S=t.data_quality)==null?void 0:S.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((Dt=t.data_quality)==null?void 0:Dt.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:((Vt=t.data_quality)==null?void 0:Vt.last_sync_at)??null,action:()=>wt("ops")});const N=[...P,...v.filter(_=>_.tone!=="ok").slice(0,3).map(_=>({key:`task-${_.task.id}`,tone:_.tone,title:_.task.title,detail:`${_.note} · ${_.focus}`,timestamp:_.lastSignalAt??_.task.updated_at??_.task.created_at??null,action:()=>wt("overview")})),...L.slice(0,2).map(_=>({key:`keeper-${_.keeper.name}`,tone:_.tone,title:_.keeper.name,detail:`${_.note} · ${_.focus}`,timestamp:_.timestamp,action:()=>ya(_.keeper)})),...T.slice(0,2).map(_=>({key:`agent-${_.agent.name}`,tone:_.tone,title:_.agent.name,detail:`${_.note} · ${_.focus}`,timestamp:_.lastSignalAt,action:()=>Oe(_.agent.name)}))].sort((_,D)=>{const K=ot(D.tone)-ot(_.tone);return K!==0?K:Y(D.timestamp)-Y(_.timestamp)}).slice(0,8),R=ps.value;return i`
    <div class="overview-sub-tabs">
      <button
        class="sub-tab-btn ${R==="triage"?"active":""}"
        onClick=${()=>{ps.value="triage"}}
      >Triage</button>
      <button
        class="sub-tab-btn ${R==="dispatch"?"active":""}"
        onClick=${()=>{ps.value="dispatch"}}
      >Dispatch</button>
    </div>

    ${R==="dispatch"?i`<${Rd} />`:i`<div class="stats-grid">
      <${we}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Un(z)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${we}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${we}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${we}
        label="Dispatchable"
        value=${x.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${we}
        label="Keeper Pressure"
        value=${L.length}
        color=${L.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${we}
        label="Owner Gaps"
        value=${y}
        color=${y>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${C} title="Room Health" class="section">
      <div class="health-strip">
        <span class="health-dot" style=${`color:${l?"#4ade80":"#fbbf24"}`} title=${`Live Feed: ${l?"Online":"Retrying"} · ${In.value} events`}>● Live</span>
        <span class="health-dot" style=${`color:${Un(Ae(o==null?void 0:o.alert_level))}`} title=${`Board: ${lo(o==null?void 0:o.alert_level)} · Freshness ${ms(o==null?void 0:o.last_activity_age_s)}`}>● Board</span>
        <span class="health-dot" style=${`color:${Un(Ae(r==null?void 0:r.alert_level))}`} title=${`Council: ${lo(r==null?void 0:r.alert_level)} · ${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum`}>● Council</span>
        <span class="health-dot" style=${`color:${Un(z)}`} title=${`Runtime: ${t!=null&&t.paused?"Paused":"Stable"}`}>● Runtime</span>
        <span class="health-uptime">Uptime ${Vd((t==null?void 0:t.uptime_seconds)??0)}</span>
      </div>
      <details class="runtime-collapsible">
        <summary class="runtime-summary">Sync and tempo details</summary>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            ${(oe=t==null?void 0:t.data_quality)!=null&&oe.last_sync_at?i`Last sync <${B} timestamp=${t.data_quality.last_sync_at} />`:i`No sync metadata yet`}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
          </div>
          <div class="overview-inline-note">${Zd(t==null?void 0:t.lodge)}</div>
          ${(re=t==null?void 0:t.lodge)!=null&&re.last_skip_reason?i`<div class="overview-inline-note">Last Lodge skip: ${t.lodge.last_skip_reason}</div>`:null}
        </div>
      </details>
    <//>

    <div class="overview-workbench">
      <div class="overview-column">
        <${C} title="Intervention Queue" class="section">
          <div class="monitor-alert-list">
            ${N.length===0?i`<div class="empty-state">No immediate intervention required</div>`:N.map(_=>i`<${au} key=${_.key} item=${_} />`)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${C} title="Dispatch Window" class="section">
          <div class="monitor-list">
            ${x.length===0?i`<div class="empty-state">No fully dispatchable agents right now</div>`:x.slice(0,5).map(_=>i`
                  <${vs}
                    key=${_.agent.name}
                    tone=${_.tone}
                    title=${_.agent.name}
                    subtitle=${_.note}
                    meta=${[_.lastSignalAt?`Signal ${new Date(_.lastSignalAt).toLocaleTimeString()}`:"No recent signal",_.agent.model??"model n/a",_.agent.koreanName??"room agent"]}
                    focus=${_.focus}
                    onClick=${()=>Oe(_.agent.name)}
                  />
                `)}
          </div>
        <//>

        <${C} title="Agent Watch" class="section">
          <div class="monitor-list">
            ${T.length===0?i`<div class="empty-state">No agent drift or stale load right now</div>`:T.slice(0,4).map(_=>i`
                  <button class="monitor-row ${_.tone}" onClick=${()=>Oe(_.agent.name)}>
                    <div class="monitor-row-header">
                      <div class="monitor-row-title">
                        <div class="monitor-name-line">
                          <span class="monitor-title">${_.agent.name}</span>
                          ${_.agent.koreanName?i`<span class="monitor-sub">${_.agent.koreanName}</span>`:null}
                        </div>
                        <div class="monitor-note">${_.note}</div>
                      </div>
                      <${Pt} status=${_.agent.status} />
                      <span class="monitor-pill ${_.tone}">${_.dispatchable?"Ready":_.drift?"Drift":"Watch"}</span>
                    </div>
                    <div class="monitor-meta">
                      ${_.lastSignalAt?i`<span>Signal <${B} timestamp=${_.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
                      <span>${_.activeTaskCount>0?`${_.activeTaskCount} active tasks`:"No active tasks"}</span>
                      ${_.agent.model?i`<span>${_.agent.model}</span>`:null}
                    </div>
                    <div class="monitor-focus">${_.focus}</div>
                  </button>
                `)}
          </div>
        <//>
      </div>

      <div class="overview-column">
        <${C} title="Keeper Pressure" class="section">
          <div class="monitor-list">
            ${L.length===0?i`<div class="empty-state">No keeper pressure signals right now</div>`:L.slice(0,4).map(_=>{var D;return i`
                  <${vs}
                    key=${_.keeper.name}
                    tone=${_.tone}
                    title=${_.keeper.name}
                    subtitle=${(D=_.keeper.diagnostic)!=null&&D.health_state?`${_.note} · ${_.keeper.diagnostic.health_state}`:_.note}
                    meta=${[_.timestamp?`Heartbeat ${new Date(_.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof _.keeper.context_ratio=="number"?Math.round(_.keeper.context_ratio*100):0}%`,_.keeper.model?`Model ${_.keeper.model}`:"model n/a",_.keeper.diagnostic?`${Yd(_.keeper.diagnostic.quiet_reason)} · next ${Xd(_.keeper.diagnostic.next_action_path)} · reply ${_.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                    focus=${_.focus}
                    onClick=${()=>ya(_.keeper)}
                  />
                `})}
          </div>
        <//>

        <${C} title="Runtime Notes" class="section">
          <details class="runtime-collapsible">
            <summary class="runtime-summary">Runtime context (${5+((E=t==null?void 0:t.lodge)!=null&&E.last_skip_reason?1:0)} items)</summary>
            <div class="overview-note-stack">
              <div class="overview-inline-note">
                Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
              </div>
              <div class="overview-inline-note">
                ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Qc.value.length} · Total tasks ${n.length}
              </div>
              <div class="overview-inline-note">
                ${sn.value?`Perpetual runtime ${sn.value.running?"running":"stopped"}${sn.value.goal?` · ${ut(sn.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
              </div>
              <div class="overview-inline-note">
                Lodge ${(Mt=t==null?void 0:t.lodge)!=null&&Mt.enabled?"enabled":"disabled"} · Last tick ${((le=t==null?void 0:t.lodge)==null?void 0:le.last_tick_ago)??"never"} · Self heartbeats ${((Ye=(Qe=t==null?void 0:t.lodge)==null?void 0:Qe.active_self_heartbeats)==null?void 0:Ye.length)??0}${(Kn=t==null?void 0:t.lodge)!=null&&Kn.last_skip_reason?` · Skip ${t.lodge.last_skip_reason}`:""}
              </div>
              <div class="overview-inline-note">
                ${a.length>0?`Hot keepers: ${L.length} · Highest context ${Qd(Math.max(...a.map(_=>_.context_tokens??0)))}`:"No keepers registered"}
              </div>
            </div>
          </details>
        <//>
      </div>
    </div>

    <${C} title="Execution Pulse" class="section">
        <div class="monitor-list">
          ${v.length===0?i`<div class="empty-state">No active or ready tasks</div>`:v.slice(0,6).map(_=>i`
                <${vs}
                  key=${_.task.id}
                  tone=${_.tone}
                  title=${_.task.title}
                  subtitle=${`${Ti(_.task.priority)} · ${_.note}`}
                  meta=${[_.task.assignee?`Owner ${_.task.assignee}`:"Unassigned",_.lastSignalAt?`Signal ${new Date(_.lastSignalAt).toLocaleTimeString()}`:"No live signal",_.task.updated_at?`Touched ${new Date(_.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${_.focus}
                  onClick=${()=>wt("overview")}
                />
              `)}
        </div>
    <//>`}
  `}const su="modulepreload",iu=function(t){return"/dashboard/"+t},uo={},ou=function(e,n,a){let s=Promise.resolve();if(n&&n.length>0){let r=function(f){return Promise.all(f.map(m=>Promise.resolve(m).then(d=>({status:"fulfilled",value:d}),d=>({status:"rejected",reason:d}))))};document.getElementsByTagName("link");const l=document.querySelector("meta[property=csp-nonce]"),p=(l==null?void 0:l.nonce)||(l==null?void 0:l.getAttribute("nonce"));s=r(n.map(f=>{if(f=iu(f),f in uo)return;uo[f]=!0;const m=f.endsWith(".css"),d=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${f}"]${d}`))return;const v=document.createElement("link");if(v.rel=m?"stylesheet":su,m||(v.as="script"),v.crossOrigin="",v.href=f,p&&v.setAttribute("nonce",p),document.head.appendChild(v),m)return new Promise((c,y)=>{v.addEventListener("load",c),v.addEventListener("error",()=>y(new Error(`Unable to preload CSS for ${f}`)))})}))}function o(r){const l=new Event("vite:preloadError",{cancelable:!0});if(l.payload=r,window.dispatchEvent(l),!l.defaultPrevented)throw r}return s.then(r=>{for(const l of r||[])l.status==="rejected"&&o(l.reason);return e().catch(o)})},fr=g(null),Ht=g(null),ba=g(!1),ka=g(!1),xa=g(null),Sa=g(null),ei=g(null),Aa=g(null),$e=g("summary"),jn=g(null),ni=g(!1),wa=g(null),_r=g(null),ai=g(!1),Ca=g(null),Li=g(null),si=g(!1),Ta=g(null),Pn=g(null),Na=g(!1),Dn=g(null),ze=g(null);let on=null;function Pi(t){return t!=="summary"&&t!=="swarm"}function k(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function u(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Q(t){return typeof t=="boolean"?t:void 0}function vt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function ru(){if(typeof window>"u")return;const e=new URLSearchParams(window.location.search).get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function lu(t){if(k(t))return{policy_class:u(t.policy_class),approval_class:u(t.approval_class),tool_allowlist:vt(t.tool_allowlist),model_allowlist:vt(t.model_allowlist),requires_human_for:vt(t.requires_human_for),autonomy_level:u(t.autonomy_level),escalation_timeout_sec:$(t.escalation_timeout_sec),kill_switch:Q(t.kill_switch),frozen:Q(t.frozen)}}function cu(t){if(k(t))return{headcount_cap:$(t.headcount_cap),active_operation_cap:$(t.active_operation_cap),max_cost_usd:$(t.max_cost_usd),max_tokens:$(t.max_tokens)}}function Di(t){if(!k(t))return null;const e=u(t.unit_id),n=u(t.label),a=u(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:u(t.parent_unit_id)??null,leader_id:u(t.leader_id)??null,roster:vt(t.roster),capability_profile:vt(t.capability_profile),source:u(t.source),created_at:u(t.created_at),updated_at:u(t.updated_at),policy:lu(t.policy),budget:cu(t.budget)}}function gr(t){if(!k(t))return null;const e=Di(t.unit);return e?{unit:e,leader_status:u(t.leader_status),roster_total:$(t.roster_total),roster_live:$(t.roster_live),active_operation_count:$(t.active_operation_count),health:u(t.health),reasons:vt(t.reasons),children:Array.isArray(t.children)?t.children.map(gr).filter(n=>n!==null):[]}:null}function du(t){if(k(t))return{total_units:$(t.total_units),company_count:$(t.company_count),platoon_count:$(t.platoon_count),squad_count:$(t.squad_count),leaf_agent_unit_count:$(t.leaf_agent_unit_count),live_agent_count:$(t.live_agent_count),managed_unit_count:$(t.managed_unit_count),active_operation_count:$(t.active_operation_count)}}function $r(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),source:u(e.source),summary:du(e.summary),units:Array.isArray(e.units)?e.units.map(gr).filter(n=>n!==null):[]}}function uu(t){if(!k(t))return null;const e=u(t.kind),n=u(t.status);return!e||!n?null:{kind:e,chain_id:u(t.chain_id)??null,goal:u(t.goal)??null,run_id:u(t.run_id)??null,status:n,viewer_path:u(t.viewer_path)??null,last_sync_at:u(t.last_sync_at)??null}}function Za(t){if(!k(t))return null;const e=u(t.operation_id),n=u(t.objective),a=u(t.assigned_unit_id),s=u(t.trace_id),o=u(t.status);return!e||!n||!a||!s||!o?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:u(t.autonomy_level),policy_class:u(t.policy_class),budget_class:u(t.budget_class),detachment_session_id:u(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:u(t.checkpoint_ref)??null,active_goal_ids:vt(t.active_goal_ids),note:u(t.note)??null,created_by:u(t.created_by),source:u(t.source),status:o,chain:uu(t.chain),created_at:u(t.created_at),updated_at:u(t.updated_at)}}function pu(t){if(!k(t))return null;const e=Za(t.operation);return e?{operation:e,assigned_unit_label:u(t.assigned_unit_label)}:null}function en(t){if(k(t))return{tone:u(t.tone),pending_ops:$(t.pending_ops),blocked_ops:$(t.blocked_ops),in_flight_ops:$(t.in_flight_ops),pipeline_stalls:$(t.pipeline_stalls),bus_traffic:$(t.bus_traffic),l1_hit_rate:$(t.l1_hit_rate),invalidation_count:$(t.invalidation_count),current_pending:$(t.current_pending),current_in_flight:$(t.current_in_flight),cdb_wakeups:$(t.cdb_wakeups),total_stolen:$(t.total_stolen),avg_best_score:$(t.avg_best_score),avg_candidate_count:$(t.avg_candidate_count),best_first_operations:$(t.best_first_operations),active_sessions:$(t.active_sessions),commit_rate:$(t.commit_rate),total_speculations:$(t.total_speculations)}}function mu(t){if(!k(t))return;const e=k(t.pipeline)?t.pipeline:void 0,n=k(t.cache)?t.cache:void 0,a=k(t.ooo)?t.ooo:void 0,s=k(t.speculative)?t.speculative:void 0,o=k(t.search_fabric)?t.search_fabric:void 0,r=k(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:$(e.total_ops),completed_ops:$(e.completed_ops),stalled_cycles:$(e.stalled_cycles),hazards_detected:$(e.hazards_detected),forwarding_used:$(e.forwarding_used),pipeline_flushes:$(e.pipeline_flushes),ipc:$(e.ipc)}:void 0,cache:n?{total_reads:$(n.total_reads),total_writes:$(n.total_writes),l1_hit_rate:$(n.l1_hit_rate),invalidation_count:$(n.invalidation_count),writeback_count:$(n.writeback_count),bus_traffic:$(n.bus_traffic)}:void 0,ooo:a?{agent_count:$(a.agent_count),total_added:$(a.total_added),total_issued:$(a.total_issued),total_completed:$(a.total_completed),total_stolen:$(a.total_stolen),cdb_wakeups:$(a.cdb_wakeups),stall_cycles:$(a.stall_cycles),global_cdb_events:$(a.global_cdb_events),current_pending:$(a.current_pending),current_in_flight:$(a.current_in_flight)}:void 0,speculative:s?{total_speculations:$(s.total_speculations),total_commits:$(s.total_commits),total_aborts:$(s.total_aborts),commit_rate:$(s.commit_rate),total_fast_calls:$(s.total_fast_calls),total_cost_usd:$(s.total_cost_usd),active_sessions:$(s.active_sessions)}:void 0,search_fabric:o?{total_operations:$(o.total_operations),best_first_operations:$(o.best_first_operations),legacy_operations:$(o.legacy_operations),blocked_operations:$(o.blocked_operations),ready_operations:$(o.ready_operations),research_pipeline_operations:$(o.research_pipeline_operations),avg_candidate_count:$(o.avg_candidate_count),avg_best_score:$(o.avg_best_score),top_stage:u(o.top_stage)??null}:void 0,signals:r?{issue_pressure:en(r.issue_pressure),cache_contention:en(r.cache_contention),scheduler_efficiency:en(r.scheduler_efficiency),routing_confidence:en(r.routing_confidence),speculative_posture:en(r.speculative_posture)}:void 0}}function hr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:$(n.total),active:$(n.active),paused:$(n.paused),managed:$(n.managed),projected:$(n.projected)}:void 0,microarch:mu(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(pu).filter(a=>a!==null):[]}}function yr(t){if(!k(t))return null;const e=u(t.detachment_id),n=u(t.operation_id),a=u(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:u(t.leader_id)??null,roster:vt(t.roster),session_id:u(t.session_id)??null,checkpoint_ref:u(t.checkpoint_ref)??null,runtime_kind:u(t.runtime_kind)??null,runtime_ref:u(t.runtime_ref)??null,source:u(t.source),status:u(t.status),last_event_at:u(t.last_event_at)??null,last_progress_at:u(t.last_progress_at)??null,heartbeat_deadline:u(t.heartbeat_deadline)??null,created_at:u(t.created_at),updated_at:u(t.updated_at)}}function vu(t){if(!k(t))return null;const e=yr(t.detachment);return e?{detachment:e,assigned_unit_label:u(t.assigned_unit_label),operation:Za(t.operation)}:null}function br(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:$(n.total),active:$(n.active),projected:$(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(vu).filter(a=>a!==null):[]}}function fu(t){if(!k(t))return null;const e=u(t.decision_id),n=u(t.trace_id),a=u(t.requested_action),s=u(t.scope_type),o=u(t.scope_id);return!e||!n||!a||!s||!o?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:o,operation_id:u(t.operation_id)??null,target_unit_id:u(t.target_unit_id)??null,requested_by:u(t.requested_by),status:u(t.status),reason:u(t.reason)??null,source:u(t.source),detail:t.detail,created_at:u(t.created_at),decided_at:u(t.decided_at)??null,expires_at:u(t.expires_at)??null}}function kr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:$(n.total),pending:$(n.pending),approved:$(n.approved),denied:$(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(fu).filter(a=>a!==null):[]}}function _u(t){if(!k(t))return null;const e=Di(t.unit);return e?{unit:e,roster_total:$(t.roster_total),roster_live:$(t.roster_live),headcount_cap:$(t.headcount_cap),active_operations:$(t.active_operations),active_operation_cap:$(t.active_operation_cap),utilization:$(t.utilization)}:null}function gu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(_u).filter(n=>n!==null):[]}}function $u(t){if(!k(t))return null;const e=u(t.alert_id);return e?{alert_id:e,severity:u(t.severity),kind:u(t.kind),scope_type:u(t.scope_type),scope_id:u(t.scope_id),title:u(t.title),detail:u(t.detail),timestamp:u(t.timestamp)}:null}function xr(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),summary:n?{total:$(n.total),bad:$(n.bad),warn:$(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map($u).filter(a=>a!==null):[]}}function Sr(t){if(!k(t))return null;const e=u(t.event_id),n=u(t.trace_id),a=u(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:u(t.operation_id)??null,unit_id:u(t.unit_id)??null,actor:u(t.actor)??null,source:u(t.source),timestamp:u(t.timestamp),detail:t.detail}}function hu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),events:Array.isArray(e.events)?e.events.map(Sr).filter(n=>n!==null):[]}}function yu(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function bu(t){if(!k(t))return null;const e=u(t.lane_id),n=u(t.label),a=u(t.kind),s=u(t.phase),o=u(t.motion_state),r=u(t.source_of_truth),l=u(t.movement_reason),p=u(t.current_step);if(!e||!n||!a||!s||!o||!r||!l||!p)return null;const f=k(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:Q(t.present)??!1,phase:s,motion_state:o,source_of_truth:r,last_movement_at:u(t.last_movement_at)??null,movement_reason:l,current_step:p,blockers:vt(t.blockers),counts:{operations:$(f.operations),detachments:$(f.detachments),workers:$(f.workers),approvals:$(f.approvals),alerts:$(f.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(yu).filter(m=>m!==null):[]}}function ku(t){if(!k(t))return null;const e=u(t.event_id),n=u(t.lane_id),a=u(t.kind),s=u(t.timestamp),o=u(t.title),r=u(t.detail),l=u(t.tone),p=u(t.source);return!e||!n||!a||!s||!o||!r||!l||!p?null:{event_id:e,lane_id:n,kind:a,timestamp:s,title:o,detail:r,tone:l,source:p}}function xu(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:vt(t.lane_ids),count:$(t.count)??0}}function Ar(t){if(!k(t))return;const e=k(t.overview)?t.overview:{},n=k(t.gaps)?t.gaps:{},a=k(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:u(t.generated_at),overview:{active_lanes:$(e.active_lanes),moving_lanes:$(e.moving_lanes),stalled_lanes:$(e.stalled_lanes),projected_lanes:$(e.projected_lanes),last_movement_at:u(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(bu).filter(s=>s!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(ku).filter(s=>s!==null):[],gaps:{count:$(n.count),items:Array.isArray(n.items)?n.items.map(xu).filter(s=>s!==null):[]},recommended_next_action:a?{tool:u(a.tool)??"masc_operator_snapshot",label:u(a.label)??"Observe operator state",reason:u(a.reason)??"",lane_id:u(a.lane_id)??null}:void 0}}function Su(t){if(!k(t))return;const e=k(t.workers)?t.workers:{},n=Q(t.pass);return{status:u(t.status)??"missing",source:u(t.source)??"none",run_id:u(t.run_id)??null,captured_at:u(t.captured_at)??null,...n!==void 0?{pass:n}:{},...$(t.peak_hot_slots)!=null?{peak_hot_slots:$(t.peak_hot_slots)}:{},...$(t.ctx_per_slot)!=null?{ctx_per_slot:$(t.ctx_per_slot)}:{},workers:{expected:$(e.expected),joined:$(e.joined),current_task_bound:$(e.current_task_bound),fresh_heartbeats:$(e.fresh_heartbeats),done:$(e.done),final:$(e.final)},artifact_ref:u(t.artifact_ref)??null,missing_reason:u(t.missing_reason)??null}}function Au(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),topology:$r(e.topology),operations:hr(e.operations),detachments:br(e.detachments),alerts:xr(e.alerts),decisions:kr(e.decisions),capacity:gu(e.capacity),traces:hu(e.traces),swarm_status:Ar(e.swarm_status)}}function wu(t){const e=k(t)?t:{},n=$r(e.topology),a=hr(e.operations),s=br(e.detachments),o=xr(e.alerts),r=kr(e.decisions);return{version:u(e.version),generated_at:u(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:s.version,generated_at:s.generated_at,summary:s.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Ar(e.swarm_status),swarm_proof:Su(e.swarm_proof)}}function Cu(t){return k(t)?{chain_id:u(t.chain_id)??null,started_at:$(t.started_at)??null,progress:$(t.progress)??null,elapsed_sec:$(t.elapsed_sec)??null}:null}function wr(t){if(!k(t))return null;const e=u(t.event);return e?{event:e,chain_id:u(t.chain_id)??null,timestamp:u(t.timestamp)??null,duration_ms:$(t.duration_ms)??null,message:u(t.message)??null,tokens:$(t.tokens)??null}:null}function Tu(t){if(!k(t))return null;const e=Za(t.operation);return e?{operation:e,runtime:Cu(t.runtime),history:wr(t.history),mermaid:u(t.mermaid)??null,preview_run:Cr(t.preview_run)}:null}function Nu(t){const e=k(t)?t:{};return{status:u(e.status)??"disconnected",base_url:u(e.base_url)??null,message:u(e.message)??null}}function Ru(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),connection:Nu(e.connection),summary:n?{linked_operations:$(n.linked_operations),active_chains:$(n.active_chains),running_operations:$(n.running_operations),recent_failures:$(n.recent_failures),last_history_event_at:u(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Tu).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(wr).filter(a=>a!==null):[]}}function Lu(t){if(!k(t))return null;const e=u(t.id);return e?{id:e,type:u(t.type),status:u(t.status),duration_ms:$(t.duration_ms)??null,error:u(t.error)??null}:null}function Cr(t){if(!k(t))return null;const e=u(t.run_id),n=u(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:$(t.duration_ms),success:Q(t.success),mermaid:u(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Lu).filter(a=>a!==null):[]}:null}function Pu(t){const e=k(t)?t:{};return{run:Cr(e.run)}}function Du(t){if(!k(t))return null;const e=u(t.title),n=u(t.path);return!e||!n?null:{title:e,path:n}}function Mu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function Eu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.tool),s=u(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:vt(t.success_signals),pitfalls:vt(t.pitfalls)}}function Iu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.summary),s=u(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(Eu).filter(o=>o!==null):[]}}function Ou(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:vt(t.tools)}}function zu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.symptom),s=u(t.why),o=u(t.fix_tool),r=u(t.fix_summary);return!e||!n||!a||!s||!o||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:o,fix_summary:r}}function ju(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.path_id),s=u(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:vt(t.notes)}}function qu(t){const e=k(t)?t:{};return{version:u(e.version),generated_at:u(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Du).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Mu).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Iu).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Ou).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(zu).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(ju).filter(n=>n!==null):[]}}function Fu(t){if(!k(t))return null;const e=u(t.id),n=u(t.title),a=u(t.status),s=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!s||!o?null:{id:e,title:n,status:a,detail:s,next_tool:o}}function Ku(t){if(!k(t))return null;const e=u(t.code),n=u(t.severity),a=u(t.title),s=u(t.detail),o=u(t.next_tool);return!e||!n||!a||!s||!o?null:{code:e,severity:n,title:a,detail:s,next_tool:o}}function Hu(t){if(!k(t))return null;const e=u(t.from),n=u(t.content),a=u(t.timestamp),s=$(t.seq);return!e||!n||!a||s==null?null:{seq:s,from:e,content:n,timestamp:a}}function Uu(t){if(!k(t))return null;const e=u(t.name),n=u(t.role),a=u(t.lane),s=u(t.status),o=u(t.claim_marker),r=u(t.done_marker),l=u(t.final_marker);if(!e||!n||!a||!s||!o||!r||!l)return null;const p=(()=>{if(!k(t.last_message))return null;const f=$(t.last_message.seq),m=u(t.last_message.content),d=u(t.last_message.timestamp);return f==null||!m||!d?null:{seq:f,content:m,timestamp:d}})();return{name:e,role:n,lane:a,joined:Q(t.joined)??!1,live_presence:Q(t.live_presence)??!1,completed:Q(t.completed)??!1,status:s,current_task:u(t.current_task)??null,bound_task_id:u(t.bound_task_id)??null,bound_task_title:u(t.bound_task_title)??null,bound_task_status:u(t.bound_task_status)??null,current_task_matches_run:Q(t.current_task_matches_run)??!1,squad_member:Q(t.squad_member)??!1,detachment_member:Q(t.detachment_member)??!1,last_seen:u(t.last_seen)??null,heartbeat_age_sec:$(t.heartbeat_age_sec)??null,heartbeat_fresh:Q(t.heartbeat_fresh)??!1,claim_marker_seen:Q(t.claim_marker_seen)??!1,done_marker_seen:Q(t.done_marker_seen)??!1,final_marker_seen:Q(t.final_marker_seen)??!1,claim_marker:o,done_marker:r,final_marker:l,last_message:p}}function Bu(t){if(!k(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!k(n))return null;const a=u(n.timestamp),s=$(n.active_slots);if(!a||s==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:s,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:u(t.slot_url)??null,provider_base_url:u(t.provider_base_url)??null,provider_reachable:Q(t.provider_reachable)??null,provider_status_code:$(t.provider_status_code)??null,provider_model_id:u(t.provider_model_id)??null,actual_model_id:u(t.actual_model_id)??null,expected_slots:$(t.expected_slots),actual_slots:$(t.actual_slots),expected_ctx:$(t.expected_ctx),actual_ctx:$(t.actual_ctx),slot_reachable:Q(t.slot_reachable)??null,slot_status_code:$(t.slot_status_code)??null,runtime_blocker:u(t.runtime_blocker)??null,detail:u(t.detail)??null,checked_at:u(t.checked_at)??null,total_slots:$(t.total_slots),ctx_per_slot:$(t.ctx_per_slot),active_slots_now:$(t.active_slots_now),peak_active_slots:$(t.peak_active_slots),sample_count:$(t.sample_count),last_sample_at:u(t.last_sample_at)??null,timeline:e}}function Wu(t){const e=k(t)?t:{},n=k(e.summary)?e.summary:void 0;return{version:u(e.version),generated_at:u(e.generated_at),run_id:u(e.run_id),room_id:u(e.room_id),operation_id:u(e.operation_id)??null,recommended_next_tool:u(e.recommended_next_tool),summary:n?{expected_workers:$(n.expected_workers),joined_workers:$(n.joined_workers),live_workers:$(n.live_workers),squad_roster_size:$(n.squad_roster_size),detachment_roster_size:$(n.detachment_roster_size),current_task_bound:$(n.current_task_bound),fresh_heartbeats:$(n.fresh_heartbeats),claim_markers_seen:$(n.claim_markers_seen),done_markers_seen:$(n.done_markers_seen),final_markers_seen:$(n.final_markers_seen),completed_workers:$(n.completed_workers),peak_hot_slots:$(n.peak_hot_slots),hot_window_ok:Q(n.hot_window_ok),pass_hot_concurrency:Q(n.pass_hot_concurrency),pass_end_to_end:Q(n.pass_end_to_end),pending_decisions:$(n.pending_decisions),pass:Q(n.pass)}:void 0,provider:Bu(e.provider),operation:Za(e.operation),squad:Di(e.squad),detachment:yr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Uu).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Fu).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Ku).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Hu).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Sr).filter(a=>a!==null):[],truth_notes:vt(e.truth_notes)}}function Ra(t){$e.value=t,Pi(t)&&Gu()}async function Mi(){ba.value=!0,xa.value=null;try{const t=await Ml();fr.value=wu(t)}catch(t){xa.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ba.value=!1}}function Ei(t){ze.value=t}async function Ii(){ka.value=!0,Sa.value=null;try{const t=await Dl();Ht.value=Au(t)}catch(t){Sa.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ka.value=!1}}async function Gu(){Ht.value||ka.value||await Ii()}async function je(){await Mi(),Pi($e.value)&&await Ii()}async function he(){var t;si.value=!0,Ta.value=null;try{const e=await El(),n=Ru(e);Li.value=n;const a=ze.value;n.operations.length===0?ze.value=null:(!a||!n.operations.some(s=>s.operation.operation_id===a))&&(ze.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ta.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{si.value=!1}}function Ju(){on=null,Pn.value=null,Na.value=!1,Dn.value=null}async function Vu(t){on=t,Na.value=!0,Dn.value=null;try{const e=await Il(t);if(on!==t)return;Pn.value=Pu(e)}catch(e){if(on!==t)return;Pn.value=null,Dn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{on===t&&(Na.value=!1)}}async function Qu(){ni.value=!0,wa.value=null;try{const t=await Ol();jn.value=qu(t)}catch(t){wa.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{ni.value=!1}}async function Tr(t=ru()){ai.value=!0,Ca.value=null;try{const e=await zl(t);_r.value=Wu(e)}catch(e){Ca.value=e instanceof Error?e.message:"Failed to load command-plane swarm view"}finally{ai.value=!1}}async function ie(t,e,n){ei.value=t,Aa.value=null;try{await jl(e,n),await Mi(),(Ht.value||Pi($e.value))&&await Ii(),await Tr(),await he()}catch(a){throw Aa.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{ei.value=null}}function Yu(t){return ie(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Xu(t){return ie(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Zu(t){return ie(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function tp(t={}){return ie("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function ep(t){return ie(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function np(t){return ie(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function ap(t,e){return ie(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function sp(t,e){return ie(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}md(()=>{Mi()});function ip(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function X(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function op(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function rp(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function j(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let po=!1,lp=0,fs=null;async function cp(){fs||(fs=ou(()=>import("./mermaid.core-Ct0eORCv.js").then(e=>e.bE),[]).then(e=>e.default));const t=await fs;return po||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),po=!0),t}function Zt(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function ts(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function dp(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function qn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ue(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:qn(t/e*100)}function up(t,e){const n=qn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Nr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Rr=[{id:"summary",label:"요약"},{id:"swarm",label:"스웜"},{id:"operations",label:"작전"},{id:"chains",label:"체인"},{id:"topology",label:"토폴로지"},{id:"alerts",label:"알림"},{id:"trace",label:"트레이스"},{id:"control",label:"제어"}],pp=Rr.map(t=>t.id),mp=["chain_start","node_start","node_complete","chain_complete","chain_error"];function vp(t){return!!t&&pp.includes(t)}function fp(t){if(t==="summary")return{};if(t==="chains"){const e=ze.value;return e?{surface:t,operation:e}:{surface:t}}return{surface:t}}function _p(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function gp(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function rt(t){return ei.value===t}function es(){return fr.value}function Bn({label:t,value:e,subtext:n,percent:a,color:s}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${up(a,s)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(qn(a))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Wn({label:t,value:e,detail:n,percent:a,tone:s}){return i`
    <article class="command-signal-rail ${j(s)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${j(s)}" style=${`width: ${Math.max(8,Math.round(qn(a)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function $p(){var nt,at,U,I;const t=es(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.detachments.summary,s=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,r=(nt=t==null?void 0:t.swarm_status)==null?void 0:nt.overview,l=t==null?void 0:t.swarm_proof,p=t==null?void 0:t.operations.microarch,f=(e==null?void 0:e.managed_unit_count)??0,m=(e==null?void 0:e.total_units)??0,d=(n==null?void 0:n.active)??0,v=(a==null?void 0:a.active)??0,c=(r==null?void 0:r.moving_lanes)??0,y=(r==null?void 0:r.active_lanes)??0,x=(l==null?void 0:l.workers.done)??0,T=(l==null?void 0:l.workers.expected)??0,L=(o==null?void 0:o.bad)??0,z=(o==null?void 0:o.warn)??0,P=(s==null?void 0:s.pending)??0,N=(s==null?void 0:s.total)??0,R=d+v,G=((at=p==null?void 0:p.cache)==null?void 0:at.l1_hit_rate)??((I=(U=p==null?void 0:p.signals)==null?void 0:U.cache_contention)==null?void 0:I.l1_hit_rate)??0,H=d>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",kt=d>0||c>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${H}</h3>
        <p>${kt}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${j(d>0?"ok":"warn")}">활성 작전 ${d}</span>
          <span class="command-chip ${j(c>0?"ok":(y>0,"warn"))}">이동 레인 ${c}/${Math.max(y,c)}</span>
          <span class="command-chip ${j(L>0?"bad":z>0?"warn":"ok")}">치명 알림 ${L}</span>
          <span class="command-chip ${j(P>0?"warn":"ok")}">승인 대기 ${P}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Bn}
          label="관리 단위 범위"
          value=${`${f}/${Math.max(m,f)}`}
          subtext=${m>0?`${m-f}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ue(f,Math.max(m,f))}
          color="#67e8f9"
        />
        <${Bn}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${d}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ue(R,Math.max(f,R||1))}
          color="#4ade80"
        />
        <${Bn}
          label="스웜 이동감"
          value=${`${c}/${Math.max(y,c)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${X(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ue(c,Math.max(y,c||1))}
          color="#fbbf24"
        />
        <${Bn}
          label="증거 수집률"
          value=${`${x}/${Math.max(T,x)}`}
          subtext=${l!=null&&l.status?`증거 소스 ${l.source} · ${l.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ue(x,Math.max(T,x||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Wn}
        label="승인 대기열"
        value=${`${P}건 대기`}
        detail=${`현재 정책 창에서 ${N}개 결정을 추적 중입니다`}
        percent=${ue(P,Math.max(N,P||1))}
        tone=${P>0?"warn":"ok"}
      />
      <${Wn}
        label="알림 압력"
        value=${`${L} bad / ${z} warn`}
        detail=${L>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ue(L*2+z,Math.max((L+z)*2,1))}
        tone=${L>0?"bad":z>0?"warn":"ok"}
      />
      <${Wn}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${f>0?`${f}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ue(v,Math.max(f,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${Wn}
        label="캐시 신뢰도"
        value=${G?ts(G):"n/a"}
        detail=${G?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${qn((G??0)*100)}
        tone=${G>=.75?"ok":G>=.4?"warn":"bad"}
      />
    </div>
  `}function hp(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function yp(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function bp(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function kp(t){return t.status==="claimed"||t.status==="in_progress"}function xp(t){const e=jn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function _s(t){var e;return((e=jn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Sp(t){const e=jn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function te(t){try{await t()}catch{}}function Ap(){var m,d,v,c,y;const t=es(),e=Li.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,s=(m=t==null?void 0:t.swarm_status)==null?void 0:m.overview,o=t==null?void 0:t.operations.microarch,r=t==null?void 0:t.decisions.summary,l=t==null?void 0:t.alerts.summary,p=(d=o==null?void 0:o.signals)==null?void 0:d.issue_pressure,f=o==null?void 0:o.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(a==null?void 0:a.active)??0}</strong><small>${((v=t==null?void 0:t.detachments.summary)==null?void 0:v.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(r==null?void 0:r.pending)??0}</strong><small>${(r==null?void 0:r.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card"><span>알림</span><strong>${(l==null?void 0:l.bad)??0}</strong><small>${(l==null?void 0:l.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((c=e==null?void 0:e.summary)==null?void 0:c.active_chains)??0}</strong><small>${((y=e==null?void 0:e.summary)==null?void 0:y.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card"><span>스웜</span><strong>${(s==null?void 0:s.active_lanes)??0}</strong><small>${s?`${s.stalled_lanes??0}개 정체 · ${X(s.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${ts(f.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"n/a"}</small></div>
    </div>
  `}function Lr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function wp({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const s of t){const o=s.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const a=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function Cp({total:t}){const n=Math.min(t,20),a=t>20?t-20:0,s=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${s.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${a>0?i`<span class="swarm-worker-count">+${a}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Tp({lane:t}){const e=t.counts??{},n=Lr(t),a=e.workers??0,s=e.operations??0,o=e.detachments??0,r=s+o,l=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${j(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${j(n)}">${t.phase}</span>
          <span class="command-chip ${j(n)}">${t.motion_state}</span>
          <span class="command-chip">${X(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${j(n)}" style=${`width:${l}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${a>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Cp} total=${a} />
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
              ${t.hard_flags.map(p=>i`<span class="command-chip ${j(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Np({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const a=Lr(n),s=n.counts.workers??0,o=n.counts.operations??0,r=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${j(a)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${j(a)}">${n.motion_state}</span>
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
  `}function Rp({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,a=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${j(t.tone)}"></span>
      <span class="swarm-event-time">${a}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Lp({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${j(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Pp({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${j(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${j(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${X(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Dp(){const t=es(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(f=>f.present))??[],s=(e==null?void 0:e.gaps.items)??[],o=(e==null?void 0:e.timeline.slice(0,8))??[],r=e==null?void 0:e.overview,l=e==null?void 0:e.recommended_next_action,p=a.length<=1;return i`
    <section class="card command-section">
      <div class="card-title">스웜</div>
      ${e?i`
            <${Np} lanes=${a} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${X(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`스냅샷 ${X(e.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(l==null?void 0:l.label)??"운영자 상태 확인"}</strong><small>${(l==null?void 0:l.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${a.length>0?i`<${wp} lanes=${a} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${a.length>0?a.map(f=>i`<${Tp} lane=${f} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Pp} proof=${n} />

                <div class="command-guide-card ${s.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${j(s.some(f=>f.severity==="bad")?"bad":s.length>0?"warn":"ok")}">${s.length}</span>
                  </div>
                  ${s.length>0?i`<div class="swarm-event-rail">${s.slice(0,4).map(f=>i`<${Lp} gap=${f} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${o.length}</span>
                  </div>
                  ${o.length>0?i`<div class="swarm-event-rail">${o.map(f=>i`<${Rp} event=${f} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Mp(){return i`
    <div class="command-surface-tabs">
      ${Rr.map(t=>i`
        <button
          class="command-surface-tab ${$e.value===t.id?"active":""}"
          onClick=${()=>{Ra(t.id),wt("command",fp(t.id))}}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function Ep(){var nt,at,U,I,S,Dt,Vt,oe,re;const t=es(),e=Ht.value,n=se.value,a=hp(),s=a?Ct.value.find(E=>E.name===a)??null:null,o=a?yt.value.filter(E=>E.assignee===a&&kp(E)):[],r=((nt=t==null?void 0:t.operations.summary)==null?void 0:nt.active)??0,l=((at=t==null?void 0:t.detachments.summary)==null?void 0:at.total)??0,p=((U=t==null?void 0:t.decisions.summary)==null?void 0:U.pending)??0,f=e==null?void 0:e.detachments.detachments.find(E=>{const Mt=E.detachment.heartbeat_deadline,le=Mt?Date.parse(Mt):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(le)&&le<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),d=!!(n!=null&&n.room||n!=null&&n.project),v=(s==null?void 0:s.current_task)??null,c=bp(s==null?void 0:s.last_seen),y=c!=null?c<=120:null,x=[d?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},a?s?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${a} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:yt.value.length>0?"masc_claim":"masc_add_task"}:v?y===!1?{title:"Task 준비도",tone:"warn",detail:`${a} current_task=${v} 이지만 heartbeat가 stale 합니다 (${c}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${a} current_task=${v}${c!=null?` · 마지막 활동 ${c}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((I=t.topology.summary)==null?void 0:I.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((S=t.topology.summary)==null?void 0:S.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Dt=t.topology.summary)==null?void 0:Dt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&l===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:f||m?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${f?` · detachment ${f.detachment.detachment_id} 가 stalled 상태입니다`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!f&&!m?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${l}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],T=d?!a||!s?"masc_join":o.length===0?yt.value.length>0?"masc_claim":"masc_add_task":v?y===!1?"masc_heartbeat":!t||(((Vt=t.topology.summary)==null?void 0:Vt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":p>0?"masc_policy_approve":r>0&&l===0||f||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",L=xp(T),P=Sp(T==="masc_set_room"?["repo-root-room"]:T==="masc_plan_set_task"?["claimed-not-current"]:T==="masc_heartbeat"?["heartbeat-stale"]:T==="masc_dispatch_tick"?["no-detachments"]:T==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=_s("room_task_hygiene"),R=_s("cpv2_benchmark"),G=_s("supervisor_session"),H=((oe=jn.value)==null?void 0:oe.docs)??[],kt=[N,R,G].filter(E=>E!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title">즉시 조치</div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(L==null?void 0:L.title)??T}</strong>
            <span class="command-chip ok">${T}</span>
          </div>
          <p>${(L==null?void 0:L.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(re=L==null?void 0:L.success_signals)!=null&&re.length?i`<div class="command-tag-row">
                ${L.success_signals.map(E=>i`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${x.map(E=>i`
            <article class="command-readiness-row ${j(E.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${E.title}</strong>
                  <span class="command-chip ${j(E.tone)}">${E.tone}</span>
                </div>
                <p>${E.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>

        ${P.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${P.length}</span>
                </div>
                <div class="command-guide-list">
                  ${P.map(E=>i`
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
        ${ni.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:wa.value?i`<div class="empty-state error">${wa.value}</div>`:i`
                <div class="command-path-grid">
                  ${kt.map(E=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${E.steps.slice(0,4).map(Mt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Mt.tool}</span>
                            <span>${Mt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${H.length>0?i`<div class="command-doc-links">
                      ${H.map(E=>i`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Ip(){return i`
    <${$p} />
    <${Ap} />
    <${Ep} />
  `}function Op(){return ka.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Sa.value?i`<div class="empty-state error">${Sa.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Pr({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,o=t.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${gp(t.unit.kind)}</span>
            <span class="command-chip ${j(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>i`<${Pr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function zp({source:t}){const e=Po(null),[n,a]=Qa(null);return ct(()=>{let s=!1;const o=e.current;return o?(o.innerHTML="",a(null),(async()=>{try{const l=await cp(),{svg:p}=await l.render(`command-chain-${++lp}`,t);if(s||!e.current)return;e.current.innerHTML=p}catch(l){if(s)return;a(l instanceof Error?l.message:"Mermaid render failed")}})(),()=>{s=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function jp({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,s=t.runtime;return i`
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
        ${s?i`<span class="command-tag ${Zt(a==null?void 0:a.status)}">${ts(s.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Nr(t.history)}</div>
    </button>
  `}function qp({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Zt(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${X(t.timestamp)}</div>
      <div class="command-card-sub">${Nr(t)}</div>
    </article>
  `}function Fp({node:t}){return i`
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
  `}function Kp({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`,o=e.chain;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${j(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${X(e.updated_at)}</span>
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
                onClick=${()=>{Ei(e.operation_id),Ra("chains"),wt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${rt(n)} onClick=${()=>te(()=>Yu(e.operation_id))}>
                ${rt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${rt(s)} onClick=${()=>te(()=>Zu(e.operation_id))}>
                ${rt(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${rt(a)} onClick=${()=>te(()=>Xu(e.operation_id))}>
                ${rt(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Hp({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${j(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${X(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${rp(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${X(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${op(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Up({alert:t}){return i`
    <article class="command-alert ${j(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${j(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${X(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Dr({event:t}){return i`
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
      <pre class="command-trace-detail">${ip(t.detail)}</pre>
    </article>
  `}function Bp({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return i`
    <article class="command-card ${j(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${j(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${X(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${rt(e)} onClick=${()=>te(()=>ep(t.decision_id))}>
                ${rt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${rt(n)} onClick=${()=>te(()=>np(t.decision_id))}>
                ${rt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Wp({row:t}){var l,p,f;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((l=e.policy)!=null&&l.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),r=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${j(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
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
        <button class="control-btn ghost" disabled=${rt(n)} onClick=${()=>te(()=>ap(e.unit_id,!s))}>
          ${rt(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${rt(a)} onClick=${()=>te(()=>sp(e.unit_id,!o))}>
          ${rt(a)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Gp({item:t}){return i`
    <article class="command-guide-card ${j(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${j(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Jp({blocker:t}){return i`
    <article class="command-alert ${j(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${j(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Vp({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${j(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${X(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Qp(){var l,p,f,m,d,v,c,y,x,T,L,z,P,N,R,G,H,kt,nt,at,U;const t=_r.value,e=yp(),n=(l=t==null?void 0:t.provider)!=null&&l.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=((f=t==null?void 0:t.provider)==null?void 0:f.actual_slots)??((m=t==null?void 0:t.provider)==null?void 0:m.total_slots)??0,s=((d=t==null?void 0:t.provider)==null?void 0:d.expected_slots)??"n/a",o=((v=t==null?void 0:t.provider)==null?void 0:v.actual_ctx)??((c=t==null?void 0:t.provider)==null?void 0:c.ctx_per_slot)??0,r=((y=t==null?void 0:t.provider)==null?void 0:y.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Dp} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title">스웜 라이브 런</div>
          ${ai.value?i`<div class="empty-state">Loading swarm live state…</div>`:Ca.value?i`<div class="empty-state error">${Ca.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((x=t.summary)==null?void 0:x.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((L=t.summary)==null?void 0:L.live_workers)??0}개 가동 · ${((z=t.summary)==null?void 0:z.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${n}</strong><small>slots ${a}/${s} · ctx ${o}/${r}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(P=t.summary)!=null&&P.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(R=t.summary)!=null&&R.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((G=t.operation)==null?void 0:G.operation_id)??"없음"}</span>
                      <span>분대</span><span>${((H=t.squad)==null?void 0:H.label)??"없음"}</span>
                      <span>실행체</span><span>${((kt=t.detachment)==null?void 0:kt.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((nt=t.summary)==null?void 0:nt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((at=t.summary)==null?void 0:at.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((U=t.provider)==null?void 0:U.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(I=>i`<span class="command-tag">${I}</span>`)}
                        </div>`:null}
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">체크리스트</div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(I=>i`<${Gp} item=${I} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">워커</div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(I=>i`<${Vp} worker=${I} />`)}
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?X(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?X(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(I=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${I.active_slots} active</strong>
                              <span class="command-chip">${X(I.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${I.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">막힘 요인</div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(I=>i`<${Jp} blocker=${I} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 메시지</div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(I=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${I.from}</strong>
                        <span class="command-chip">${X(I.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${I.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${I.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title">최근 트레이스 이벤트</div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(I=>i`<${Dr} event=${I} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Yp(){const t=Ht.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${Kp} card=${e} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${Hp} card=${e} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Xp(){var l,p,f,m,d,v,c,y,x,T,L,z,P,N,R,G;const t=Li.value,e=(t==null?void 0:t.operations)??[],n=ze.value,a=e.find(H=>H.operation.operation_id===n)??e[0]??null,s=((l=a==null?void 0:a.operation.chain)==null?void 0:l.run_id)??null,o=((p=Pn.value)==null?void 0:p.run)??(a==null?void 0:a.preview_run)??null,r=!((f=Pn.value)!=null&&f.run)&&!!(a!=null&&a.preview_run);return ct(()=>{s?Vu(s):Ju()},[s]),i`
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
            <span>Last Event</span><span>${X((c=t==null?void 0:t.summary)==null?void 0:c.last_history_event_at)}</span>
          </div>
        </article>

        ${Ta.value?i`<div class="empty-state error">${Ta.value}</div>`:null}

        ${si.value&&!t?i`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(H=>i`
                    <${jp}
                      overlay=${H}
                      selected=${(a==null?void 0:a.operation.operation_id)===H.operation.operation_id}
                      onSelect=${()=>Ei(H.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(H=>i`<${qp} item=${H} />`)}
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
                    ${((x=a.operation.chain)==null?void 0:x.status)??a.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((T=a.operation.chain)==null?void 0:T.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((L=a.operation.chain)==null?void 0:L.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${s??"not materialized"}</span>
                  <span>Progress</span><span>${ts((z=a.runtime)==null?void 0:z.progress)}</span>
                  <span>Elapsed</span><span>${dp((P=a.runtime)==null?void 0:P.elapsed_sec)}</span>
                  <span>Updated</span><span>${X(((N=a.operation.chain)==null?void 0:N.last_sync_at)??a.operation.updated_at)}</span>
                </div>
                ${(R=a.operation.chain)!=null&&R.goal?i`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((G=a.operation.chain)==null?void 0:G.chain_id)??"graph"}</span>
                      </div>
                      <${zp} source=${a.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Na.value?i`<div class="empty-state">Loading run detail…</div>`:Dn.value?i`<div class="empty-state error">${Dn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${r?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(H=>i`<${Fp} node=${H} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Zp(){const t=Ht.value;return i`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(e=>i`<${Pr} node=${e} />`)}`:i`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `}function tm(){const t=Ht.value;return i`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Up} alert=${e} />`)}
          </div>`:i`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `}function em(){const t=Ht.value;return i`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Dr} event=${e} />`)}
          </div>`:i`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `}function nm(){const t=Ht.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Bp} decision=${e} />`)}
            </div>`:i`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${Wp} row=${e} />`)}
            </div>`:i`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `}function am(){if($e.value==="summary")return i`<${Ip} />`;if($e.value==="swarm")return i`<${Qp} />`;if(!Ht.value)return i`<${Op} />`;switch($e.value){case"chains":return i`<${Xp} />`;case"topology":return i`<${Zp} />`;case"alerts":return i`<${tm} />`;case"trace":return i`<${em} />`;case"control":return i`<${nm} />`;case"operations":default:return i`<${Yp} />`}}function sm(){return ct(()=>{je(),he(),Qu(),Tr()},[]),ct(()=>{if(st.value.tab!=="command")return;const t=st.value.params.surface,e=st.value.params.operation;vp(t)?Ra(t):t||Ra("summary"),e&&Ei(e)},[st.value.tab,st.value.params.surface,st.value.params.operation]),ct(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,je(),he()},250))},n=new EventSource(_p()),a=mp.map(s=>{const o=()=>e();return n.addEventListener(s,o),{type:s,handler:o}});return n.onerror=()=>{e()},()=>{a.forEach(({type:s,handler:o})=>{n.removeEventListener(s,o)}),n.close(),t&&window.clearTimeout(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면 / Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{te(()=>tp())}}
            disabled=${rt("dispatch:tick")}
          >
            ${rt("dispatch:tick")?"Reconciling…":"Run Tick"}
          </button>
          <button class="control-btn ghost" onClick=${()=>{je(),he()}} disabled=${ba.value}>
            ${ba.value?"Refreshing…":"Refresh"}
          </button>
        </div>
      </div>

      ${xa.value?i`<div class="empty-state error">${xa.value}</div>`:null}
      ${Aa.value?i`<div class="empty-state error">${Aa.value}</div>`:null}
      <${Mp} />
      <${am} />
    </section>
  `}const Fn=g(null),La=g(!1),ae=g(null),J=g(!1),Pa=g([]);let im=1;function V(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function M(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function $t(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Mr(t){return typeof t=="boolean"?t:void 0}function om(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Ne(t,e=[]){if(Array.isArray(t))return t;if(!V(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function rm(t){return V(t)?{id:M(t.id),seq:$t(t.seq),from:M(t.from)??M(t.from_agent)??"system",content:M(t.content)??"",timestamp:M(t.timestamp)??new Date().toISOString(),type:M(t.type)}:null}function lm(t){return V(t)?{room_id:M(t.room_id),current_room:M(t.current_room)??M(t.room),project:M(t.project),cluster:M(t.cluster),paused:Mr(t.paused),pause_reason:M(t.pause_reason)??null,paused_by:M(t.paused_by)??null,paused_at:M(t.paused_at)??null}:{}}function mo(t){if(!V(t))return;const e=Object.entries(t).map(([n,a])=>{const s=M(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function cm(t){if(!V(t))return null;const e=V(t.status)?t.status:void 0,n=V(t.summary)?t.summary:V(e==null?void 0:e.summary)?e.summary:void 0,a=V(t.session)?t.session:V(e==null?void 0:e.session)?e.session:void 0,s=M(t.session_id)??M(n==null?void 0:n.session_id)??M(a==null?void 0:a.session_id);if(!s)return null;const o=mo(t.report_paths)??mo(e==null?void 0:e.report_paths),r=Ne(t.recent_events,["events"]).filter(V);return{session_id:s,status:M(t.status)??M(n==null?void 0:n.status)??M(a==null?void 0:a.status),progress_pct:$t(t.progress_pct)??$t(n==null?void 0:n.progress_pct),elapsed_sec:$t(t.elapsed_sec)??$t(n==null?void 0:n.elapsed_sec),remaining_sec:$t(t.remaining_sec)??$t(n==null?void 0:n.remaining_sec),done_delta_total:$t(t.done_delta_total)??$t(n==null?void 0:n.done_delta_total),summary:n,team_health:V(t.team_health)?t.team_health:V(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:V(t.communication_metrics)?t.communication_metrics:V(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:V(t.orchestration_state)?t.orchestration_state:V(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:V(t.cascade_metrics)?t.cascade_metrics:V(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,session:a,recent_events:r}}function dm(t){if(!V(t))return null;const e=M(t.name);if(!e)return null;const n=V(t.context)?t.context:void 0;return{name:e,agent_name:M(t.agent_name),status:M(t.status),autonomy_level:M(t.autonomy_level),context_ratio:$t(t.context_ratio)??$t(n==null?void 0:n.context_ratio),generation:$t(t.generation),active_goal_ids:om(t.active_goal_ids),last_autonomous_action_at:M(t.last_autonomous_action_at)??null,last_turn_ago_s:$t(t.last_turn_ago_s),model:M(t.model)??M(t.active_model)??M(t.primary_model)}}function um(t){if(!V(t))return null;const e=M(t.confirm_token)??M(t.token);return e?{confirm_token:e,actor:M(t.actor),action_type:M(t.action_type),target_type:M(t.target_type),target_id:M(t.target_id)??null,delegated_tool:M(t.delegated_tool),created_at:M(t.created_at),preview:t.preview}:null}function pm(t){const e=V(t)?t:{};return{room:lm(e.room),sessions:Ne(e.sessions,["items","sessions"]).map(cm).filter(n=>n!==null),keepers:Ne(e.keepers,["items","keepers"]).map(dm).filter(n=>n!==null),recent_messages:Ne(e.recent_messages,["messages"]).map(rm).filter(n=>n!==null),pending_confirms:Ne(e.pending_confirms,["items","confirms"]).map(um).filter(n=>n!==null),available_actions:Ne(e.available_actions,["actions"]).filter(V).map(n=>({action_type:M(n.action_type)??"unknown",target_type:M(n.target_type)??"unknown",description:M(n.description),confirm_required:Mr(n.confirm_required)}))}}function Gn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function vo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Da(t){Pa.value=[{...t,id:im++,at:new Date().toISOString()},...Pa.value].slice(0,20)}function Er(t){return t.confirm_required?Gn(t.preview)||"Confirmation required":Gn(t.result)||Gn(t.executed_action)||Gn(t.delegated_tool_result)||t.status}async function Be(){La.value=!0,ae.value=null;try{const t=await Pl();Fn.value=pm(t)}catch(t){ae.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{La.value=!1}}async function mm(t){J.value=!0,ae.value=null;try{const e=await zn(t);return Da({actor:t.actor,action_type:t.action_type,target_label:vo(t),outcome:e.confirm_required?"preview":"executed",message:Er(e),delegated_tool:e.delegated_tool}),await Be(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw ae.value=n,Da({actor:t.actor,action_type:t.action_type,target_label:vo(t),outcome:"error",message:n}),e}finally{J.value=!1}}async function vm(t,e){J.value=!0,ae.value=null;try{const n=await Fl(t,e);return Da({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Er(n),delegated_tool:n.delegated_tool}),await Be(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw ae.value=a,Da({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{J.value=!1}}const Ir="masc_dashboard_agent_name";function fm(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Ir))==null?void 0:a.trim())||"dashboard"}const ns=g(fm()),un=g(""),ii=g("Operator pause"),pn=g(""),Ma=g(""),oi=g("2"),Ea=g(""),qe=g("note"),Ia=g(""),Oa=g(""),za=g(""),ri=g("2"),li=g("Operator stop request"),ci=g(""),mn=g("");function _m(t){const e=t.trim()||"dashboard";ns.value=e,localStorage.setItem(Ir,e)}function gs(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function gm(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function ja(t){return typeof t=="string"?t.trim().toLowerCase():""}function $m(t){var a;const e=ja(t.status);if(e==="paused")return"bad";const n=ja((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function fo(t){const e=ja(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function be(t){const e=ns.value.trim()||"dashboard";try{const n=await mm({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?w("Confirmation queued","warning"):w(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return w(a,"error"),null}}async function _o(){const t=un.value.trim();if(!t)return;await be({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(un.value="")}async function hm(){await be({action_type:"room_pause",target_type:"room",payload:{reason:ii.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function ym(){await be({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function bm(){const t=pn.value.trim();if(!t)return;await be({action_type:"task_inject",target_type:"room",payload:{title:t,description:Ma.value.trim()||"Injected from Ops tab",priority:Number.parseInt(oi.value,10)||2},successMessage:"Task injection submitted"})&&(pn.value="",Ma.value="")}async function km(){var o;const t=Fn.value,e=Ea.value||((o=t==null?void 0:t.sessions[0])==null?void 0:o.session_id)||"";if(!e){w("Select a team session first","warning");return}const n={turn_kind:qe.value},a=Ia.value.trim();a&&(n.message=a),qe.value==="task"&&(n.task_title=Oa.value.trim()||"Operator injected task",n.task_description=za.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(ri.value,10)||2),await be({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(Ia.value="",qe.value==="task"&&(Oa.value="",za.value=""))}async function xm(){var n;const t=Fn.value,e=Ea.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){w("Select a team session first","warning");return}await be({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:li.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function Sm(){var s;const t=Fn.value,e=ci.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=mn.value.trim();if(!e){w("Select a keeper first","warning");return}if(!n)return;await be({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(mn.value="")}async function go(t){const e=ns.value.trim()||"dashboard";try{await vm(e,t),w("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";w(a,"error")}}function Am(){var v;const t=Fn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],o=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===Ea.value)??n[0]??null,l=a.find(c=>c.name===ci.value)??a[0]??null,p=n.filter(c=>$m(c)!=="ok"),f=a.filter(c=>fo(c)!=="ok"),m=o.slice(0,5),d=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:p.length,detail:p.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:p.some(c=>ja(c.status)==="paused")?"bad":p.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:f.length,detail:f.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:f.some(c=>fo(c)==="bad")?"bad":f.length>0?"warn":"ok"}];return i`
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
            value=${ns.value}
            onInput=${c=>_m(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Be()}} disabled=${La.value||J.value}>
            ${La.value?"Refreshing...":"Refresh"}
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
                ${c.preview?i`<pre class="ops-code-block">${gs(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{go(c.confirm_token)}} disabled=${J.value}>
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
                    ${c.preview?i`<pre class="ops-code-block compact">${gs(c.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{go(c.confirm_token)}} disabled=${J.value}>
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
              ${Pa.value.length===0?i`
                <div class="ops-empty">No operator actions in this session yet.</div>
              `:Pa.value.map(c=>i`
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
                  onClick=${()=>{Ea.value=c.session_id}}
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
                  onClick=${()=>{ci.value=c.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${c.name}</strong>
                    <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${c.model??"model n/a"}</span>
                    <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                    <span>${gm(c.last_turn_ago_s)}</span>
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
                  value=${un.value}
                  onInput=${c=>{un.value=c.target.value}}
                  onKeyDown=${c=>{c.key==="Enter"&&_o()}}
                  disabled=${J.value}
                />
                <button class="control-btn" onClick=${()=>{_o()}} disabled=${J.value||un.value.trim()===""}>
                  Send
                </button>
              </div>

              <label class="control-label" for="ops-pause-reason">Pause or Resume</label>
              <div class="control-row ops-split-row">
                <input
                  id="ops-pause-reason"
                  class="control-input"
                  type="text"
                  value=${ii.value}
                  onInput=${c=>{ii.value=c.target.value}}
                  disabled=${J.value}
                />
                <button class="control-btn ghost" onClick=${()=>{hm()}} disabled=${J.value}>
                  Pause
                </button>
                <button class="control-btn ghost" onClick=${()=>{ym()}} disabled=${J.value}>
                  Resume
                </button>
              </div>

              <div class="ops-section-head">Inject Work</div>
              <input
                class="control-input"
                type="text"
                placeholder="Task title"
                value=${pn.value}
                onInput=${c=>{pn.value=c.target.value}}
                disabled=${J.value}
              />
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Task description"
                value=${Ma.value}
                onInput=${c=>{Ma.value=c.target.value}}
                disabled=${J.value}
              ></textarea>
              <div class="control-row ops-split-row">
                <select
                  class="control-input ops-select"
                  value=${oi.value}
                  onChange=${c=>{oi.value=c.target.value}}
                  disabled=${J.value}
                >
                  <option value="1">P1</option>
                  <option value="2">P2</option>
                  <option value="3">P3</option>
                  <option value="4">P4</option>
                  <option value="5">P5</option>
                </select>
                <button class="control-btn" onClick=${()=>{bm()}} disabled=${J.value||pn.value.trim()===""}>
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
                    <pre class="ops-code-block compact">${gs(r.recent_events.slice(-3))}</pre>
                  `:null}
                </div>
              `:i`<div class="ops-empty">Select a team session to edit notes, inject tasks, or stop the run.</div>`}

              <label class="control-label" for="ops-turn-kind">Session Action</label>
              <div class="control-row ops-split-row">
                <select
                  id="ops-turn-kind"
                  class="control-input ops-select"
                  value=${qe.value}
                  onChange=${c=>{qe.value=c.target.value}}
                  disabled=${J.value||!r}
                >
                  <option value="note">Note</option>
                  <option value="broadcast">Broadcast</option>
                  <option value="task">Task</option>
                  <option value="checkpoint">Checkpoint</option>
                </select>
                <button class="control-btn" onClick=${()=>{km()}} disabled=${J.value||!r}>
                  Apply
                </button>
              </div>
              <textarea
                class="control-textarea"
                rows=${3}
                placeholder="Session message"
                value=${Ia.value}
                onInput=${c=>{Ia.value=c.target.value}}
                disabled=${J.value||!r}
              ></textarea>
              ${qe.value==="task"?i`
                <input
                  class="control-input"
                  type="text"
                  placeholder="Injected task title"
                  value=${Oa.value}
                  onInput=${c=>{Oa.value=c.target.value}}
                  disabled=${J.value||!r}
                />
                <textarea
                  class="control-textarea"
                  rows=${2}
                  placeholder="Injected task description"
                  value=${za.value}
                  onInput=${c=>{za.value=c.target.value}}
                  disabled=${J.value||!r}
                ></textarea>
                <select
                  class="control-input ops-select"
                  value=${ri.value}
                  onChange=${c=>{ri.value=c.target.value}}
                  disabled=${J.value||!r}
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
                  value=${li.value}
                  onInput=${c=>{li.value=c.target.value}}
                  disabled=${J.value||!r}
                />
                <button class="control-btn ghost" onClick=${()=>{xm()}} disabled=${J.value||!r}>
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
                value=${mn.value}
                onInput=${c=>{mn.value=c.target.value}}
                disabled=${J.value||!l}
              ></textarea>
              <div class="control-row">
                <button class="control-btn" onClick=${()=>{Sm()}} disabled=${J.value||!l||mn.value.trim()===""}>
                  Send Keeper Message
                </button>
              </div>
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function wm({text:t}){if(!t)return null;const e=Cm(t);return i`<div class="markdown-content">${e}</div>`}function Cm(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],l=s.slice(r.length).trim(),p=[];for(a++;a<e.length&&!e[a].startsWith(r);)p.push(e[a]),a++;a++,n.push(i`<pre><code class=${l?`language-${l}`:""}>${p.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],l=s.trim().replace(/^<think>/,"").trim();for(l&&l!=="</think>"&&r.push(l),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const f=e[a].replace("</think>","").trim();f&&r.push(f),a++}const p=r.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${$s(p)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(i`<blockquote>${$s(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const o=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;o.push(r),a++}o.length>0&&n.push(i`<p>${$s(o.join(`
`))}</p>`)}return n}function $s(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const o=s[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(s[2]){const o=s[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(s[3]){const o=s[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else s[4]&&s[5]&&e.push(i`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const rn=g("posts"),di=g([]),ui=g([]),vn=g(""),qa=g(!1),fn=g(!1),Mn=g(""),Fa=g(null),Rt=g(null),pi=g(!1),Xt=g(null),la=g(null);async function as(){qa.value=!0,Mn.value="";try{const[t,e]=await Promise.all([Sc(),Ac()]);di.value=t,ui.value=e,Xt.value=!0,la.value=Date.now()}catch(t){Mn.value=t instanceof Error?t.message:"Failed to load council data",Xt.value=!1}finally{qa.value=!1}}pd(as);async function $o(){const t=vn.value.trim();if(t){fn.value=!0;try{const e=await wc(t);vn.value="",w(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await as()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";w(n,"error")}finally{fn.value=!1}}}async function Tm(t){Fa.value=t,pi.value=!0,Rt.value=null;try{Rt.value=await Cc(t)}catch(e){Mn.value=e instanceof Error?e.message:"Failed to load debate status",Rt.value=null}finally{pi.value=!1}}const Or=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ca=g(null),_n=g([]),ye=g(!1),_e=g(null),gn=g("");function Nm(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Rm=g(Nm()),$n=g(!1);async function Oi(t){_e.value=t,ca.value=null,_n.value=[],ye.value=!0;try{const e=await Jl(t);if(_e.value!==t)return;ca.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},_n.value=e.comments??[]}catch{_e.value===t&&(ca.value=null,_n.value=[])}finally{_e.value===t&&(ye.value=!1)}}async function ho(t){const e=gn.value.trim();if(e){$n.value=!0;try{await Vl(t,Rm.value,e),gn.value="",w("Comment posted","success"),await Oi(t),jt()}catch{w("Failed to post comment","error")}finally{$n.value=!1}}}function Lm(){const t=wn.value;return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Or.map(e=>i`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{wn.value=e.id,jt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${pe.value?"is-active":""}"
          onClick=${()=>{pe.value=!pe.value,jt()}}
        >
          ${pe.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${jt} disabled=${Tn.value}>
          ${Tn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function mi(){var e;const t=(e=se.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:i`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?i`<span class="feed-health-meta">Last sync: <${B} timestamp=${t.last_sync_at} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function zr({flair:t}){return t?i`<span class="post-flair ${t}">${t}</span>`:null}function Pm(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function yo(t){return t.updated_at!==t.created_at}function vi(){var n;const t=((n=Or.find(a=>a.id===wn.value))==null?void 0:n.label)??wn.value,e=Ge.value.length;return i`
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
        <strong>${pe.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Zs.value?i`<${B} timestamp=${Zs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Dm({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Ho(t.id,n),jt()}catch{w("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>ll(t.id)}>
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
              <${zr} flair=${t.flair} />
              ${yo(t)?i`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${B} timestamp=${t.created_at} /></span>
            ${yo(t)?i`<span>Updated <${B} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Pm(t.content)}</div>
      </div>
    </div>
  `}function Mm({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${B} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Em({postId:t}){return i`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${gn.value}
        onInput=${e=>{gn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ho(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${$n.value}
      />
      <button
        onClick=${()=>ho(t)}
        disabled=${$n.value||gn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${$n.value?"...":"Post"}
      </button>
    </div>
  `}function Im({post:t}){_e.value!==t.id&&!ye.value&&Oi(t.id);const e=async n=>{try{await Ho(t.id,n),jt()}catch{w("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>wt("board")}>← Back to Board</button>
      <${C} title=${i`${t.title} <${zr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${wm} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${B} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?i`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${C} title="Comments (${ye.value?"...":_n.value.length})">
        ${ye.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Mm} comments=${_n.value} />`}
        <${Em} postId=${t.id} />
      <//>
    </div>
  `}function Om({debate:t}){const e=Fa.value===t.id;return i`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Tm(t.id)}
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
  `}function zm({session:t}){return i`
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
  `}function jr(){return Xt.value===null||Xt.value&&!la.value?null:i`
    <div class="feed-health-banner ${Xt.value===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${Xt.value===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${la.value?i`<span class="feed-health-meta">Last sync: <${B} timestamp=${la.value} /></span>`:i`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function jm(){const t=Xt.value===!1;return i`
    <div>
      <${jr} />
      <${C} title="Start Debate" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${vn.value}
            onInput=${e=>{vn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&$o()}}
            disabled=${fn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${$o}
            disabled=${fn.value||vn.value.trim()===""}
          >
            ${fn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${as} disabled=${qa.value}>
            ${qa.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Mn.value?i`<div class="council-error">${Mn.value}</div>`:null}
      <//>

      <${C} title="Debates" class="section">
        <div class="council-list">
          ${di.value.length===0?i`<div class="empty-state">${t?"No debates loaded (council feed degraded).":"No debates yet"}</div>`:di.value.map(e=>i`<${Om} key=${e.id} debate=${e} />`)}
        </div>
      <//>

      <${C} title=${Fa.value?`Debate Detail (${Fa.value})`:"Debate Detail"} class="section">
        ${pi.value?i`<div class="loading-indicator">Loading debate detail...</div>`:Rt.value?i`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${Rt.value.status}</span>
                  <span>Total arguments: ${Rt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${Rt.value.support_count}</span>
                  <span>Oppose: ${Rt.value.oppose_count}</span>
                  <span>Neutral: ${Rt.value.neutral_count}</span>
                </div>
                ${Rt.value.summary_text?i`<pre class="council-detail">${Rt.value.summary_text}</pre>`:null}
              `:i`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function qm(){const t=Xt.value===!1;return i`
    <div>
      <${jr} />
      <${C} title="Voting Sessions" class="section">
        <div class="council-list">
          ${ui.value.length===0?i`<div class="empty-state">${t?"No sessions loaded (council feed degraded).":"No active sessions"}</div>`:ui.value.map(e=>i`<${zm} key=${e.id} session=${e} />`)}
        </div>
      <//>
    </div>
  `}function Fm(){const t=rn.value;return i`
    <div class="overview-sub-tabs" style="margin-bottom: 12px;">
      <button class="sub-tab-btn ${t==="posts"?"active":""}" onClick=${()=>{rn.value="posts"}}>Posts</button>
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{rn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{rn.value="voting"}}>Voting</button>
    </div>
  `}function Km(){var a,s;const t=Ge.value,e=Tn.value,n=((s=(a=se.value)==null?void 0:a.data_quality)==null?void 0:s.board_contract_ok)===!1;return i`
    <div>
      <${mi} />
      <${vi} />
      <${Lm} />
      ${e?i`<div class="loading-indicator">Loading board...</div>`:t.length===0?i`
              <div class="empty-state">
                ${n?"No posts loaded (board feed degraded). Check board contract sync.":pe.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
              </div>
            `:i`<div class="board-post-list">
              ${t.map(o=>i`<${Dm} key=${o.id} post=${o} />`)}
            </div>`}
    </div>
  `}function Hm(){var s,o;const t=Ge.value,e=st.value.postId,n=((o=(s=se.value)==null?void 0:s.data_quality)==null?void 0:o.board_contract_ok)===!1,a=rn.value;if(ct(()=>{(a==="debates"||a==="voting")&&as()},[a]),e){const r=t.find(l=>l.id===e)??(_e.value===e?ca.value:null);return!r&&_e.value!==e&&!ye.value&&Oi(e),r?i`
          <${mi} />
          <${vi} />
          <${Im} post=${r} />
        `:i`
          <div>
            <${mi} />
            <${vi} />
            <button class="back-btn" onClick=${()=>wt("board")}>← Back to Board</button>
            ${ye.value?i`<div class="loading-indicator">Loading post...</div>`:i`
                  <div class="empty-state">
                    ${n?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return i`
    <${Fm} />
    ${a==="debates"?i`<${jm} />`:a==="voting"?i`<${qm} />`:i`<${Km} />`}
  `}const Um=40;function Bm({items:t,itemHeight:e,overscan:n=5,renderItem:a,getKey:s,className:o=""}){const r=Po(null),[l,p]=Qa({start:0,end:30}),f=t.length>Um;if(ct(()=>{if(!f)return;const c=r.current;if(!c)return;let y=!1;const x=()=>{const{scrollTop:P,clientHeight:N}=c,R=Math.max(0,Math.floor(P/e)-n),G=Math.min(t.length,Math.ceil((P+N)/e)+n);p(H=>H.start===R&&H.end===G?H:{start:R,end:G})};let T=!1;const L=()=>{T||y||(T=!0,requestAnimationFrame(()=>{y||x(),T=!1}))},z=new ResizeObserver(()=>{y||x()});return x(),c.addEventListener("scroll",L,{passive:!0}),z.observe(c),()=>{y=!0,c.removeEventListener("scroll",L),z.disconnect()}},[f,t.length,e,n]),!f)return i`
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
          ${v.map((c,y)=>{const x=l.start+y;return i`<div key=${s(c)}>${a(c,x)}</div>`})}
        </div>
      </div>
    </div>
  `}function Wm(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Gm(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Jm(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const qr=120,Vm=12,Qm=16,Ym=12,fi=g("all"),Xm={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Zm={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function tv(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function ev(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Wm(t),actor:Gm(t),content:Jm(t),timestamp:new Date(t.timestamp).toISOString()}}function nv(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function av(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function Jn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function _i(t){return t.last_heartbeat??Jn(t.last_turn_ago_s)??Jn(t.last_proactive_ago_s)??Jn(t.last_handoff_ago_s)??Jn(t.last_compaction_ago_s)}function sv(t,e){const n=_i(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function Et(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const gi=Tt(()=>{const t=An.value.map(tv),e=va.value.map(ev),n=[...yt.value].sort((o,r)=>Et(r.updated_at??r.created_at??0)-Et(o.updated_at??o.created_at??0)).slice(0,Vm).map(nv).filter(o=>o!==null),a=[...Ge.value].sort((o,r)=>Et(r.updated_at||r.created_at)-Et(o.updated_at||o.created_at)).slice(0,Qm).map(av),s=[...Jt.value].sort((o,r)=>Et(_i(r)??0)-Et(_i(o)??0)).slice(0,Ym).map(sv).filter(o=>o!==null);return[...t,...e,...n,...a,...s].sort((o,r)=>Et(r.timestamp)-Et(o.timestamp))}),iv=Tt(()=>{const t=gi.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),ov=Tt(()=>{const t=fi.value;return(t==="all"?gi.value:gi.value.filter(n=>n.kind===t)).slice(0,qr)}),rv=Tt(()=>{const t=Xa.value,e={activeAssignedCount:0,lastActivityAt:null,lastActivityText:null};return Ct.value.map(n=>({agent:n,motion:t.get(n.name.trim().toLowerCase())??e})).sort((n,a)=>{const s=a.motion.activeAssignedCount-n.motion.activeAssignedCount;return s!==0?s:Et(a.motion.lastActivityAt??0)-Et(n.motion.lastActivityAt??0)})});function lv(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function nn({label:t,value:e,color:n}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function cv({row:t}){return i`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${lv(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Zm[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function dv(){const t=iv.value,e=ov.value,n=e[0],a=rv.value;return i`
    <div class="stats-grid">
      <${nn} label="Visible rows" value=${e.length} />
      <${nn} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${nn} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${nn} label="Board signals" value=${t.board} color="#fbbf24" />
      <${nn} label="SSE events" value=${In.value} color="#c084fc" />
    </div>

    <${C} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>i`
            <button
              class="goal-filter-btn ${fi.value===s?"active":""}"
              onClick=${()=>{fi.value=s}}
            >
              ${Xm[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Ft.value?"":"pill-stale"}">
            ${Ft.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?i`Latest: <${B} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${qr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      ${e.length===0?i`<div class="terminal-feed"><div class="empty-state">Waiting for live or snapshot signals...</div></div>`:i`<${Bm}
            items=${e}
            itemHeight=${28}
            overscan=${8}
            getKey=${s=>s.id}
            renderItem=${s=>i`<${cv} row=${s} />`}
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
                    ${o.lastActivityAt?i` · <${B} timestamp=${o.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${o.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Fr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,o=2*Math.PI*a,r=o*((100-t*100)/100);let l="mitosis-safe";return t>=.8?l="mitosis-critical":t>=.5&&(l="mitosis-warn"),i`
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
  `}const hs=600*1e3,uv=1200*1e3,bo=.8;function Qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ce(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function pv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function mv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function vv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function fv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function _v(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function gv(t){var p,f;const e=Xa.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Qt(n)):Number.POSITIVE_INFINITY,s=!!((p=t.current_task)!=null&&p.trim())||e.activeAssignedCount>0;let o="watching",r="ok",l="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(o="offline",r="bad",l=n?"Offline or inactive":"No recent presence"):a>uv?(o="quiet",r="bad",l=s?"Working without a fresh signal":"No fresh agent signal"):s?(o="working",r=a>hs?"warn":"ok",l=a>hs?"Execution looks quiet for too long":"Task and live signal aligned"):a>hs?(o="quiet",r="warn",l="Quiet but still reachable"):t.status==="idle"&&(o="watching",r="ok",l="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:o,tone:r,focus:((f=t.current_task)==null?void 0:f.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:l}}function $v(t){const e=tr.value.get(t.name)??"idle",n=er.value.has(t.name),a=t.context_ratio??0;let s="healthy",o="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",o="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=bo)&&(s="warning",o="warn",r=a>=bo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:o,focus:fv(t),note:r}}function an({label:t,value:e,color:n,caption:a}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?i`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function hv({item:t}){const e=t.kind==="agent"?()=>Oe(t.agent.name):()=>ya(t.keeper);return i`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?i`<span><${B} timestamp=${t.timestamp} /></span>`:i`<span>No signal</span>`}
      </div>
    </button>
  `}function ko({row:t}){const{agent:e,motion:n}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Oe(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Fr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Pt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${pv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?i`<span>Signal <${B} timestamp=${t.lastSignalAt} /></span>`:i`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
        ${e.last_seen?i`<span>Seen <${B} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?i`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function yv({row:t}){const{keeper:e}=t;return i`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ya(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?i`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Fr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Pt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${mv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?i`<span>Heartbeat <${B} timestamp=${e.last_heartbeat} /></span>`:i`<span>No heartbeat</span>`}
        <span>${_v(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${vv(e.context_ratio)}</span>
        ${e.model?i`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function bv(){const t=[...Ct.value].map(gv).sort((m,d)=>{const v=Ce(d.tone)-Ce(m.tone);if(v!==0)return v;const c=d.activeTaskCount-m.activeTaskCount;return c!==0?c:Qt(d.lastSignalAt)-Qt(m.lastSignalAt)}),e=[...Jt.value].map($v).sort((m,d)=>{const v=Ce(d.tone)-Ce(m.tone);if(v!==0)return v;const c=(d.keeper.context_ratio??0)-(m.keeper.context_ratio??0);return c!==0?c:Qt(d.keeper.last_heartbeat)-Qt(m.keeper.last_heartbeat)}),n=t.filter(m=>m.state!=="offline"),a=t.filter(m=>m.state==="offline"),s=n.length,o=t.filter(m=>m.state==="working").length,r=t.filter(m=>m.lastSignalAt&&Date.now()-Qt(m.lastSignalAt)<=12e4).length,l=t.filter(m=>m.tone!=="ok"),p=e.filter(m=>m.tone!=="ok"),f=[...p.map(m=>({kind:"keeper",key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.keeper.last_heartbeat??null,keeper:m.keeper})),...l.map(m=>({kind:"agent",key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,subtitle:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,agent:m.agent}))].sort((m,d)=>{const v=Ce(d.tone)-Ce(m.tone);return v!==0?v:Qt(d.timestamp)-Qt(m.timestamp)}).slice(0,8);return i`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${an} label="Agents online" value=${s} color="#4ade80" caption="active + idle" />
        <${an} label="Working now" value=${o} color="#fbbf24" caption="task or claimed load" />
        <${an} label="Fresh signals" value=${r} color="#22d3ee" caption="within last 2 minutes" />
        <${an} label="Agent alerts" value=${l.length} color=${l.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${an} label="Keeper alerts" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${C} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${f.length===0?i`<div class="empty-state">No agent or keeper alerts right now</div>`:f.map(m=>i`<${hv} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${C} title="Active Agents" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live agents stay grouped here first so execution drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?i`<div class="empty-state">No active agents visible</div>`:n.map(m=>i`<${ko} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?i`<div class="empty-state">No keepers active</div>`:e.map(m=>i`<${yv} key=${m.keeper.name} row=${m} />`)}
          </div>
        <//>

        <${C} title="Offline Agents" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows are separated so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${a.length===0?i`<div class="empty-state">No offline agents right now</div>`:a.map(m=>i`<${ko} key=${m.agent.name} row=${m} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ka=g("all"),Ha=g("all"),$i=Tt(()=>{let t=Cn.value;return Ka.value!=="all"&&(t=t.filter(e=>e.horizon===Ka.value)),Ha.value!=="all"&&(t=t.filter(e=>e.status===Ha.value)),t}),kv=Tt(()=>{const t={short:[],mid:[],long:[]};for(const e of $i.value){const n=t[e.horizon];n&&n.push(e)}return t}),xv=Tt(()=>{const t=Array.from(Qo.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Sv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function zi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function da(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Av(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function xo(t){return t.toFixed(4)}function So(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function wv({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${da(t.horizon)}">
            ${zi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Sv(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${B} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Pt} status=${t.status} />
        <div class="goal-updated">
          <${B} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ao({label:t,timestamp:e,source:n,note:a}){return i`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?i`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?i`<${B} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ys({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return i`
    <${C} title="${zi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>i`<${wv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Cv(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ka.value===t?"active":""}"
            onClick=${()=>{Ka.value=t}}
          >
            ${t==="all"?"All":zi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Ha.value===t?"active":""}"
            onClick=${()=>{Ha.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Tv(){const t=Cn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${da("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${da("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${da("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Nv({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${Pt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${xo(t.baseline_metric)}</span>
          <span>Current ${xo(t.current_metric)}</span>
          <span class=${So(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${So(t)}
          </span>
          <span>Elapsed ${Av(t.elapsed_seconds)}</span>
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
  `}function bs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return i`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?i`<${B} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Rv(){const{todo:t,inProgress:e,done:n}=Zo.value;return i`
    <${C} title="Task Backlog" class="section">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>i`<${bs} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>i`<${bs} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>i`<${bs} key=${a.id} task=${a} />`)}
          ${n.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Lv(){const t=kv.value,e=xv.value,n=e.filter(l=>l.status==="running").length,a=e.filter(l=>l.recoverable).length,s=Cn.value.filter(l=>l.status==="active").length,o=Vs.value,r=o==="idle"?"No loop running":o==="error"?Qs.value??"MDAL snapshot unavailable":"Current loop snapshot";return i`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${$i.value.length}</div>
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
            <button class="control-btn ghost" onClick=${Nn} disabled=${Pe.value}>
              ${Pe.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${He} disabled=${De.value}>
              ${De.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Nn(),He()}}
              disabled=${Pe.value||De.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Ao} label="Goals" timestamp=${Yo.value} source="masc_goal_list" />
          <${Ao}
            label="MDAL loops"
            timestamp=${Xo.value}
            source="/api/v1/mdal/loops"
            note=${r}
          />
        </div>
      <//>

      <${C} title="Goal Pipeline" class="section">
        <${Tv} />
        <${Cv} />
      <//>

      ${Pe.value&&Cn.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:$i.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
              <${ys} horizon="short" items=${t.short??[]} />
              <${ys} horizon="mid" items=${t.mid??[]} />
              <${ys} horizon="long" items=${t.long??[]} />
            `}

      <${C} title="MDAL Loops" class="section">
        ${De.value&&e.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&o==="error"?i`
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
                  ${e.map(l=>i`<${Nv} key=${l.loop_id} loop=${l} />`)}
                </div>
              `}
      <//>

      <${Rv} />
    </div>
  `}const Re=g(""),ks=g("ability_check"),xs=g("10"),Ss=g("12"),Vn=g(""),Qn=g("idle"),Yt=g(""),Yn=g("keeper-late"),As=g("player"),ws=g(""),At=g("idle"),Cs=g(null),Xn=g(""),Ts=g(""),Ns=g("player"),Rs=g(""),Ls=g(""),Ps=g(""),hn=g("20"),Ds=g("20"),Ms=g(""),Zn=g("idle"),hi=g(null),Kr=g("overview"),Es=g("all"),Is=g("all"),Os=g("all"),Pv=12e4,ss=g(null),wo=g(Date.now());function Dv(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Mv(t,e){return e>0?Math.round(t/e*100):0}const Ev={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Iv={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ta(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Ov(t){const e=t.trim().toLowerCase();return Ev[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function zv(t){const e=t.trim().toLowerCase();return Iv[e]??"상황에 따라 선택되는 전술 액션입니다."}function ee(t){return typeof t=="object"&&t!==null}function gt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function It(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const jv=new Set(["str","dex","con","int","wis","cha"]);function qv(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!ee(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,o])=>{const r=s.trim();if(r){if(typeof o=="number"&&Number.isFinite(o)){a[r]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const l=Number.parseFloat(o.trim());if(Number.isFinite(l)){a[r]=Math.max(0,Math.trunc(l));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Fv(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(hn.value.trim(),10);Number.isFinite(a)&&a>n&&(hn.value=String(n))}function yi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Kv(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Hv(t){Kr.value=t}function Hr(t){const e=ss.value;return e==null||e<=t}function Uv(t){const e=ss.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ua(){ss.value=null}function Ur(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Bv(t,e){Ur(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ss.value=Date.now()+Pv,w("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ua(t){return Hr(t)?(w("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function bi(t,e,n){return Ur([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Wv({hp:t,max:e}){const n=Mv(t,e),a=Dv(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Gv({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Jv({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Br({actor:t}){var p,f,m,d;const e=(p=t.archetype)==null?void 0:p.trim(),n=(f=t.persona)==null?void 0:f.trim(),a=(m=t.portrait)==null?void 0:m.trim(),s=(d=t.background)==null?void 0:d.trim(),o=t.traits??[],r=t.skills??[],l=Object.entries(t.stats_raw??{}).filter(([v,c])=>Number.isFinite(c)).filter(([v])=>!jv.has(v.toLowerCase()));return i`
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
        <${Pt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Jv} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Wv} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Gv} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${ta(e)}</div>`:null}
      ${s?i`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${l.map(([v,c])=>i`
                <span class="trpg-custom-stat-chip">${ta(v)} ${c}</span>
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
                  <span class="trpg-annot-name">${ta(v)}</span>
                  <span class="trpg-annot-desc">${Ov(v)}</span>
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
                  <span class="trpg-annot-name">${ta(v)}</span>
                  <span class="trpg-annot-desc">${zv(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Vv({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Wr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return i`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Kv(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${yi(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${B} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Qv({events:t}){const e="__none__",n=Es.value,a=Is.value,s=Os.value,o=Array.from(new Set(t.map(yi).map(d=>d.trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),r=Array.from(new Set(t.map(d=>(d.type??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),l=t.some(d=>(d.type??"").trim()===""),p=Array.from(new Set(t.map(d=>(d.phase??"").trim()).filter(d=>d!==""))).sort((d,v)=>d.localeCompare(v)),f=t.some(d=>(d.phase??"").trim()===""),m=t.filter(d=>{if(n!=="all"&&yi(d)!==n)return!1;const v=(d.type??"").trim(),c=(d.phase??"").trim();if(a===e){if(v!=="")return!1}else if(a!=="all"&&v!==a)return!1;if(s===e){if(c!=="")return!1}else if(s!=="all"&&c!==s)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${d=>{Es.value=d.target.value}}>
          <option value="all">all</option>
          ${o.map(d=>i`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${d=>{Is.value=d.target.value}}>
          <option value="all">all</option>
          ${l?i`<option value=${e}>(none)</option>`:null}
          ${r.map(d=>i`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${d=>{Os.value=d.target.value}}>
          <option value="all">all</option>
          ${f?i`<option value=${e}>(none)</option>`:null}
          ${p.map(d=>i`<option value=${d}>${d}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Es.value="all",Is.value="all",Os.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Wr} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Yv({outcome:t}){if(!t)return null;const e=o=>{const r=o.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function Gr({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function Xv({state:t,nowMs:e}){var f;const n=Ut.value||((f=t.session)==null?void 0:f.room)||"",a=Qn.value,s=t.party??[];if(!s.find(m=>m.id===Re.value)&&s.length>0){const m=s[0];m&&(Re.value=m.id)}const r=async()=>{var d,v;if(!n){w("Room ID가 비어 있습니다.","error");return}if(!ua(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(bi("라운드 실행",n,m)){Qn.value="running";try{const c=await uc(n);hi.value=c,Qn.value="ok";const y=ee(c.summary)?c.summary:null,x=y?En(y,"advanced",!1):!1,T=y?gt(y,"progress_reason",""):"";w(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${T?`: ${T}`:""}`,x?"success":"warning"),qt()}catch(c){hi.value=null,Qn.value="error";const y=c instanceof Error?c.message:"라운드 실행에 실패했습니다.";w(y,"error")}finally{Ua()}}},l=async()=>{var d,v;if(!n||!ua(e))return;const m=((d=t.current_round)==null?void 0:d.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(bi("턴 강제 진행",n,m))try{await vc(n),w("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{w("턴 이동에 실패했습니다.","error")}finally{Ua()}},p=async()=>{if(!n||!ua(e))return;const m=Re.value.trim();if(!m){w("먼저 Actor를 선택하세요.","warning");return}const d=Number.parseInt(xs.value,10),v=Number.parseInt(Ss.value,10);if(Number.isNaN(d)||Number.isNaN(v)){w("stat/dc는 숫자여야 합니다.","warning");return}const c=Number.parseInt(Vn.value,10),y=Vn.value.trim()===""||Number.isNaN(c)?void 0:c;try{await mc({roomId:n,actorId:m,action:ks.value.trim()||"ability_check",statValue:d,dc:v,rawD20:y}),w("주사위 판정을 기록했습니다.","success"),qt()}catch{w("주사위 판정 기록에 실패했습니다.","error")}};return i`
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
            value=${Re.value}
            onChange=${m=>{Re.value=m.target.value}}
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
              value=${ks.value}
              onInput=${m=>{ks.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${xs.value}
              onInput=${m=>{xs.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ss.value}
              onInput=${m=>{Ss.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Vn.value}
              onInput=${m=>{Vn.value=m.target.value}}
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
  `}function Zv({state:t}){var s;const e=Ut.value||((s=t.session)==null?void 0:s.room)||"",n=Zn.value,a=async()=>{if(!e){w("Room ID가 비어 있습니다.","warning");return}const o=Xn.value.trim(),r=Ts.value.trim();if(!r&&!o){w("이름 또는 Actor ID를 입력하세요.","warning");return}const l=Number.parseInt(hn.value.trim(),10),p=Number.parseInt(Ds.value.trim(),10),f=Number.isFinite(p)?Math.max(1,p):20,m=Number.isFinite(l)?Math.max(0,Math.min(f,l)):f;let d={};try{d=qv(Ms.value)}catch(v){w(v instanceof Error?v.message:"능력치 JSON 오류","error");return}Zn.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,c=await fc(e,{actor_id:o||void 0,name:r||void 0,role:Ns.value,idempotencyKey:v,portrait:Ls.value.trim()||void 0,background:Ps.value.trim()||void 0,hp:m,max_hp:f,alive:m>0,stats:Object.keys(d).length>0?d:void 0}),y=typeof c.actor_id=="string"?c.actor_id.trim():"";if(!y)throw new Error("생성 응답에 actor_id가 없습니다.");const x=Rs.value.trim();x&&await _c(e,y,x),Re.value=y,Yt.value=y,o||(Xn.value=""),Zn.value="ok",w(`Actor 생성 완료: ${y}`,"success"),await qt()}catch(v){Zn.value="error",w(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ts.value}
            onInput=${o=>{Ts.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ns.value}
            onChange=${o=>{Ns.value=o.target.value}}
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
            value=${Rs.value}
            onInput=${o=>{Rs.value=o.target.value}}
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
              value=${Xn.value}
              onInput=${o=>{Xn.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ls.value}
              onInput=${o=>{Ls.value=o.target.value}}
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
              value=${hn.value}
              onInput=${o=>{hn.value=o.target.value}}
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
              value=${Ds.value}
              onInput=${o=>{const r=o.target.value;Ds.value=r,Fv(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ps.value}
              onInput=${o=>{Ps.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ms.value}
              onInput=${o=>{Ms.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function tf({state:t,nowMs:e}){var v;const n=Ut.value||((v=t.session)==null?void 0:v.room)||"",a=t.join_gate,s=Cs.value,o=ee(s)?s:null,r=(t.party??[]).filter(c=>c.role!=="dm"),l=Yt.value.trim(),p=r.some(c=>c.id===l),f=p?l:l?"__manual__":"",m=async()=>{const c=Yt.value.trim(),y=Yn.value.trim();if(!n||!c){w("Room/Actor가 필요합니다.","warning");return}At.value="checking";try{const x=await gc(n,c,y||void 0);Cs.value=x,At.value="ok",w("참가 가능 여부를 갱신했습니다.","success")}catch(x){At.value="error";const T=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";w(T,"error")}},d=async()=>{var L,z;const c=Yt.value.trim(),y=Yn.value.trim(),x=ws.value.trim();if(!n||!c||!y){w("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ua(e))return;const T=((L=t.current_round)==null?void 0:L.phase)??((z=t.session)==null?void 0:z.status)??"unknown";if(bi("Mid-Join 승인 요청",n,T)){At.value="requesting";try{const P=await $c({room_id:n,actor_id:c,keeper_name:y,role:As.value,...x?{name:x}:{}});Cs.value=P;const N=ee(P)?En(P,"granted",!1):!1,R=ee(P)?gt(P,"reason_code",""):"";N?w("Mid-Join이 승인되었습니다.","success"):w(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),At.value=N?"ok":"error",qt()}catch(P){At.value="error";const N=P instanceof Error?P.message:"Mid-Join 요청에 실패했습니다.";w(N,"error")}finally{Ua()}}};return i`
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
            onChange=${c=>{const y=c.target.value;if(y==="__manual__"){(p||!l)&&(Yt.value="");return}Yt.value=y}}
          >
            <option value="">Actor 선택</option>
            ${r.map(c=>i`
              <option value=${c.id}>${c.name} (${c.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${f==="__manual__"?i`
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
            value=${Yn.value}
            onInput=${c=>{Yn.value=c.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${As.value}
            onChange=${c=>{As.value=c.target.value}}
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
            value=${ws.value}
            onInput=${c=>{ws.value=c.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${At.value==="checking"||At.value==="requesting"}>
              ${At.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${d} disabled=${At.value==="checking"||At.value==="requesting"}>
              ${At.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${En(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${It(o,"effective_score",0)}/${It(o,"required_points",0)}</span>
            ${gt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${gt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Jr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Vr({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Qr(){const t=hi.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ee(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(ee).slice(-8),o=t.canon_check,r=ee(o)?o:null,l=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],p=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],f=n?En(n,"advanced",!1):!1,m=n?gt(n,"progress_reason",""):"",d=n?gt(n,"progress_detail",""):"",v=n?It(n,"player_successes",0):0,c=n?It(n,"player_required_successes",0):0,y=n?En(n,"dm_success",!1):!1,x=n?It(n,"timeouts",0):0,T=n?It(n,"unavailable",0):0,L=n?It(n,"reprompts",0):0,z=n?It(n,"npc_attacks",0):0,P=n?It(n,"keeper_timeout_sec",0):0,N=n?It(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${f?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${f?"ADVANCED":"STALLED"}</strong>
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
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${z}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${P||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${N}</div></div>
      </div>

      ${s.length>0?i`
          <div class="trpg-round-list">
            ${s.map(R=>{const G=gt(R,"status","unknown"),H=gt(R,"actor_id","-"),kt=gt(R,"role","-"),nt=gt(R,"reason",""),at=gt(R,"action_type",""),U=gt(R,"reply","");return i`
                <div class="trpg-round-item ${G.includes("fallback")||G.includes("timeout")?"failed":"active"}">
                  <span>${H} (${kt})</span>
                  <span style="margin-left:auto; font-size:11px;">${G}</span>
                  ${at?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${at}</div>`:null}
                  ${nt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${nt}</div>`:null}
                  ${U?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${U.slice(0,120)}</div>`:null}
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
  `}function ef({state:t,nowMs:e}){var r,l,p;const n=Ut.value||((r=t.session)==null?void 0:r.room)||"",a=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown",s=Hr(e),o=Uv(e);return i`
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
          ${s?i`<button class="trpg-run-btn recommend" onClick=${()=>Bv(n,a)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Ua(),w("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function nf({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Hv(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function af({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${Wr} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${C} title="맵" style="margin-top:16px;">
              <${Vv} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${C} title="현재 라운드">
          <${Vr} state=${t} />
        <//>

        <${C} title="기여도" style="margin-top:16px;">
          <${Jr} state=${t} />
        <//>

        <${C} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>i`<${Br} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Gr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function sf({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${C} title=${`이벤트 타임라인 (${e.length})`}>
          <${Qv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${C} title="최근 라운드 결과">
          <${Qr} />
        <//>

        <${C} title="현재 라운드" style="margin-top:16px;">
          <${Vr} state=${t} />
        <//>
      </div>
    </div>
  `}function of({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${ef} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${C} title="조작 패널">
            <${Xv} state=${t} nowMs=${e} />
          <//>

          <${C} title="Actor Spawn" style="margin-top:16px;">
            <${Zv} state=${t} />
          <//>

          <${C} title="Mid-Join Gate" style="margin-top:16px;">
            <${tf} state=${t} nowMs=${e} />
          <//>

          <${C} title="최근 라운드 결과" style="margin-top:16px;">
            <${Qr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${C} title="기여도" style="margin-top:0;">
            <${Jr} state=${t} />
          <//>

          <${C} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>i`<${Br} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${C} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Gr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function rf(){var l,p,f,m,d;const t=Vo.value,e=Xs.value;if(ct(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{wo.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>qt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,o=Kr.value,r=wo.value;return i`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ut.value||((l=t.session)==null?void 0:l.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((f=t.session)==null?void 0:f.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>qt()}>새로고침</button>
      </div>

      <${Yv} outcome=${s} />

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

      <${nf} active=${o} />

      ${o==="overview"?i`<${af} state=${t} />`:o==="timeline"?i`<${sf} state=${t} />`:i`<${of} state=${t} nowMs=${r} />`}
    </div>
  `}const ji="masc_dashboard_agent_name";function lf(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ji);return e??n??"dashboard"}const ht=g(lf()),yn=g(""),bn=g(""),Ba=g(""),Yr=g(null),Wa=g(null),kn=g(!1),Me=g(!1),xn=g(!1),Sn=g(!1),Ga=g(!1),Ja=g(!1),is=g(!1);function Va(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function pa(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Xr(t){return!t||t.length===0?"none":t.join(", ")}function cf(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Va(t.quiet_start)}-${Va(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${pa(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${pa(t.interval_s)}.`:`Lodge ticks every ${pa(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Ve(){Ke();try{await ne()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function qi(t){const e=t.trim();ht.value=e,e&&localStorage.setItem(ji,e)}function df(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function ki(){const t=ht.value.trim();if(t){xn.value=!0;try{const e=await yc(t),n=df(e);n&&qi(n),is.value=!0,await Ve(),w(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";w(n,"error")}finally{xn.value=!1}}}async function uf(){const t=ht.value.trim();if(t){Sn.value=!0;try{await Bo(t),is.value=!1,await Ve(),w(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";w(n,"error")}finally{Sn.value=!1}}}async function pf(){const t=ht.value.trim();if(t)try{await Bo(t)}catch{}localStorage.removeItem(ji),qi("dashboard"),is.value=!1,await ki()}async function mf(){const t=ht.value.trim();if(t){Ga.value=!0;try{await bc(t),await Ve(),w("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";w(n,"error")}finally{Ga.value=!1}}}async function Co(){const t=ht.value.trim(),e=yn.value.trim();if(!(!t||!e)){kn.value=!0;try{await Uo(t,e),yn.value="",await Ve(),w("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";w(a,"error")}finally{kn.value=!1}}}async function vf(){const t=bn.value.trim(),e=Ba.value.trim()||"Created from dashboard";if(t){Me.value=!0;try{await hc(t,e,1),bn.value="",Ba.value="",await Ve(),w("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";w(a,"error")}finally{Me.value=!1}}}async function To(){const t=ht.value.trim()||"dashboard";Ja.value=!0,Wa.value=null;try{const e=await zn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=wi(e.result);Yr.value=n,await Ve(),n!=null&&n.skipped_reason?w(n.skipped_reason,"warning"):w(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Wa.value=n,w(n,"error")}finally{Ja.value=!1}}function ff({runtime:t}){var s,o;const e=Yr.value??(t==null?void 0:t.last_tick_result)??null;if(Wa.value)return i`<div class="control-result-box is-error">${Wa.value}</div>`;if(!e)return i`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((o=e.passed_rows)==null?void 0:o.slice(0,3))??[];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?i`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Xr(e.acted_names)}</div>
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
  `}function _f(t){return t.find(n=>n.name===ln.value)??t[0]??null}function gf(){var a,s;const t=Jt.value,e=((a=se.value)==null?void 0:a.lodge)??null,n=_f(t);return ct(()=>{ki()},[]),ct(()=>{var r;const o=((r=t[0])==null?void 0:r.name)??"";if(!ln.value&&o){na(o);return}ln.value&&!t.some(l=>l.name===ln.value)&&na(o)},[t.map(o=>o.name).join("|")]),i`
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
          onInput=${o=>qi(o.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ki()}}
            disabled=${xn.value||ht.value.trim()===""}
          >
            ${xn.value?"Joining...":is.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{uf()}}
            disabled=${Sn.value||ht.value.trim()===""}
          >
            ${Sn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{pf()}}
            disabled=${xn.value||Sn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{mf()}}
            disabled=${Ga.value||ht.value.trim()===""}
          >
            ${Ga.value?"Pinging...":"Heartbeat"}
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
            value=${yn.value}
            onInput=${o=>{yn.value=o.target.value}}
            onKeyDown=${o=>{o.key==="Enter"&&Co()}}
            disabled=${kn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{Co()}}
            disabled=${kn.value||yn.value.trim()===""||ht.value.trim()===""}
          >
            ${kn.value?"Sending...":"Send"}
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
          onInput=${o=>{na(o.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?i`<option value="">No keepers available</option>`:t.map(o=>i`<option value=${o.name}>${o.name}</option>`)}
        </select>

        <${ur} keeper=${n} />
        <${mr}
          actor=${ht.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{To()}}
        />
        <${pr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${cf(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${pa(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Va(e==null?void 0:e.quiet_start)}-${Va(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Xr((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?i`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{To()}}
            disabled=${Ja.value}
          >
            ${Ja.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${ff} runtime=${e} />
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
          value=${bn.value}
          onInput=${o=>{bn.value=o.target.value}}
          disabled=${Me.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Ba.value}
          onInput=${o=>{Ba.value=o.target.value}}
          disabled=${Me.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{vf()}}
          disabled=${Me.value||bn.value.trim()===""}
        >
          ${Me.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const No=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],xi=[{id:"command",label:"Command",icon:"🧭",group:"command",description:"Company, platoon, squad, and agent command plane with operation and trace visibility"},{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals, MDAL loops, and task backlog in one planning surface"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}],Ro="masc_dashboard_quick_actions_open";function $f(){const t=Ft.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${In.value} events</span>
    </div>
  `}function hf(){const t=st.value.tab,e=Ft.value,n=xi.find(r=>r.id===t),a=No.find(r=>r.id===(n==null?void 0:n.group)),[s,o]=Qa(()=>{const r=localStorage.getItem(Ro);return r!=="0"});return ct(()=>{localStorage.setItem(Ro,s?"1":"0")},[s]),i`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?i`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${No.map(r=>i`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${xi.filter(l=>l.group===r.id).map(l=>i`
                  <button
                    class="rail-tab-btn ${t===l.id?"active":""}"
                    onClick=${()=>wt(l.id)}
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
            <strong>${Ct.value.length}</strong>
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
            onClick=${()=>{ne(),t==="command"&&(je(),he()),t==="ops"&&Be(),t==="board"&&jt(),t==="trpg"&&qt(),t==="goals"&&(Nn(),He())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>wt("ops")}>
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
        ${s?i`<div class="rail-fold-body"><${gf} /></div>`:i`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function yf(){switch(st.value.tab){case"command":return i`<${sm} />`;case"overview":return i`<${co} />`;case"ops":return i`<${Am} />`;case"board":return i`<${Hm} />`;case"agents":return i`<${bv} />`;case"goals":return i`<${Lv} />`;case"trpg":return i`<${rf} />`;default:return i`<${co} />`}}function bf(){ct(()=>{cl(),zo(),ne();const n=vd();return fd(),()=>{gl(),n(),_d()}},[]),ct(()=>{const n=setInterval(()=>{const a=st.value.tab;a==="command"?(je(),he()):a==="ops"?Be():a==="board"?jt():a==="trpg"?qt():a==="goals"&&(Nn(),He())},15e3);return()=>{clearInterval(n)}},[]),ct(()=>{const n=st.value.tab;n==="command"&&(je(),he()),n==="ops"&&Be(),n==="board"&&jt(),n==="trpg"&&qt(),n==="goals"&&(Nn(),He())},[st.value.tab]);const t=st.value.tab,e=xi.find(n=>n.id===t);return i`
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
            class="activity-panel-toggle ${Ue.value?"active":""}"
            onClick=${Jd}
            title="Toggle Activity Panel"
          >
            Activity
          </button>
          <${$f} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${hf} />
        <main class="dashboard-main">
          ${Ys.value&&!Ft.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${yf} />`}
        </main>
      </div>

      ${Ue.value?i`
        <div class="activity-panel-backdrop" onClick=${so} />
        <aside class="activity-panel">
          <div class="activity-panel-header">
            <h3>Activity Feed</h3>
            <button class="activity-panel-close" onClick=${so}>Close</button>
          </div>
          <div class="activity-panel-body">
            <${dv} />
          </div>
        </aside>
      `:null}

      <${Wd} />
      <${Ad} />
      <${yd} />
    </div>
  `}const Lo=document.getElementById("app");Lo&&al(i`<${bf} />`,Lo);export{ou as _};
