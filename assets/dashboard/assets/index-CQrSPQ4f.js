var Qr=Object.defineProperty;var Zr=(t,e,n)=>e in t?Qr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ie=(t,e,n)=>Zr(t,typeof e!="symbol"?e+"":e,n);import{e as tl,_ as el,c as g,b as re,y as rt,d as xi,A as nl,G as al}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var o=tl.bind(el);const sl=["mission","execution","memory","governance","planning","intervene","command","lab"],Si={tab:"mission",params:{},postId:null};function Oo(t){return!!t&&sl.includes(t)}function Os(t){try{return decodeURIComponent(t)}catch{return t}}function js(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function ol(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ai(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=Os(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=Os(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],a=e.tab;return{tab:Oo(n)?n:Oo(a)?a:"mission",params:e,postId:null}}function $a(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Si;const n=Os(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const d=n.indexOf("?");d>=0&&(a=n.slice(0,d),s=n.slice(d+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=js(s),r=ol(a);return Ai(r,i)}function il(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Si,params:js(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=js(e.replace(/^\?/,""));return Ai(a,s)}function Ci(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([s])=>!(s==="tab"||t.tab==="lab"&&s==="surface"));if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const j=g($a(window.location.hash));window.addEventListener("hashchange",()=>{j.value=$a(window.location.hash)});function gt(t,e){const n={tab:t,params:e??{}};window.location.hash=Ci(n)}function rl(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function ll(){if(window.location.hash&&window.location.hash!=="#"){j.value=$a(window.location.hash);return}const t=il(window.location.pathname,window.location.search);if(t){j.value=t;const e=Ci(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",j.value=$a(window.location.hash)}const jo="masc_dashboard_sse_session_id",cl=1e3,dl=15e3,Se=g(!1),_o=g(0),wi=g(null),Fs=g([]);function ul(){let t=sessionStorage.getItem(jo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(jo,t)),t}const pl=200;function ml(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};Fs.value=[s,...Fs.value].slice(0,pl)}function qs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Fo(t,e){const n=qs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function At(t,e,n,a,s={}){ml(t,e,n,{eventType:a,...s})}let Pt=null,je=null,Ks=0;function Ti(){je&&(clearTimeout(je),je=null)}function vl(){if(je)return;Ks++;const t=Math.min(Ks,5),e=Math.min(dl,cl*Math.pow(2,t));je=setTimeout(()=>{je=null,Ii()},e)}function Ii(){Ti(),Pt&&(Pt.close(),Pt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",ul());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);Pt=i,i.onopen=()=>{Pt===i&&(Ks=0,Se.value=!0)},i.onerror=()=>{Pt===i&&(Se.value=!1,i.close(),Pt=null,vl())},i.onmessage=r=>{try{const d=JSON.parse(r.data);_o.value++,wi.value=d,_l(d)}catch{}}}function _l(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":At(n,"Joined","system","agent_joined");break;case"agent_left":At(n,"Left","system","agent_left");break;case"broadcast":At(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":At(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":At(n,Fo("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:qs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":At(n,Fo("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:qs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":At(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":At(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":At(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":At(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:At(n,e,"system","unknown")}}function fl(){Ti(),Pt&&(Pt.close(),Pt=null),Se.value=!1}function Ri(){return new URLSearchParams(window.location.search)}function Ni(){const t=Ri(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Pi(){return{...Ni(),"Content-Type":"application/json"}}const gl=15e3,fo=3e4,$l=6e4,qo=new Set([408,425,429,500,502,503,504]);class zn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ie(this,"method");Ie(this,"path");Ie(this,"status");Ie(this,"statusText");Ie(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function go(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new zn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function hl(){var e,n;const t=Ri();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function it(t){const e=await go(t,{headers:Ni()},gl);if(!e.ok)throw new zn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function yl(t){return new Promise(e=>setTimeout(e,t))}function bl(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function kl(t){if(t instanceof zn)return t.timeout||typeof t.status=="number"&&qo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=bl(t.message);return e!==null&&qo.has(e)}async function Mi(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!kl(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await yl(i),a+=1}}async function Ft(t,e,n,a=fo){const s=await go(t,{method:"POST",headers:{...Pi(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new zn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.json()}async function xl(t,e,n,a=fo){const s=await go(t,{method:"POST",headers:{...Pi(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new zn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function Sl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Al(t){var e,n,a,s,i,r,d;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const c=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(c)}return((d=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:d.text)??""}async function le(t,e){const n=await xl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},$l),a=Sl(n);return Al(a)}function Cl(){return it("/api/v1/dashboard/shell")}function wl(){return it("/api/v1/dashboard/execution")}function Tl(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),it(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Il(){return it("/api/v1/dashboard/governance")}function Rl(){return it("/api/v1/dashboard/semantics")}function Nl(){return it("/api/v1/dashboard/mission")}function Pl(){return it("/api/v1/dashboard/planning")}function Ml(){return it("/api/v1/operator")}function Li(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return it(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Ll(){return it("/api/v1/command-plane")}function Dl(){return it("/api/v1/command-plane/summary")}function El(){return it("/api/v1/chains/summary")}function zl(t){return it(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Ol(){return it("/api/v1/command-plane/help")}function jl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const a=n.toString();return it(`/api/v1/command-plane/swarm${a?`?${a}`:""}`)}function Fl(t,e){return Ft(t,e)}function ql(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return fo}}function Va(t){return Ft("/api/v1/operator/action",t,void 0,ql(t))}function Kl(t,e){return Ft("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function ha(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Ul(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Hl(t){if(!K(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const s=J(t.score,0),i=J(t.votes_up,0),r=J(t.votes_down,0),d=J(t.votes,s||i-r),c=J(t.comment_count,J(t.reply_count,0)),m=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(K(k)){const w=h(k.name,"").trim();if(w)return w}return h(t.flair_name,"").trim()||void 0})(),u=h(t.created_at_iso,"").trim()||ha(t.created_at),p=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ha(t.updated_at):u),$=h(t.title,"").trim()||Ul(a);return{id:e,author:n,title:$,content:a,tags:[],votes:d,vote_balance:s,comment_count:c,created_at:u,updated_at:p,flair:m,hearth_count:J(t.hearth_count,0)}}function Wl(t){if(!K(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:ha(t.created_at)}}async function Bl(t){return Mi("fetchBoardPost",async()=>{const e=await it(`/api/v1/board/${t}?format=flat`),n=K(e.post)?e.post:e,a=Hl(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Wl).filter(r=>r!==null);return{...a,comments:i}})}function Di(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:hl()})}function Gl(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Jl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function ut(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Ko(t){const e=Jl(ut(t.outcome,t.result,t.result_code));if(!e)return;const n=ut(t.reason,t.reason_code,t.description,t.detail),a=ut(t.summary,t.summary_ko,t.summary_en,t.note),s=ut(t.details,t.details_text,t.text,t.note),i=ut(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=ut(t.winner_actor_id,t.winner_actor,t.actor_winner_id),d=ut(t.raw_reason,t.raw_reason_code,t.error_message),c=(()=>{const p=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof p=="string"?[p]:Array.isArray(p)?p.map(_=>{if(typeof _=="string")return _.trim();if(K(_)){const $=h(_.summary,"").trim();if($)return $;const k=h(_.text,"").trim();if(k)return k;const A=h(_.type,"").trim();return A||h(_.event_id,"").trim()}return""}).filter(_=>_.length>0):[]})(),m=(()=>{const p=J(t.turn,Number.NaN);if(Number.isFinite(p))return p;const _=J(t.turn_number,Number.NaN);if(Number.isFinite(_))return _;const $=J(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const k=J(t.round,Number.NaN);return Number.isFinite(k)?k:void 0})(),u=ut(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:c.length>0?c:void 0,raw_reason:d||void 0,turn:m,phase:u||void 0}}function Vl(t,e){const n=K(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>K(r)?h(r.type,"")==="session.outcome":!1),i=K(n.session_outcome)?n.session_outcome:{};if(K(i)&&Object.keys(i).length>0){const r=Ko(i);if(r)return r}if(K(s))return Ko(K(s.payload)?s.payload:{})}function K(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function J(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Yl(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Us(t,e=!1){return typeof t=="boolean"?t:e}function nn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(K(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),s=h(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Xl(t){const e={};if(!K(t)&&!Array.isArray(t))return e;if(K(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=h(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!K(n))continue;const a=ut(n.to,n.target,n.actor_id,n.name,n.id),s=ut(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Ql(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function bt(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const Zl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function tc(t){const e=K(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(Zl.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function ec(t,e){if(t!=="dice.rolled")return;const n=J(e.raw_d20,0),a=J(e.total,0),s=J(e.bonus,0),i=h(e.action,"roll"),r=J(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function nc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ac(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function sc(t,e,n,a){const s=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(a.proposed_action,h(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(a.reply,h(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const i=h(a.action,"roll"),r=J(a.total,0),d=J(a.dc,0),c=h(a.label,""),m=s||"actor",u=d>0?` vs DC ${d}`:"",p=c?` (${c})`:"";return`${m} ${i}: ${r}${u}${p}`}case"turn.started":return`Turn ${J(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,K(a.actor)?h(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${J(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${J(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const i=K(a.entity_refs)?a.entity_refs:{},r=h(i.requested_tier,""),d=h(i.effective_tier,""),c=Us(i.guardrail_applied,!1),m=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!d)return m;const u=r&&d?`${r}->${d}`:d||r;return`${m} [${u}${c?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),d=h(a.contract_id,"n/a");return`Canon ${r}: ${d}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const i=nc(a);return i?`${t}: ${i}`:t}}}function oc(t,e){const n=K(t)?t:{},a=h(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[s]||h(K(n.payload)?n.payload.actor_name:"",""),r=K(n.payload)?n.payload:{},d=h(n.ts,h(n.timestamp,new Date().toISOString())),c=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:a,actor:i||s||h(r.actor_name,""),actor_id:s||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:c||void 0,category:m||ac(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:sc(a,s,i,r),dice_roll:ec(a,r),timestamp:d}}function ic(t,e,n){var F,tt;const a=h(t.room_id,"")||n||"default",s=K(t.state)?t.state:{},i=K(s.party)?s.party:{},r=K(s.actor_control)?s.actor_control:{},d=K(s.join_gate)?s.join_gate:{},c=K(s.contribution_ledger)?s.contribution_ledger:{},m=Object.entries(i).map(([W,et])=>{const b=K(et)?et:{},Tt=bt(b,"max_hp",void 0,10),Xt=bt(b,"hp",void 0,Tt),me=bt(b,"max_mp",void 0,0),ve=bt(b,"mp",void 0,0),O=bt(b,"level",void 0,1),It=bt(b,"xp",void 0,0),_e=Us(b.alive,Xt>0),tn=r[W],en=typeof tn=="string"?tn:void 0,Wn=Ql(b.role,W,en),Bn=Yl(b.generation),Gn=ut(b.joined_at,b.joinedAt,b.started_at,b.startedAt),Jn=ut(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),q=ut(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),Te=ut(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),Xr=ut(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:W,name:h(b.name,W),role:Wn,keeper:en,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:nn(b.traits),skills:nn(b.skills),stats_raw:tc(b),status:_e?"active":"dead",generation:Bn,joined_at:Gn||void 0,claimed_at:Jn||void 0,last_seen:q||void 0,scene:Te||void 0,location:Xr||void 0,inventory:nn(b.inventory),notes:nn(b.notes),relationships:Xl(b.relationships),stats:{hp:Xt,max_hp:Tt,mp:ve,max_mp:me,level:O,xp:It,strength:bt(b,"strength","str",10),dexterity:bt(b,"dexterity","dex",10),constitution:bt(b,"constitution","con",10),intelligence:bt(b,"intelligence","int",10),wisdom:bt(b,"wisdom","wis",10),charisma:bt(b,"charisma","cha",10)}}}),u=m.filter(W=>W.status!=="dead"),p=Vl(t,e),_={phase_open:Us(d.phase_open,!0),min_points:J(d.min_points,3),window:h(d.window,"round_boundary_only"),last_opened_turn:typeof d.last_opened_turn=="number"?d.last_opened_turn:null,last_closed_turn:typeof d.last_closed_turn=="number"?d.last_closed_turn:null},$=Object.entries(c).map(([W,et])=>{const b=K(et)?et:{};return{actor_id:W,score:J(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:nn(b.reasons)}}),k=m.reduce((W,et)=>(W[et.id]=et.name,W),{}),A=e.map(W=>oc(W,k)),w=J(s.turn,1),M=h(s.phase,"round"),z=h(s.map,""),E=K(s.world)?s.world:{},I=z||h(E.ascii_map,h(E.map,"")),R=A.filter((W,et)=>{const b=e[et];if(!K(b))return!1;const Tt=K(b.payload)?b.payload:{};return J(Tt.turn,-1)===w}),V=(R.length>0?R:A).slice(-12),G=h(s.status,"active");return{session:{id:a,room:a,status:G==="ended"?"ended":G==="paused"?"paused":"active",round:w,actors:u,created_at:((F=A[0])==null?void 0:F.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:M,events:V,timestamp:((tt=A[A.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:I||void 0,join_gate:_,contribution_ledger:$,outcome:p,party:u,story_log:A,history:[]}}async function rc(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await it(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function lc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([it(`/api/v1/trpg/state${e}`),rc(t)]);return ic(n,a,t)}function cc(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function dc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function uc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function pc(t,e){const n=dc();return Ft("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function mc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Ft("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function vc(t,e,n){return Ft("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function _c(t,e,n){const a=await le("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function fc(t){const e=await le("trpg.mid_join.request",t);return JSON.parse(e)}async function gc(t,e){await le("masc_broadcast",{agent_name:t,message:e})}async function $c(t=40){return(await le("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function hc(t,e=20){return le("masc_task_history",{task_id:t,limit:e})}async function yc(t){const e=await le("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function bc(t){return Mi("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await it(`/api/v1/council/debates/${e}/summary`);if(!K(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:J(n.support_count,0),oppose_count:J(n.oppose_count,0),neutral_count:J(n.neutral_count,0),total_arguments:J(n.total_arguments,0),created_at:ha(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function kc(t,e,n){return le("masc_keeper_msg",{name:t,message:e})}const xc=g(""),Bt=g({}),mt=g({}),Hs=g({}),Ws=g({}),Bs=g({}),Gs=g({}),Gt=g({});function dt(t,e,n){t.value={...t.value,[e]:n}}function Vt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function Y(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function wt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Le(t){return typeof t=="boolean"?t:void 0}function Js(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Vs(t){return Array.isArray(t)?t.map(e=>Y(e)).filter(e=>!!e):[]}function Sc(t){var n;const e=(n=Y(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Ac(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ls(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Vt(a))continue;const s=Y(a.name);if(!s)continue;const i=Y(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function Cc(t){if(!Vt(t))return null;const e=Y(t.name);return e?{name:e,trigger:Y(t.trigger),outcome:Y(t.outcome),summary:Y(t.summary),reason:Y(t.reason)}:null}function wc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Tc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Ei(t,e,n){return Y(t)??Tc(e,n)}function zi(t,e){return typeof t=="boolean"?t:e==="recover"}function ya(t){if(!Vt(t))return null;const e=Y(t.health_state),n=Y(t.next_action_path),a=Y(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:Y(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Js(t.last_reply_at),last_reply_preview:Y(t.last_reply_preview)??null,last_error:Y(t.last_error)??null,next_eligible_at_s:wt(t.next_eligible_at_s)??null,recoverable:zi(t.recoverable,n),summary:Ei(t.summary,e,Y(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Oi(t){return Vt(t)?{hour:wt(t.hour),checked:wt(t.checked)??0,acted:wt(t.acted)??0,acted_names:Vs(t.acted_names),activity_report:Y(t.activity_report),quiet_hours_overridden:Le(t.quiet_hours_overridden),skipped_reason:Y(t.skipped_reason),acted_rows:ls(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ls(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ls(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Cc).filter(e=>e!==null):[]}:null}function Ic(t){return Vt(t)?{enabled:Le(t.enabled)??!1,interval_s:wt(t.interval_s)??0,quiet_start:wt(t.quiet_start),quiet_end:wt(t.quiet_end),quiet_active:Le(t.quiet_active),use_planner:Le(t.use_planner),delegate_llm:Le(t.delegate_llm),agent_count:wt(t.agent_count),agents:Vs(t.agents),last_tick_ago_s:wt(t.last_tick_ago_s)??null,last_tick_ago:Y(t.last_tick_ago),total_ticks:wt(t.total_ticks),total_checkins:wt(t.total_checkins),last_skip_reason:Y(t.last_skip_reason)??null,last_tick_result:Oi(t.last_tick_result),active_self_heartbeats:Vs(t.active_self_heartbeats)}:null}function Rc(t){return Vt(t)?{status:t.status,diagnostic:ya(t.diagnostic)}:null}function Nc(t){return Vt(t)?{recovered:Le(t.recovered)??!1,skipped_reason:Y(t.skipped_reason)??null,before:ya(t.before),after:ya(t.after),down:t.down,up:t.up}:null}function Pc(t,e){var z,E;if(!(t!=null&&t.name))return null;const n=Y((z=t.agent)==null?void 0:z.status)??Y(t.status)??"unknown",a=Y((E=t.agent)==null?void 0:E.error)??null,s=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,d=t.last_turn_ago_s??null,c=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,p=c&&u!=null?Math.max(0,m-u):null,_=r<=0||d==null?"never":d>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,k=a??(s&&!i?"keeper keepalive is not running":null),A=n==="offline"||n==="inactive"?"offline":k?"degraded":_==="stale"?"stale":_==="never"?"idle":"healthy",w=k?wc(k):e!=null&&e.quiet_active&&_!=="fresh"?"quiet_hours":s&&!i?"disabled":r<=0?"never_started":p!=null&&p>0?"min_gap":_==="fresh"||_==="stale"?"no_recent_activity":"unknown",M=A==="offline"||A==="degraded"||A==="stale"?"recover":w==="quiet_hours"?"manual_lodge_poke":w==="unknown"?"probe":"direct_message";return{health_state:A,quiet_reason:w,next_action_path:M,last_reply_status:_,last_reply_at:$,last_reply_preview:null,last_error:k,next_eligible_at_s:p!=null&&p>0?p:null,recoverable:zi(void 0,M),summary:Ei(void 0,A,w),keepalive_running:i}}function Mc(t,e){if(!Vt(t))return null;const n=Sc(t.role),a=Y(t.content)??Y(t.preview);if(!a)return null;const s=Js(t.ts_unix)??Js(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:Ac(n),text:a,timestamp:s,delivery:"history"}}function Lc(t,e,n){const a=Vt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>Mc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:ya(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Uo(t,e){const n=mt.value[t]??[];mt.value={...mt.value,[t]:[...n,e].slice(-50)}}function Dc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Ec(t,e){const a=(mt.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(i=>Dc(s,i)));mt.value={...mt.value,[t]:[...e,...a].slice(-50)}}function Ya(t,e){Bt.value={...Bt.value,[t]:e},Ec(t,e.history)}function Ho(t,e){const n=Bt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ya(t,{...n,diagnostic:{...a,...e}})}async function $o(){try{await On()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function zc(t){xc.value=t.trim()}async function ji(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Bt.value[n])return Bt.value[n];dt(Hs,n,!0),dt(Gt,n,null);try{const a=await le("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const i=Lc(n,a,s);return Ya(n,i),i}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return dt(Gt,n,s),null}finally{dt(Hs,n,!1)}}async function Oc(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;Uo(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),dt(Ws,n,!0),dt(Gt,n,null);try{const i=await kc(n,a);mt.value={...mt.value,[n]:(mt.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},Uo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Ho(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await $o()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw mt.value={...mt.value,[n]:(mt.value[n]??[]).map(d=>d.id===s?{...d,delivery:"error",error:r}:d)},Ho(n,{last_reply_status:"error",last_error:r}),dt(Gt,n,r),i}finally{dt(Ws,n,!1)}}async function jc(t,e){const n=t.trim();if(!n)return null;dt(Bs,n,!0),dt(Gt,n,null);try{const a=await Va({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Rc(a.result),i=(s==null?void 0:s.diagnostic)??null;if(i){const r=Bt.value[n];Ya(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??mt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await $o(),i}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw dt(Gt,n,s),a}finally{dt(Bs,n,!1)}}async function Fc(t,e){const n=t.trim();if(!n)return null;dt(Gs,n,!0),dt(Gt,n,null);try{const a=await Va({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Nc(a.result),i=(s==null?void 0:s.after)??null;if(i){const r=Bt.value[n];Ya(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??mt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await $o(),i}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw dt(Gt,n,s),a}finally{dt(Gs,n,!1)}}function fe(t){return(t??"").trim().toLowerCase()}function $t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function la(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Vn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function an(t){return t.last_heartbeat??Vn(t.last_turn_ago_s)??Vn(t.last_proactive_ago_s)??Vn(t.last_handoff_ago_s)??Vn(t.last_compaction_ago_s)}function qc(t){const e=t.title.trim();return e||la(t.content)}function Kc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Uc(t,e,n,a,s={}){var E;const i=fe(t),r=e.filter(I=>fe(I.assignee)===i&&(I.status==="claimed"||I.status==="in_progress")).length,d=n.filter(I=>fe(I.from)===i).sort((I,R)=>$t(R.timestamp)-$t(I.timestamp))[0],c=a.filter(I=>fe(I.agent)===i||fe(I.author)===i).sort((I,R)=>$t(R.timestamp)-$t(I.timestamp))[0],m=(s.boardPosts??[]).filter(I=>fe(I.author)===i).sort((I,R)=>$t(R.updated_at||R.created_at)-$t(I.updated_at||I.created_at))[0],u=(s.keepers??[]).filter(I=>fe(I.name)===i&&an(I)!==null).sort((I,R)=>$t(an(R)??0)-$t(an(I)??0))[0],p=d?$t(d.timestamp):0,_=c?$t(c.timestamp):0,$=m?$t(m.updated_at||m.created_at):0,k=u?$t(an(u)??0):0,A=s.lastSeen?$t(s.lastSeen):0,w=((E=s.currentTask)==null?void 0:E.trim())||(r>0?`${r} claimed tasks`:null);if(p===0&&_===0&&$===0&&k===0&&A===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:w};const z=[d?{timestamp:d.timestamp,ts:p,text:la(d.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${la(qc(m))}`}:null,u?{timestamp:an(u),ts:k,text:Kc(u)}:null,c?{timestamp:new Date(c.timestamp).toISOString(),ts:_,text:la(c.text)}:null].filter(I=>I!==null).sort((I,R)=>R.ts-I.ts)[0];return z&&z.ts>=A?{activeAssignedCount:r,lastActivityAt:z.timestamp,lastActivityText:z.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}const Yt=g([]),Et=g([]),Be=g([]),ce=g([]),Fe=g(null),Hc=g(null),Ys=g(new Map),Xa=g([]),$n=g("hot"),De=g(!0),Fi=g(null),Wt=g(""),hn=g([]),Ee=g(!1),qi=g(new Map),ho=g("unknown"),ba=g(null),Xs=g(!1),yn=g(!1),Qs=g(!1),ze=g(!1),yo=g(null),ka=g(!1),xa=g(null),Ki=g(null),Zs=g(null),Ui=g(null),Hi=g(null),Wc=g(null);re(()=>Yt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Bc=re(()=>{const t=Et.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Wi=re(()=>{const t=new Map,e=Et.value,n=Be.value,a=Fs.value,s=Xa.value,i=ce.value;for(const r of Yt.value)t.set(r.name.trim().toLowerCase(),Uc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:s,keepers:i}));return t});function Gc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Jc=re(()=>{const t=new Map;for(const e of ce.value)t.set(e.name,Gc(e));return t}),Vc=12e4;function Yc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Xc=re(()=>{const t=Date.now(),e=new Set,n=Ys.value;for(const a of ce.value){const s=Yc(a,n);s!=null&&t-s>Vc&&e.add(a.name)}return e});let cs=null;function Qc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function ct(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function C(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Mt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function to(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Bi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Zc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function td(t){if(!ct(t))return null;const e=y(t.name);return e?{name:e,agent_type:y(t.agent_type),status:Bi(t.status),current_task:y(t.current_task)??null,joined_at:y(t.joined_at),last_seen:y(t.last_seen),capabilities:Mt(t.capabilities),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:Mt(t.traits),interests:Mt(t.interests),activityLevel:C(t.activityLevel)??C(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function ed(t){if(!ct(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:Zc(t.status),priority:C(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function nd(t){if(!ct(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",a=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:C(t.seq),from:e,content:n,timestamp:a,type:y(t.type)}}function Wo(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function ad(t,e){if(e.length===0)return t;const n=new Map;for(const a of t){const s=typeof a.seq=="number"?`seq:${a.seq}`:`ts:${a.timestamp}|from:${a.from}|content:${a.content}`;n.set(s,a)}for(const a of e){const s=typeof a.seq=="number"?`seq:${a.seq}`:`ts:${a.timestamp}|from:${a.from}|content:${a.content}`;n.set(s,a)}return[...n.values()].sort((a,s)=>Wo(a)-Wo(s)).slice(-500)}function sd(t){return Array.isArray(t)?t.map(e=>{if(!ct(e))return null;const n=C(e.ts_unix);if(n==null)return null;const a=ct(e.handoff)?e.handoff:null;return{ts:n,context_ratio:C(e.context_ratio)??0,context_tokens:C(e.context_tokens)??0,context_max:C(e.context_max)??0,latency_ms:C(e.latency_ms)??0,generation:C(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:C(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:C(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?C(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Bo(t){if(!ct(t))return null;const e=y(t.health_state),n=y(t.next_action_path),a=y(t.last_reply_status);if(!e||!n||!a)return null;const s=y(t.quiet_reason)??null,i=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":s==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":s==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":s==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:s,next_action_path:n,last_reply_status:a,last_reply_at:to(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:C(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function od(t,e){return(Array.isArray(t)?t:ct(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!ct(a))return null;const s=ct(a.agent)?a.agent:null,i=ct(a.context)?a.context:null,r=ct(a.metrics_window)?a.metrics_window:void 0,d=y(a.name);if(!d)return null;const c=C(a.context_ratio)??C(i==null?void 0:i.context_ratio),m=y(a.status)??y(s==null?void 0:s.status)??"offline",u=Bi(m),p=y(a.model)??y(a.active_model)??y(a.primary_model),_=Mt(a.skill_secondary),$=i?{source:y(i.source),context_ratio:C(i.context_ratio),context_tokens:C(i.context_tokens),context_max:C(i.context_max),message_count:C(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,k=s?{name:y(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:y(s.error),agent_type:y(s.agent_type),status:y(s.status),current_task:y(s.current_task)??null,joined_at:y(s.joined_at),last_seen:y(s.last_seen),last_seen_ago_s:C(s.last_seen_ago_s),capabilities:Mt(s.capabilities),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,A=sd(a.metrics_series),w={name:d,emoji:y(a.emoji),koreanName:y(a.koreanName)??y(a.korean_name),agent_name:y(a.agent_name),trace_id:y(a.trace_id),model:p,primary_model:y(a.primary_model),active_model:y(a.active_model),next_model_hint:y(a.next_model_hint)??null,status:u,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:C(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:C(a.proactive_idle_sec),proactive_cooldown_sec:C(a.proactive_cooldown_sec),last_heartbeat:y(a.last_heartbeat)??y(s==null?void 0:s.last_seen),generation:C(a.generation),turn_count:C(a.turn_count)??C(a.total_turns),keeper_age_s:C(a.keeper_age_s),last_turn_ago_s:C(a.last_turn_ago_s),last_handoff_ago_s:C(a.last_handoff_ago_s),last_compaction_ago_s:C(a.last_compaction_ago_s),last_proactive_ago_s:C(a.last_proactive_ago_s),last_proactive_preview:y(a.last_proactive_preview)??null,context_ratio:c,context_tokens:C(a.context_tokens)??C(i==null?void 0:i.context_tokens),context_max:C(a.context_max)??C(i==null?void 0:i.context_max),context_source:y(a.context_source)??y(i==null?void 0:i.source),context:$,traits:Mt(a.traits),interests:Mt(a.interests),primaryValue:y(a.primaryValue)??y(a.primary_value),activityLevel:C(a.activityLevel)??C(a.activity_level),memory_recent_note:y(a.memory_recent_note)??null,recent_input_preview:y(a.recent_input_preview)??null,recent_output_preview:y(a.recent_output_preview)??null,recent_tool_names:Mt(a.recent_tool_names)??[],conversation_tail_count:C(a.conversation_tail_count),k2k_count:C(a.k2k_count),handoff_count_total:C(a.handoff_count_total)??C(a.trace_history_count),compaction_count:C(a.compaction_count),last_compaction_saved_tokens:C(a.last_compaction_saved_tokens),diagnostic:Bo(a.diagnostic),skill_primary:y(a.skill_primary)??null,skill_secondary:_,skill_reason:y(a.skill_reason)??null,metrics_series:A.length>0?A:void 0,metrics_window:r,agent:k};return w.diagnostic=Bo(a.diagnostic)??Pc(w,(e==null?void 0:e.lodge)??null),w}).filter(a=>a!==null)}function Gi(t){return ct(t)?{...t,lodge:Ic(t.lodge)??void 0}:null}function id(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function rd(t){if(!ct(t))return null;const e=C(t.iteration);if(e==null)return null;const n=C(t.metric_before)??0,a=C(t.metric_after)??n,s=ct(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:C(t.delta)??a-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:C(t.elapsed_ms)??0,cost_usd:C(t.cost_usd)??null,evidence:s?{worker_engine:(s.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(s.worker_model)??"",tool_call_count:C(s.tool_call_count)??0,tool_names:Mt(s.tool_names)??[],session_id:y(s.session_id)??"",evidence_status:s.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function ld(t){var i,r;if(!ct(t))return null;const e=y(t.loop_id);if(!e)return null;const n=C(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map(rd).filter(d=>d!==null):[],s=C(t.current_metric)??((i=a[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:id(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:C(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:C(t.max_iterations)??0,baseline_metric:n,current_metric:s,target:y(t.target)??"",stagnation_streak:C(t.stagnation_streak)??0,stagnation_limit:C(t.stagnation_limit)??0,elapsed_seconds:C(t.elapsed_seconds)??0,updated_at:to(t.updated_at)??null,stopped_at:to(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:C(t.latest_tool_call_count)??0,latest_tool_names:Mt(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function On(){Xs.value=!0;try{await Promise.all([Vi(),Kt()]),Ki.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Xs.value=!1}}async function Ji(){ka.value=!0,xa.value=null;try{const t=await Rl();yo.value=t,Wc.value=new Date().toISOString()}catch(t){xa.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ka.value=!1}}function cd(t){var e;return((e=yo.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function dd(t){var n;const e=((n=yo.value)==null?void 0:n.surfaces)??[];for(const a of e){const s=a.panels.find(i=>i.id===t);if(s)return s}return null}function ud(t){var a,s;hn.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!ct(i))return null;const r=y(i.id),d=y(i.title),c=y(i.horizon),m=y(i.status),u=y(i.created_at),p=y(i.updated_at);return!r||!d||!c||!m||!u||!p?null:{id:r,horizon:c,title:d,metric:y(i.metric)??null,target_value:y(i.target_value)??null,due_date:y(i.due_date)??null,priority:C(i.priority)??3,status:m,parent_goal_id:y(i.parent_goal_id)??null,last_review_note:y(i.last_review_note)??null,last_review_at:y(i.last_review_at)??null,created_at:u,updated_at:p}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((a=t.mdal)==null?void 0:a.loops)?t.mdal.loops:[];for(const i of n){const r=ld(i);r&&e.set(r.loop_id,r)}qi.value=e,ba.value=typeof((s=t.mdal)==null?void 0:s.error)=="string"?t.mdal.error:null,ho.value=ba.value?"error":e.size===0?"idle":"ready"}async function Vi(){try{const t=await Cl(),e=Gi(t.status);e&&(Fe.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Kt(){var t;try{const e=await wl(),n=Gi(e.status),a=(t=Fe.value)==null?void 0:t.room;n&&(Fe.value=n);const s=a!=null&&(n==null?void 0:n.room)!=null&&a!==n.room;Yt.value=(Array.isArray(e.agents)?e.agents:[]).map(td).filter(r=>r!==null),Et.value=(Array.isArray(e.tasks)?e.tasks:[]).map(ed).filter(r=>r!==null);const i=(Array.isArray(e.messages)?e.messages:[]).map(nd).filter(r=>r!==null);Be.value=s?i:ad(Be.value,i),ce.value=od(e.keepers,n??Fe.value),Hc.value=null,Ki.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function zt(){yn.value=!0;try{const t=await Tl($n.value,{excludeSystem:De.value});Xa.value=t.posts??[],Zs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{yn.value=!1}}async function Ot(){var t;Qs.value=!0;try{const e=Wt.value||((t=Fe.value)==null?void 0:t.room)||"default";Wt.value||(Wt.value=e);const n=await lc(e);Fi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Qs.value=!1}}async function Ge(){Ee.value=!0,ze.value=!0;try{const t=await Pl();ud(t),Ui.value=new Date().toISOString(),Hi.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),ho.value="error",ba.value=t instanceof Error?t.message:String(t)}finally{Ee.value=!1,ze.value=!1}}async function eo(){return Ge()}let ca=null;function pd(t){ca=t}let da=null;function md(t){da=t}let ua=null;function vd(t){ua=t}const he={};function ge(t,e,n=500){he[t]&&clearTimeout(he[t]),he[t]=setTimeout(()=>{e(),delete he[t]},n)}function _d(){const t=wi.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Ys.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Ys.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ge("execution",Kt),Qc(e.type)&&(cs||(cs=setTimeout(()=>{On(),da==null||da(),ua==null||ua(),cs=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ge("execution",Kt),e.type==="broadcast"&&ge("execution",Kt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ge("execution",Kt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ge("board",zt),e.type.startsWith("decision_")&&ge("council",()=>ca==null?void 0:ca()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ge("mdal",eo,350)}});return()=>{t();for(const e of Object.keys(he))clearTimeout(he[e]),delete he[e]}}let dn=null;function fd(){dn||(dn=setInterval(()=>{Se.value,On()},1e4))}function gd(){dn&&(clearInterval(dn),dn=null)}function $d({metric:t}){return o`
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
  `}function hd({panel:t}){return o`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${t.purpose}</span>
        <span>Solves</span><span>${t.problem_solved}</span>
        <span>When</span><span>${t.when_active}</span>
        <span>Agent Role</span><span>${t.agent_role}</span>
        <span>Ecosystem</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?o`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?o`<div class="semantic-metric-list">
            ${t.metrics.map(e=>o`<${$d} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function D({panelId:t,compact:e=!1,label:n="Why"}){const a=dd(t);return a?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${hd} panel=${a} />
    </details>
  `:ka.value?o`<span class="semantic-inline-state">Loading semantics…</span>`:null}function xt({surfaceId:t,compact:e=!1}){const n=cd(t);return n?o`
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
      ${n.panels.length>0?o`<div class="semantic-tag-row">
            ${n.panels.map(a=>o`<span class="semantic-tag">${a.title}</span>`)}
          </div>`:null}
    </section>
  `:ka.value?o`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:xa.value?o`<div class="semantic-surface-card ${e?"compact":""}">${xa.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:a}){return o`
    <div class="card ${e??""}">
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${D} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const Qa=g(null),no=g(!1),Sa=g(null);function U(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function N(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function B(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function bo(t){return typeof t=="boolean"?t:void 0}function Ut(t,e=[]){if(Array.isArray(t))return t;if(!U(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Za(t){if(!U(t))return null;const e=N(t.kind),n=N(t.summary),a=N(t.target_type);return!e||!n||!a?null:{kind:e,severity:N(t.severity)??"warn",summary:n,target_type:a,target_id:N(t.target_id)??null,actor:N(t.actor)??null,evidence:t.evidence}}function ts(t){if(!U(t))return null;const e=N(t.action_type),n=N(t.target_type),a=N(t.reason);return!e||!n||!a?null:{action_type:e,target_type:n,target_id:N(t.target_id)??null,severity:N(t.severity)??"warn",reason:a,confirm_required:bo(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function yd(t){if(!U(t))return null;const e=N(t.session_id);return e?{session_id:e,goal:N(t.goal),status:N(t.status),health:N(t.health),scale_profile:N(t.scale_profile),control_profile:N(t.control_profile),planned_worker_count:B(t.planned_worker_count),active_agent_count:B(t.active_agent_count),last_turn_age_sec:B(t.last_turn_age_sec)??null,attention_count:B(t.attention_count),recommended_action_count:B(t.recommended_action_count),top_attention:Za(t.top_attention),top_recommendation:ts(t.top_recommendation)}:null}function bd(t){if(!U(t))return null;const e=N(t.session_id);if(!e)return null;const n=U(t.status)?t.status:t,a=U(n.summary)?n.summary:void 0;return{session_id:e,status:N(t.status)??N(a==null?void 0:a.status)??(U(n.session)?N(n.session.status):void 0),progress_pct:B(t.progress_pct)??B(a==null?void 0:a.progress_pct),elapsed_sec:B(t.elapsed_sec)??B(a==null?void 0:a.elapsed_sec),remaining_sec:B(t.remaining_sec)??B(a==null?void 0:a.remaining_sec),done_delta_total:B(t.done_delta_total)??B(a==null?void 0:a.done_delta_total),summary:U(t.summary)?t.summary:a,team_health:U(t.team_health)?t.team_health:U(n.team_health)?n.team_health:void 0,communication_metrics:U(t.communication_metrics)?t.communication_metrics:U(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:U(t.orchestration_state)?t.orchestration_state:U(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:U(t.cascade_metrics)?t.cascade_metrics:U(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:U(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([s,i])=>{const r=N(i);return r?[s,r]:null}).filter(s=>s!==null)):U(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([s,i])=>{const r=N(i);return r?[s,r]:null}).filter(s=>s!==null)):void 0,session:U(t.session)?t.session:U(n.session)?n.session:void 0,recent_events:Ut(t.recent_events,["events"]).filter(U)}}function kd(t){if(!U(t))return null;const e=N(t.name);return e?{name:e,agent_name:N(t.agent_name),status:N(t.status),autonomy_level:N(t.autonomy_level),context_ratio:B(t.context_ratio),generation:B(t.generation),active_goal_ids:Ut(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:N(t.last_autonomous_action_at)??null,last_turn_ago_s:B(t.last_turn_ago_s),model:N(t.model)}:null}function xd(t){if(!U(t))return null;const e=N(t.confirm_token)??N(t.token);return e?{confirm_token:e,actor:N(t.actor),action_type:N(t.action_type),target_type:N(t.target_type),target_id:N(t.target_id)??null,delegated_tool:N(t.delegated_tool),created_at:N(t.created_at),preview:t.preview}:null}function Sd(t){if(!U(t))return null;const e=N(t.action_type),n=N(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:N(t.description),confirm_required:bo(t.confirm_required)}}function Ad(t){const e=U(t)?t:{};return{room_health:N(e.room_health),cluster:N(e.cluster),project:N(e.project),current_room:N(e.current_room)??null,paused:bo(e.paused),tempo_interval_s:B(e.tempo_interval_s),active_agents:B(e.active_agents),keeper_pressure:B(e.keeper_pressure),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),incident_count:B(e.incident_count),recommended_action_count:B(e.recommended_action_count),top_attention:Za(e.top_attention),top_action:ts(e.top_action)}}function Cd(t){const e=U(t)?t:{},n=U(e.swarm_overview)?e.swarm_overview:{};return{health:N(e.health),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),swarm_overview:{active_lanes:B(n.active_lanes),moving_lanes:B(n.moving_lanes),stalled_lanes:B(n.stalled_lanes),projected_lanes:B(n.projected_lanes),last_movement_at:N(n.last_movement_at)??null},top_attention:Za(e.top_attention),top_action:ts(e.top_action),session_cards:Ut(e.session_cards).map(yd).filter(a=>a!==null)}}function wd(t){const e=U(t)?t:{};return{sessions:Ut(e.sessions,["items"]).map(bd).filter(n=>n!==null),keepers:Ut(e.keepers,["items"]).map(kd).filter(n=>n!==null),pending_confirms:Ut(e.pending_confirms).map(xd).filter(n=>n!==null),available_actions:Ut(e.available_actions).map(Sd).filter(n=>n!==null)}}function Td(t){const e=U(t)?t:{};return{generated_at:N(e.generated_at),summary:Ad(e.summary),incidents:Ut(e.incidents).map(Za).filter(n=>n!==null),recommended_actions:Ut(e.recommended_actions).map(ts).filter(n=>n!==null),command_focus:Cd(e.command_focus),operator_targets:wd(e.operator_targets)}}async function pa(){no.value=!0,Sa.value=null;try{const t=await Nl();Qa.value=Td(t)}catch(t){Sa.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{no.value=!1}}function de({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Id(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function ot({timestamp:t}){const e=Id(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}let Rd=0;const ye=g([]);function P(t,e="success",n=4e3){const a=++Rd;ye.value=[...ye.value,{id:a,message:t,type:e}],setTimeout(()=>{ye.value=ye.value.filter(s=>s.id!==a)},n)}function Nd(t){ye.value=ye.value.filter(e=>e.id!==t)}function Pd(){const t=ye.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Nd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Md="masc_dashboard_agent_name",Qe=g(null),Aa=g(!1),bn=g(""),Ca=g([]),kn=g([]),qe=g(""),un=g(!1);function es(t){Qe.value=t,ko()}function Go(){Qe.value=null,bn.value="",Ca.value=[],kn.value=[],qe.value=""}function Ld(){const t=Qe.value;return t?Yt.value.find(e=>e.name===t)??null:null}function Yi(t){return t?Et.value.filter(e=>e.assignee===t):[]}async function ko(){const t=Qe.value;if(t){Aa.value=!0,bn.value="",Ca.value=[],kn.value=[];try{const e=await $c(80);Ca.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Yi(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await hc(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));kn.value=a}catch(e){bn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Aa.value=!1}}}async function Jo(){var a;const t=Qe.value,e=qe.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(Md))==null?void 0:a.trim())||"dashboard";un.value=!0;try{await gc(n,`@${t} ${e}`),qe.value="",P(`Mention sent to ${t}`,"success"),ko()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";P(i,"error")}finally{un.value=!1}}function Dd({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${de} status=${t.status} />
    </div>
  `}function Ed({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function zd(){var s,i,r,d;const t=Qe.value;if(!t)return null;const e=Ld(),n=Yi(t),a=Ca.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${c=>{c.target.classList.contains("agent-detail-overlay")&&Go()}}
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
                        <${de} status=${e.status} />
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
            ${(((s=e==null?void 0:e.traits)==null?void 0:s.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(c=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${c}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(d=e==null?void 0:e.interests)==null?void 0:d.map(c=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${c}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${ot} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ko()}} disabled=${Aa.value}>
              ${Aa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Go}>Close</button>
          </div>
        </div>

        ${bn.value?o`<div class="council-error">${bn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(c=>o`<${Dd} key=${c.id} task=${c} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((c,m)=>o`<div key=${m} class="agent-activity-line">${c}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Task History">
          ${kn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${kn.value.map(c=>o`<${Ed} key=${c.taskId} row=${c} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${qe.value}
              onInput=${c=>{qe.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Jo()}}
              disabled=${un.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Jo()}}
              disabled=${un.value||qe.value.trim()===""}
            >
              ${un.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Od(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function jd(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Fd(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Vo(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Xi(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function qd(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Qi(t){if(!t)return null;const e=Bt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Kd({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&ji(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Bt.value[t.name],a=Qi(t),s=Hs.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${Od(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${jd((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?o` · ${Xi(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?o` · next eligible ${qd(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?o`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Ud({keeperName:t,placeholder:e}){const[n,a]=xi("");rt(()=>{t&&ji(t)},[t]);const s=mt.value[t]??[],i=Ws.value[t]??!1,r=Gt.value[t],d=async()=>{const c=n.trim();if(!(!t||!c)){a("");try{await Oc(t,c)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${t}`;P(u,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(c=>o`
              <div class="keeper-conversation-item" key=${c.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Vo(c)}`}>${c.label}</span>
                  <span class=${`keeper-role-chip ${Vo(c)}`}>${Fd(c)}</span>
                  ${c.timestamp?o`<span class="keeper-conversation-time">${Xi(c.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${c.text}</div>
                ${c.error?o`<div class="keeper-conversation-error">${c.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${c=>{a(c.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{d()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Hd({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=Qi(e),s=Bs.value[e.name]??!1,i=Gs.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",d=(a==null?void 0:a.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{jc(e.name,t).catch(c=>{const m=c instanceof Error?c.message:`Failed to probe ${e.name}`;P(m,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Fc(e.name,t).catch(c=>{const m=c instanceof Error?c.message:`Failed to recover ${e.name}`;P(m,"error")})}}
        disabled=${i||!d||!t.trim()}
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
  `}const xo=g(null);function So(t){xo.value=t,zc(t.name)}function Yo(){xo.value=null}const Pe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Wd(t){if(!t)return 0;const e=Pe.findIndex(n=>n.level===t);return e>=0?e:0}function Bd({keeper:t}){const e=Wd(t.autonomy_level),n=Pe[e]??Pe[0];if(!n)return null;const a=(e+1)/Pe.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Pe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Pe.map((s,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?s.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${ot} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ma(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Gd({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ma(t.context_tokens)}</div>
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
  `}function Jd({keeper:t}){var u,p;const e=t.metrics_series??[];if(e.length<2){const _=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,$=_>85?"#ef4444":_>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${_.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${_.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((_,$)=>{const k=s+$/(i-1)*(n-2*s),A=a-s-(_.context_ratio??0)*(a-2*s);return{x:k,y:A,p:_}}),d=r.map(({x:_,y:$})=>`${_.toFixed(1)},${$.toFixed(1)}`).join(" "),c=(((p=e[e.length-1])==null?void 0:p.context_ratio)??0)*100,m=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:_})=>_.is_handoff).map(({x:_})=>o`
          <line x1="${_.toFixed(1)}" y1="${s}" x2="${_.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${d}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:_})=>_.is_compaction).map(({x:_,y:$})=>o`
          <circle cx="${_.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${c.toFixed(1)}%</span>
    </div>`}const ds=g("");function Vd({keeper:t}){var s,i,r,d;const e=ds.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(c=>c.title.toLowerCase().includes(e)||c.key.includes(e)||c.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ds.value}
        onInput=${c=>{ds.value=c.target.value}}
      />
      ${a.map(c=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${c.title}</span>
          <span class="keeper-field-key">${c.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${c.value}</span>
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ma(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ma(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ma(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((d=t.context)==null?void 0:d.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Yd({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>o`
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
  `}function Xd({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Qd({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Xo({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function us(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Zd({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:us(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:us(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:us(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Zi(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function tu(){try{const t=await Va({actor:Zi(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Oi(t.result);await On(),e!=null&&e.skipped_reason?P(e.skipped_reason,"warning"):P(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";P(e,"error")}}function eu({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Kd} keeper=${t} />
          <${Hd}
            actor=${Zi()}
            keeper=${t}
            onPokeLodge=${()=>{tu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Ud}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function nu(){var e,n,a;const t=xo.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Yo()}}
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
            <${de} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Yo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Gd} keeper=${t} />

        ${""}
        <${Jd} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${Vd} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${Xo} traits=${t.traits??[]} label="Traits" />
            <${Xo} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${ot} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${T} title="Autonomy">
                <${Bd} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${Yd} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${T} title="Equipment (${t.inventory.length})">
                <${Xd} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${Qd} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${Zd} keeper=${t} />
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
                  ${t.context_max??((a=t.context)==null?void 0:a.context_max)??"-"}
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
        <${eu} keeper=${t} />
      </div>
    </div>
  `:null}const wa="masc_dashboard_workflow_context",au=900*1e3;function Ao(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function Ct(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Qt(t){const e=Ct(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function tr(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function ao(t){return Ao(t)?t:null}function su(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function ou(t){if(!t)return null;try{const e=JSON.parse(t);if(!Ao(e))return null;const n=Ct(e.id),a=Ct(e.source_surface),s=Ct(e.source_label),i=Ct(e.summary),r=Ct(e.created_at);return!n||a!=="mission"||!s||!i||!r?null:{id:n,source_surface:"mission",source_label:s,action_type:Ct(e.action_type),target_type:Ct(e.target_type),target_id:Ct(e.target_id),focus_kind:Ct(e.focus_kind),summary:i,payload_preview:Ct(e.payload_preview),suggested_payload:ao(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function Co(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=au}function iu(){const t=tr(),e=ou((t==null?void 0:t.getItem(wa))??null);return e?Co(e)?e:(t==null||t.removeItem(wa),null):null}const er=g(iu());function ru(t){const e=t&&Co(t)?t:null;er.value=e;const n=tr();if(!n)return;if(!e){n.removeItem(wa);return}const a=su(e);a&&n.setItem(wa,a)}function nr(t){if(!t)return null;const e=ao(t.suggested_payload);if(e)return e;if(Ao(t.preview)){const n=ao(t.preview.payload);if(n)return n}return null}function ar(t){if(!t)return null;const e=Qt(t.message);if(e)return e;const n=Qt(t.task_title)??Qt(t.title),a=Qt(t.task_description)??Qt(t.description),s=Qt(t.reason),i=Qt(t.priority)??Qt(t.task_priority);return n&&a?`${n} · ${a}`:n&&i?`${n} · P${i}`:n||a||s||null}function sr(t,e,n,a,s,i){return["mission",t,e??"action",n??"target",a??"room",s??"focus",i].join(":")}function Ze(t,e,n="상황판 추천 액션"){const a=new Date().toISOString(),s=nr(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,d=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,c=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:sr(n,(t==null?void 0:t.action_type)??null,i,r,d,a),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:r,focus_kind:d,summary:c,payload_preview:ar(s),suggested_payload:s,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:a}}function lu(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function jn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=er.value;if(n&&Co(n)&&lu(n,e))return n;const a=new Date().toISOString();return{id:sr("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,a),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:a}}function cu(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function or(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function du(t){return{source:"mission",surface:or(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function wo(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function To(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function uu(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function yt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function pt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function xn(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function ps(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function nt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function St(t){return t==="bad"||t==="offline"||t==="critical"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"?"warn":"ok"}function Ae(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function pu(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function Qo(t){const e=xn(t.ts);if(e!=null)return e;const n=pt(t.ts_iso);if(!n)return 0;const a=Date.parse(n);return Number.isNaN(a)?0:a}function mu(t){return[...new Set(t.filter(Boolean))]}function vu(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function _u(t){return ar(nr(t))}function fu(t){return wo(t?Ze(t,null,"상황판 추천 액션"):null)}function ns(t,e=Ze()){ru(e),gt(t,t==="intervene"?cu(e):du(e))}function gu(t){ns("intervene",Ze(null,t,"상황판 incident"))}function $u(t){ns("command",Ze(null,t,"상황판 incident"))}function hu(t,e,n="상황판 추천 액션"){ns("intervene",Ze(t,e,n))}function yu(t,e,n="상황판 추천 액션"){ns("command",Ze(t,e,n))}function Zo(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),gt(t,n)}function ir(t,e){const n=t.trim().toLowerCase();return[...e].filter(a=>(a.from??"").trim().toLowerCase()===n).sort((a,s)=>Date.parse(s.timestamp)-Date.parse(a.timestamp))[0]??null}function bu(t,e){const n=t.trim().toLowerCase();return[...e].filter(a=>{if((a.from??"").trim().toLowerCase()===n)return!1;const i=(a.content??"").trim().toLowerCase();return i.includes(`@${n}`)||i.includes(n)}).sort((a,s)=>Date.parse(s.timestamp)-Date.parse(a.timestamp))[0]??null}function ku(t){const e=yt(t.session)?t.session:{},n=yt(t.summary)?t.summary:{};return mu([...ps(e.agent_names),...ps(n.active_agents),...ps(n.planned_participants)])}function xu(t){const e=yt(t.session)?t.session:{};return pt(e.goal)??pt(e.session_id)??t.session_id}function Su(t){const e=yt(t.session)?t.session:{};return pt(e.room_id)}function Au(t){const e=yt(t.session)?t.session:{};return pt(e.created_at_iso)}function Cu(t){const e=yt(t.session)?t.session:{};return pt(e.updated_at_iso)}function wu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return pt(e.mode)}function Tu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return xn(e.broadcast_count)??0}function Iu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return xn(e.portal_count)??0}function Ru(t){const e=yt(t.team_health)?t.team_health:{};return{active:xn(e.active_agents_count)??0,required:xn(e.required_agents)??0}}function Nu(t){const n=[...t.recent_events??[]].sort((u,p)=>Qo(p)-Qo(u))[0];if(!n)return{at:null,summary:"최근 session event가 없습니다."};const a=yt(n.detail)?n.detail:{},s=pt(n.event_type)??"event",i=pt(a.actor),r=pt(a.task_title)??pt(a.title),d=nt(pt(a.result),120),c=nt(pt(a.reason),120),m=r?`${i?`${i} · `:""}${r}`:d??c??s.replace(/_/g," ");return{at:pt(n.ts_iso),summary:m}}function Pu(){const t=Qa.value;return t?t.operator_targets.sessions.map(e=>{var i,r;const n=Ru(e),a=Nu(e),s=t.command_focus.session_cards.find(d=>d.session_id===e.session_id);return{session:e,goal:xu(e),room:Su(e),status:e.status??"unknown",memberNames:ku(e),startedAt:Au(e),stoppedAt:Cu(e),elapsedSec:e.elapsed_sec??null,lastEventAt:a.at,lastEventSummary:a.summary,communicationMode:wu(e),broadcastCount:Tu(e),portalCount:Iu(e),activeCount:n.active,requiredCount:n.required,attentionSummary:((i=s==null?void 0:s.top_attention)==null?void 0:i.summary)??((r=s==null?void 0:s.top_recommendation)==null?void 0:r.reason)??null}}).sort((e,n)=>{const a=Date.parse(e.lastEventAt??e.startedAt??"")||0;return(Date.parse(n.lastEventAt??n.startedAt??"")||0)-a}):[]}function rr(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=yt(t.metrics_window)?t.metrics_window:{};return(Array.isArray(e.top_tools)?e.top_tools:[]).map(a=>yt(a)?pt(a.tool):null).filter(a=>a!==null)}function Mu(t){return ce.value.find(e=>e.agent_name===t||e.name===t)??null}function lr(t,e){const n=nt(t.current_task,100);if(!n)return"명시된 current task 없음";const a=e.find(i=>i.id===n);if(a)return`${a.id} · ${nt(a.title,92)}`;const s=e.find(i=>i.title===n);return s?`${s.id} · ${nt(s.title,92)}`:n}function Lu(t){const e=new Map;for(const n of t)for(const a of n.memberNames)e.has(a)||e.set(a,n);return[...Yt.value].map(n=>{var _,$;const a=e.get(n.name),s=Mu(n.name),i=ir(n.name,Be.value),r=bu(n.name,Be.value),d=Wi.value.get(n.name.trim().toLowerCase()),c=a?a.memberNames.filter(k=>k!==n.name):[],m=a?`${a.goal}${a.room?` · ${a.room}`:""}`:((_=Qa.value)==null?void 0:_.summary.current_room)??"room",u=(s==null?void 0:s.skill_primary)??(n.capabilities&&n.capabilities.length>0?n.capabilities.slice(0,3).join(", "):null)??n.agent_type??null,p=lr(n,Et.value);return{agent:n,where:m,withWhom:c,activeSince:(a==null?void 0:a.startedAt)??n.joined_at??n.last_seen??null,currentWork:p,how:u,recentInput:nt(r==null?void 0:r.content,120)??nt(s==null?void 0:s.recent_input_preview,120)??null,recentOutput:nt(i==null?void 0:i.content,120)??nt(s==null?void 0:s.recent_output_preview,120)??nt(($=s==null?void 0:s.diagnostic)==null?void 0:$.last_reply_preview,120)??null,recentEvent:nt(d==null?void 0:d.lastActivityText,120)??(a==null?void 0:a.lastEventSummary)??null,recentTools:s?rr(s):[]}}).sort((n,a)=>{const s=c=>c==="busy"?4:c==="active"?3:c==="listening"?2:c==="idle"?1:0,i=s(a.agent.status)-s(n.agent.status);if(i!==0)return i;const r=Date.parse(n.agent.last_seen??n.activeSince??"")||0;return(Date.parse(a.agent.last_seen??a.activeSince??"")||0)-r})}function Du(){return[...ce.value].map(t=>{var e,n,a,s;return{keeper:t,activeSince:((e=t.agent)==null?void 0:e.joined_at)??t.created_at??t.last_heartbeat??null,currentWork:nt((n=t.agent)==null?void 0:n.current_task,110)??nt(t.skill_primary,110)??nt(t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:nt(t.recent_input_preview,120)??null,recentOutput:nt(t.recent_output_preview,120)??nt((a=t.diagnostic)==null?void 0:a.last_reply_preview,120)??nt(t.last_proactive_preview,120)??null,recentEvent:nt(t.last_proactive_reason,120)??nt((s=t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:rr(t)}}).sort((t,e)=>{const n=Date.parse(t.keeper.last_heartbeat??t.activeSince??"")||0;return(Date.parse(e.keeper.last_heartbeat??e.activeSince??"")||0)-n})}function Eu({cluster:t,project:e,room:n,generatedAt:a}){return o`
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
        <strong>${a?Ae(a):"fresh"}</strong>
      </div>
    </div>
  `}function Re({label:t,value:e,detail:n,tone:a}){return o`
    <article class="mission-stat-card ${St(a)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function zu({row:t}){const e=t.memberNames.slice(0,4).map(n=>{const a=Yt.value.find(i=>i.name===n),s=ir(n,Be.value);return{name:n,currentTask:a?lr(a,Et.value):"agent snapshot 없음",output:nt(s==null?void 0:s.content,96)}});return o`
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
          <strong>${pu(t.elapsedSec)}</strong>
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

      ${e.length>0?o`
            <div class="mission-member-stack">
              ${e.map(n=>o`
                <button class="mission-member-row" onClick=${()=>es(n.name)}>
                  <strong>${n.name}</strong>
                  <span>${n.currentTask}</span>
                  <small>${n.output??"최근 출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      ${t.attentionSummary?o`<div class="mission-inline-note">attention: ${t.attentionSummary}</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Zo("intervene",t.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Zo("command",t.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `}function Ou({row:t}){const e=t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음",n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return o`
    <button class="mission-activity-card ${St(t.agent.status)}" onClick=${()=>es(t.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.agent.emoji??""}</span>
          <div>
            <strong>${t.agent.name}</strong>
            ${t.agent.koreanName?o`<span>${t.agent.koreanName}</span>`:null}
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
        ${t.how?o`<small>어떻게 · ${t.how}</small>`:null}
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
        ${t.recentEvent?o`<span>최근 일 · ${t.recentEvent}</span>`:null}
      </div>
    </button>
  `}function ju({row:t}){const e=[`gen ${t.keeper.generation??0}`,`handoff ${t.keeper.handoff_count_total??0}`,`compact ${t.keeper.compaction_count??0}`,t.keeper.context_ratio!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null].filter(n=>n!==null).join(" · ");return o`
    <button class="mission-activity-card ${St(t.keeper.status)}" onClick=${()=>So(t.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.keeper.emoji??""}</span>
          <div>
            <strong>${t.keeper.name}</strong>
            ${t.keeper.koreanName?o`<span>${t.keeper.koreanName}</span>`:null}
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
        ${t.keeper.skill_reason?o`<small>판단 요약 · ${nt(t.keeper.skill_reason,120)}</small>`:null}
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
        ${t.recentEvent?o`<span>최근 일 · ${t.recentEvent}</span>`:null}
      </div>
    </button>
  `}function Fu({item:t}){return o`
    <article class="mission-action-card ${St(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${St(t.severity)}">${t.kind}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>gu(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>$u(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function qu({action:t,incident:e}){const n=_u(t);return o`
    <article class="mission-action-card ${St(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${St(t.severity)}">${To(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${vu(t)}</span>
        <span>${fu(t)}</span>
      </div>
      ${n?o`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>hu(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>yu(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function ti(){const t=Qa.value;if(no.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Sa.value&&!t)return o`<div class="empty-state error">${Sa.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=Pu(),n=Lu(e),a=Du(),s=n.filter(c=>["active","busy","listening","idle"].includes(c.agent.status)).length,i=n.filter(c=>c.recentOutput).length+a.filter(c=>c.recentOutput).length,r=t.incidents[0]??null,d=t.recommended_actions[0]??null;return o`
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

      <${Eu}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${Re} label="활성 흐름" value=${e.length} detail="지금 보이는 crew / session" tone=${e.length>0?"ok":"warn"} />
        <${Re} label="응답 가능 에이전트" value=${s} detail="지금 응답 가능한 actor 수" tone=${s>0?"ok":"warn"} />
        <${Re} label="Keeper 수" value=${a.length} detail="연속성 runtime / generation 관찰 대상" tone=${a.length>0?"ok":"warn"} />
        <${Re} label="최근 output" value=${i} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${i>0?"ok":"warn"} />
        <${Re} label="내부 incident" value=${t.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${(r==null?void 0:r.severity)??"ok"} />
        <${Re} label="추천 액션" value=${t.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${(d==null?void 0:d.severity)??"ok"} />
      </div>

      <div class="mission-human-grid">
        <${T} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${e.length>0?e.map(c=>o`<${zu} key=${c.session.session_id} row=${c} />`):o`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${n.length>0?n.slice(0,10).map(c=>o`<${Ou} key=${c.agent.name} row=${c} />`):o`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
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
            ${a.length>0?a.slice(0,8).map(c=>o`<${ju} key=${c.keeper.name} row=${c} />`):o`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${t.incidents.slice(0,2).map(c=>o`<${Fu} key=${`${c.kind}:${c.target_id??"room"}`} item=${c} />`)}
            ${t.recommended_actions.slice(0,2).map(c=>o`<${qu} key=${`${c.action_type}:${c.target_id??"room"}`} action=${c} />`)}
            ${t.incidents.length===0&&t.recommended_actions.length===0?o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`:null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>gt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>gt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const Ku="modulepreload",Uu=function(t){return"/dashboard/"+t},ei={},Hu=function(e,n,a){let s=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(p=>({status:"fulfilled",value:p}),p=>({status:"rejected",reason:p}))))};document.getElementsByTagName("link");const d=document.querySelector("meta[property=csp-nonce]"),c=(d==null?void 0:d.nonce)||(d==null?void 0:d.getAttribute("nonce"));s=r(n.map(m=>{if(m=Uu(m),m in ei)return;ei[m]=!0;const u=m.endsWith(".css"),p=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${p}`))return;const _=document.createElement("link");if(_.rel=u?"stylesheet":Ku,u||(_.as="script"),_.crossOrigin="",_.href=m,c&&_.setAttribute("nonce",c),document.head.appendChild(_),u)return new Promise(($,k)=>{_.addEventListener("load",$),_.addEventListener("error",()=>k(new Error(`Unable to preload CSS for ${m}`)))})}))}function i(r){const d=new Event("vite:preloadError",{cancelable:!0});if(d.payload=r,window.dispatchEvent(d),!d.defaultPrevented)throw r}return s.then(r=>{for(const d of r||[])d.status==="rejected"&&i(d.reason);return e().catch(i)})},Io=g(null),qt=g(null),Ta=g(!1),Ia=g(!1),Ra=g(null),Na=g(null),so=g(null),Pa=g(null),X=g("warroom"),Fn=g(null),oo=g(!1),Ma=g(null),Ce=g(null),La=g(!1),Da=g(null),qn=g(null),io=g(!1),Ea=g(null),Sn=g(null),za=g(!1),An=g(null),Ke=g(null);let ln=null;function Ro(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function f(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function at(t){return typeof t=="boolean"?t:void 0}function _t(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function cr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((s,i)=>{t.has(i)||t.set(i,s)}),t}function Wu(){const e=cr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Bu(){const e=cr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Gu(t){if(S(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:_t(t.tool_allowlist),model_allowlist:_t(t.model_allowlist),requires_human_for:_t(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:f(t.escalation_timeout_sec),kill_switch:at(t.kill_switch),frozen:at(t.frozen)}}function Ju(t){if(S(t))return{headcount_cap:f(t.headcount_cap),active_operation_cap:f(t.active_operation_cap),max_cost_usd:f(t.max_cost_usd),max_tokens:f(t.max_tokens)}}function No(t){if(!S(t))return null;const e=l(t.unit_id),n=l(t.label),a=l(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:_t(t.roster),capability_profile:_t(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:Gu(t.policy),budget:Ju(t.budget)}}function dr(t){if(!S(t))return null;const e=No(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:f(t.roster_total),roster_live:f(t.roster_live),active_operation_count:f(t.active_operation_count),health:l(t.health),reasons:_t(t.reasons),children:Array.isArray(t.children)?t.children.map(dr).filter(n=>n!==null):[]}:null}function Vu(t){if(S(t))return{total_units:f(t.total_units),company_count:f(t.company_count),platoon_count:f(t.platoon_count),squad_count:f(t.squad_count),leaf_agent_unit_count:f(t.leaf_agent_unit_count),live_agent_count:f(t.live_agent_count),managed_unit_count:f(t.managed_unit_count),active_operation_count:f(t.active_operation_count)}}function ur(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:Vu(e.summary),units:Array.isArray(e.units)?e.units.map(dr).filter(n=>n!==null):[]}}function Yu(t){if(!S(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function as(t){if(!S(t))return null;const e=l(t.operation_id),n=l(t.objective),a=l(t.assigned_unit_id),s=l(t.trace_id),i=l(t.status);return!e||!n||!a||!s||!i?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:s,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:_t(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:i,chain:Yu(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Xu(t){if(!S(t))return null;const e=as(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function sn(t){if(S(t))return{tone:l(t.tone),pending_ops:f(t.pending_ops),blocked_ops:f(t.blocked_ops),in_flight_ops:f(t.in_flight_ops),pipeline_stalls:f(t.pipeline_stalls),bus_traffic:f(t.bus_traffic),l1_hit_rate:f(t.l1_hit_rate),invalidation_count:f(t.invalidation_count),current_pending:f(t.current_pending),current_in_flight:f(t.current_in_flight),cdb_wakeups:f(t.cdb_wakeups),total_stolen:f(t.total_stolen),avg_best_score:f(t.avg_best_score),avg_candidate_count:f(t.avg_candidate_count),best_first_operations:f(t.best_first_operations),active_sessions:f(t.active_sessions),commit_rate:f(t.commit_rate),total_speculations:f(t.total_speculations)}}function Qu(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,a=S(t.ooo)?t.ooo:void 0,s=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:f(e.total_ops),completed_ops:f(e.completed_ops),stalled_cycles:f(e.stalled_cycles),hazards_detected:f(e.hazards_detected),forwarding_used:f(e.forwarding_used),pipeline_flushes:f(e.pipeline_flushes),ipc:f(e.ipc)}:void 0,cache:n?{total_reads:f(n.total_reads),total_writes:f(n.total_writes),l1_hit_rate:f(n.l1_hit_rate),invalidation_count:f(n.invalidation_count),writeback_count:f(n.writeback_count),bus_traffic:f(n.bus_traffic)}:void 0,ooo:a?{agent_count:f(a.agent_count),total_added:f(a.total_added),total_issued:f(a.total_issued),total_completed:f(a.total_completed),total_stolen:f(a.total_stolen),cdb_wakeups:f(a.cdb_wakeups),stall_cycles:f(a.stall_cycles),global_cdb_events:f(a.global_cdb_events),current_pending:f(a.current_pending),current_in_flight:f(a.current_in_flight)}:void 0,speculative:s?{total_speculations:f(s.total_speculations),total_commits:f(s.total_commits),total_aborts:f(s.total_aborts),commit_rate:f(s.commit_rate),total_fast_calls:f(s.total_fast_calls),total_cost_usd:f(s.total_cost_usd),active_sessions:f(s.active_sessions)}:void 0,search_fabric:i?{total_operations:f(i.total_operations),best_first_operations:f(i.best_first_operations),legacy_operations:f(i.legacy_operations),blocked_operations:f(i.blocked_operations),ready_operations:f(i.ready_operations),research_pipeline_operations:f(i.research_pipeline_operations),avg_candidate_count:f(i.avg_candidate_count),avg_best_score:f(i.avg_best_score),top_stage:l(i.top_stage)??null}:void 0,signals:r?{issue_pressure:sn(r.issue_pressure),cache_contention:sn(r.cache_contention),scheduler_efficiency:sn(r.scheduler_efficiency),routing_confidence:sn(r.routing_confidence),speculative_posture:sn(r.speculative_posture)}:void 0}}function pr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:f(n.total),active:f(n.active),paused:f(n.paused),managed:f(n.managed),projected:f(n.projected)}:void 0,microarch:Qu(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Xu).filter(a=>a!==null):[]}}function mr(t){if(!S(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),a=l(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:l(t.leader_id)??null,roster:_t(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Zu(t){if(!S(t))return null;const e=mr(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:as(t.operation)}:null}function vr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:f(n.total),active:f(n.active),projected:f(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Zu).filter(a=>a!==null):[]}}function tp(t){if(!S(t))return null;const e=l(t.decision_id),n=l(t.trace_id),a=l(t.requested_action),s=l(t.scope_type),i=l(t.scope_id);return!e||!n||!a||!s||!i?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:s,scope_id:i,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function _r(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:f(n.total),pending:f(n.pending),approved:f(n.approved),denied:f(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(tp).filter(a=>a!==null):[]}}function ep(t){if(!S(t))return null;const e=No(t.unit);return e?{unit:e,roster_total:f(t.roster_total),roster_live:f(t.roster_live),headcount_cap:f(t.headcount_cap),active_operations:f(t.active_operations),active_operation_cap:f(t.active_operation_cap),utilization:f(t.utilization)}:null}function np(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(ep).filter(n=>n!==null):[]}}function ap(t){if(!S(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function fr(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:f(n.total),bad:f(n.bad),warn:f(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(ap).filter(a=>a!==null):[]}}function gr(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.trace_id),a=l(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function sp(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(gr).filter(n=>n!==null):[]}}function op(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),a=l(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function ip(t){if(!S(t))return null;const e=l(t.lane_id),n=l(t.label),a=l(t.kind),s=l(t.phase),i=l(t.motion_state),r=l(t.source_of_truth),d=l(t.movement_reason),c=l(t.current_step);if(!e||!n||!a||!s||!i||!r||!d||!c)return null;const m=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:at(t.present)??!1,phase:s,motion_state:i,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:d,current_step:c,blockers:_t(t.blockers),counts:{operations:f(m.operations),detachments:f(m.detachments),workers:f(m.workers),approvals:f(m.approvals),alerts:f(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(op).filter(u=>u!==null):[]}}function rp(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.lane_id),a=l(t.kind),s=l(t.timestamp),i=l(t.title),r=l(t.detail),d=l(t.tone),c=l(t.source);return!e||!n||!a||!s||!i||!r||!d||!c?null:{event_id:e,lane_id:n,kind:a,timestamp:s,title:i,detail:r,tone:d,source:c}}function lp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),a=l(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:_t(t.lane_ids),count:f(t.count)??0}}function $r(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},a=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:f(e.active_lanes),moving_lanes:f(e.moving_lanes),stalled_lanes:f(e.stalled_lanes),projected_lanes:f(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(ip).filter(s=>s!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(rp).filter(s=>s!==null):[],gaps:{count:f(n.count),items:Array.isArray(n.items)?n.items.map(lp).filter(s=>s!==null):[]},recommended_next_action:a?{tool:l(a.tool)??"masc_operator_snapshot",label:l(a.label)??"Observe operator state",reason:l(a.reason)??"",lane_id:l(a.lane_id)??null}:void 0}}function cp(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=at(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},...f(t.peak_hot_slots)!=null?{peak_hot_slots:f(t.peak_hot_slots)}:{},...f(t.ctx_per_slot)!=null?{ctx_per_slot:f(t.ctx_per_slot)}:{},workers:{expected:f(e.expected),joined:f(e.joined),current_task_bound:f(e.current_task_bound),fresh_heartbeats:f(e.fresh_heartbeats),done:f(e.done),final:f(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function dp(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:ur(e.topology),operations:pr(e.operations),detachments:vr(e.detachments),alerts:fr(e.alerts),decisions:_r(e.decisions),capacity:np(e.capacity),traces:sp(e.traces),swarm_status:$r(e.swarm_status)}}function up(t){const e=S(t)?t:{},n=ur(e.topology),a=pr(e.operations),s=vr(e.detachments),i=fr(e.alerts),r=_r(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:s.version,generated_at:s.generated_at,summary:s.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:$r(e.swarm_status),swarm_proof:cp(e.swarm_proof)}}function pp(t){return S(t)?{chain_id:l(t.chain_id)??null,started_at:f(t.started_at)??null,progress:f(t.progress)??null,elapsed_sec:f(t.elapsed_sec)??null}:null}function hr(t){if(!S(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:f(t.duration_ms)??null,message:l(t.message)??null,tokens:f(t.tokens)??null}:null}function mp(t){if(!S(t))return null;const e=as(t.operation);return e?{operation:e,runtime:pp(t.runtime),history:hr(t.history),mermaid:l(t.mermaid)??null,preview_run:yr(t.preview_run)}:null}function vp(t){const e=S(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function _p(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:vp(e.connection),summary:n?{linked_operations:f(n.linked_operations),active_chains:f(n.active_chains),running_operations:f(n.running_operations),recent_failures:f(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(mp).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(hr).filter(a=>a!==null):[]}}function fp(t){if(!S(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:f(t.duration_ms)??null,error:l(t.error)??null}:null}function yr(t){if(!S(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:f(t.duration_ms),success:at(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(fp).filter(a=>a!==null):[]}:null}function gp(t){const e=S(t)?t:{};return{run:yr(e.run)}}function $p(t){if(!S(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function hp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function yp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.tool),s=l(t.summary);return!e||!n||!a||!s?null:{id:e,title:n,tool:a,summary:s,success_signals:_t(t.success_signals),pitfalls:_t(t.pitfalls)}}function bp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.summary),s=l(t.when_to_use);return!e||!n||!a||!s?null:{id:e,title:n,summary:a,when_to_use:s,steps:Array.isArray(t.steps)?t.steps.map(yp).filter(i=>i!==null):[]}}function kp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:_t(t.tools)}}function xp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.symptom),s=l(t.why),i=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!a||!s||!i||!r?null:{id:e,title:n,symptom:a,why:s,fix_tool:i,fix_summary:r}}function Sp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.path_id),s=l(t.transport);return!e||!n||!a||!s?null:{id:e,title:n,path_id:a,transport:s,request:t.request,response:t.response,notes:_t(t.notes)}}function Ap(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map($p).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(hp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(bp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(kp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(xp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Sp).filter(n=>n!==null):[]}}function Cp(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.status),s=l(t.detail),i=l(t.next_tool);return!e||!n||!a||!s||!i?null:{id:e,title:n,status:a,detail:s,next_tool:i}}function wp(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),a=l(t.title),s=l(t.detail),i=l(t.next_tool);return!e||!n||!a||!s||!i?null:{code:e,severity:n,title:a,detail:s,next_tool:i}}function Tp(t){if(!S(t))return null;const e=l(t.from),n=l(t.content),a=l(t.timestamp),s=f(t.seq);return!e||!n||!a||s==null?null:{seq:s,from:e,content:n,timestamp:a}}function Ip(t){if(!S(t))return null;const e=l(t.name),n=l(t.role),a=l(t.lane),s=l(t.status),i=l(t.claim_marker),r=l(t.done_marker),d=l(t.final_marker);if(!e||!n||!a||!s||!i||!r||!d)return null;const c=(()=>{if(!S(t.last_message))return null;const m=f(t.last_message.seq),u=l(t.last_message.content),p=l(t.last_message.timestamp);return m==null||!u||!p?null:{seq:m,content:u,timestamp:p}})();return{name:e,role:n,lane:a,joined:at(t.joined)??!1,live_presence:at(t.live_presence)??!1,completed:at(t.completed)??!1,status:s,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:at(t.current_task_matches_run)??!1,squad_member:at(t.squad_member)??!1,detachment_member:at(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:f(t.heartbeat_age_sec)??null,heartbeat_fresh:at(t.heartbeat_fresh)??!1,claim_marker_seen:at(t.claim_marker_seen)??!1,done_marker_seen:at(t.done_marker_seen)??!1,final_marker_seen:at(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:d,last_message:c}}function Rp(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const a=l(n.timestamp),s=f(n.active_slots);if(!a||s==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:s,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:at(t.provider_reachable)??null,provider_status_code:f(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:f(t.expected_slots),actual_slots:f(t.actual_slots),expected_ctx:f(t.expected_ctx),actual_ctx:f(t.actual_ctx),slot_reachable:at(t.slot_reachable)??null,slot_status_code:f(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:f(t.total_slots),ctx_per_slot:f(t.ctx_per_slot),active_slots_now:f(t.active_slots_now),peak_active_slots:f(t.peak_active_slots),sample_count:f(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function Np(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:f(n.expected_workers),joined_workers:f(n.joined_workers),live_workers:f(n.live_workers),squad_roster_size:f(n.squad_roster_size),detachment_roster_size:f(n.detachment_roster_size),current_task_bound:f(n.current_task_bound),fresh_heartbeats:f(n.fresh_heartbeats),claim_markers_seen:f(n.claim_markers_seen),done_markers_seen:f(n.done_markers_seen),final_markers_seen:f(n.final_markers_seen),completed_workers:f(n.completed_workers),peak_hot_slots:f(n.peak_hot_slots),hot_window_ok:at(n.hot_window_ok),pass_hot_concurrency:at(n.pass_hot_concurrency),pass_end_to_end:at(n.pass_end_to_end),pending_decisions:f(n.pending_decisions),pass:at(n.pass)}:void 0,provider:Rp(e.provider),operation:as(e.operation),squad:No(e.squad),detachment:mr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Ip).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Cp).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(wp).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Tp).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(gr).filter(a=>a!==null):[],truth_notes:_t(e.truth_notes)}}function ke(t){X.value=t,Ro(t)&&Pp()}async function br(){Ta.value=!0,Ra.value=null;try{const t=await Dl();Io.value=up(t)}catch(t){Ra.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Ta.value=!1}}function Po(t){Ke.value=t}async function Mo(){Ia.value=!0,Na.value=null;try{const t=await Ll();qt.value=dp(t)}catch(t){Na.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ia.value=!1}}async function Pp(){qt.value||Ia.value||await Mo()}async function xe(){await br(),Ro(X.value)&&await Mo()}async function ne(){var t;io.value=!0,Ea.value=null;try{const e=await El(),n=_p(e);qn.value=n;const a=Ke.value;n.operations.length===0?Ke.value=null:(!a||!n.operations.some(s=>s.operation.operation_id===a))&&(Ke.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ea.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{io.value=!1}}function Mp(){ln=null,Sn.value=null,za.value=!1,An.value=null}async function Lp(t){ln=t,za.value=!0,An.value=null;try{const e=await zl(t);if(ln!==t)return;Sn.value=gp(e)}catch(e){if(ln!==t)return;Sn.value=null,An.value=e instanceof Error?e.message:"Failed to load chain run"}finally{ln===t&&(za.value=!1)}}async function Dp(){oo.value=!0,Ma.value=null;try{const t=await Ol();Fn.value=Ap(t)}catch(t){Ma.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{oo.value=!1}}async function Ht(t=Wu(),e=Bu()){La.value=!0,Da.value=null;try{const n=await jl(t,e);Ce.value=Np(n)}catch(n){Da.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{La.value=!1}}async function ue(t,e,n){so.value=t,Pa.value=null;try{await Fl(e,n),await br(),(qt.value||Ro(X.value))&&await Mo(),await Ht(),await ne()}catch(a){throw Pa.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{so.value=null}}function Ep(t){return ue(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function zp(t){return ue(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Op(t){return ue(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function jp(t={}){return ue("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Fp(t){return ue(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function qp(t){return ue(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Kp(t,e){return ue(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Up(t,e){return ue(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}md(()=>{xe(),ne(),(X.value==="swarm"||X.value==="warroom"||Ce.value!==null)&&Ht()});const pe=g(null),kr=g(null),jt=g(null),Cn=g(!1),ie=g(null),wn=g(!1),Je=g(null),Q=g(!1),Oa=g([]);let Hp=1;function H(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function st(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ss(t){return typeof t=="boolean"?t:void 0}function Wp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function Lt(t,e=[]){if(Array.isArray(t))return t;if(!H(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Bp(t){return H(t)?{id:x(t.id),seq:st(t.seq),from:x(t.from)??x(t.from_agent)??"system",content:x(t.content)??"",timestamp:x(t.timestamp)??new Date().toISOString(),type:x(t.type)}:null}function Gp(t){return H(t)?{room_id:x(t.room_id),current_room:x(t.current_room)??x(t.room),project:x(t.project),cluster:x(t.cluster),paused:ss(t.paused),pause_reason:x(t.pause_reason)??null,paused_by:x(t.paused_by)??null,paused_at:x(t.paused_at)??null}:{}}function ni(t){if(!H(t))return;const e=Object.entries(t).map(([n,a])=>{const s=x(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function xr(t){if(!H(t))return null;const e=x(t.kind),n=x(t.summary),a=x(t.target_type);return!e||!n||!a?null:{kind:e,severity:x(t.severity)??"warn",summary:n,target_type:a,target_id:x(t.target_id)??null,actor:x(t.actor)??null,evidence:t.evidence}}function Sr(t){if(!H(t))return null;const e=x(t.action_type),n=x(t.target_type),a=x(t.reason);return!e||!n||!a?null:{action_type:e,target_type:n,target_id:x(t.target_id)??null,severity:x(t.severity)??"warn",reason:a,confirm_required:ss(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Jp(t){return H(t)?{actor:x(t.actor)??null,spawn_agent:x(t.spawn_agent)??null,spawn_role:x(t.spawn_role)??null,spawn_model:x(t.spawn_model)??null,worker_class:x(t.worker_class)??null,parent_actor:x(t.parent_actor)??null,capsule_mode:x(t.capsule_mode)??null,runtime_pool:x(t.runtime_pool)??null,lane_id:x(t.lane_id)??null,controller_level:x(t.controller_level)??null,control_domain:x(t.control_domain)??null,supervisor_actor:x(t.supervisor_actor)??null,model_tier:x(t.model_tier)??null,task_profile:x(t.task_profile)??null,risk_level:x(t.risk_level)??null,routing_confidence:st(t.routing_confidence)??null,routing_reason:x(t.routing_reason)??null,status:x(t.status)??"unknown",turn_count:st(t.turn_count)??0,empty_note_turn_count:st(t.empty_note_turn_count)??0,has_turn:ss(t.has_turn)??!1,last_turn_ts_iso:x(t.last_turn_ts_iso)??null}:null}function Vp(t){if(!H(t))return null;const e=x(t.session_id);return e?{session_id:e,goal:x(t.goal),status:x(t.status),health:x(t.health),scale_profile:x(t.scale_profile),control_profile:x(t.control_profile),planned_worker_count:st(t.planned_worker_count),active_agent_count:st(t.active_agent_count),last_turn_age_sec:st(t.last_turn_age_sec)??null,attention_count:st(t.attention_count),recommended_action_count:st(t.recommended_action_count),top_attention:xr(t.top_attention),top_recommendation:Sr(t.top_recommendation)}:null}function Ar(t){const e=H(t)?t:{};return{trace_id:x(e.trace_id),target_type:x(e.target_type)??"room",target_id:x(e.target_id)??null,health:x(e.health),swarm_status:H(e.swarm_status)?e.swarm_status:void 0,attention_items:Lt(e.attention_items).map(xr).filter(n=>n!==null),recommended_actions:Lt(e.recommended_actions).map(Sr).filter(n=>n!==null),session_cards:Lt(e.session_cards).map(Vp).filter(n=>n!==null),worker_cards:Lt(e.worker_cards).map(Jp).filter(n=>n!==null)}}function Yp(t){if(!H(t))return null;const e=H(t.status)?t.status:void 0,n=H(t.summary)?t.summary:H(e==null?void 0:e.summary)?e.summary:void 0,a=H(t.session)?t.session:H(e==null?void 0:e.session)?e.session:void 0,s=x(t.session_id)??x(n==null?void 0:n.session_id)??x(a==null?void 0:a.session_id);if(!s)return null;const i=ni(t.report_paths)??ni(e==null?void 0:e.report_paths),r=Lt(t.recent_events,["events"]).filter(H);return{session_id:s,status:x(t.status)??x(n==null?void 0:n.status)??x(a==null?void 0:a.status),progress_pct:st(t.progress_pct)??st(n==null?void 0:n.progress_pct),elapsed_sec:st(t.elapsed_sec)??st(n==null?void 0:n.elapsed_sec),remaining_sec:st(t.remaining_sec)??st(n==null?void 0:n.remaining_sec),done_delta_total:st(t.done_delta_total)??st(n==null?void 0:n.done_delta_total),summary:n,team_health:H(t.team_health)?t.team_health:H(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:H(t.communication_metrics)?t.communication_metrics:H(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:H(t.orchestration_state)?t.orchestration_state:H(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:H(t.cascade_metrics)?t.cascade_metrics:H(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function Xp(t){if(!H(t))return null;const e=x(t.name);if(!e)return null;const n=H(t.context)?t.context:void 0;return{name:e,agent_name:x(t.agent_name),status:x(t.status),autonomy_level:x(t.autonomy_level),context_ratio:st(t.context_ratio)??st(n==null?void 0:n.context_ratio),generation:st(t.generation),active_goal_ids:Wp(t.active_goal_ids),last_autonomous_action_at:x(t.last_autonomous_action_at)??null,last_turn_ago_s:st(t.last_turn_ago_s),model:x(t.model)??x(t.active_model)??x(t.primary_model)}}function Qp(t){if(!H(t))return null;const e=x(t.confirm_token)??x(t.token);return e?{confirm_token:e,actor:x(t.actor),action_type:x(t.action_type),target_type:x(t.target_type),target_id:x(t.target_id)??null,delegated_tool:x(t.delegated_tool),created_at:x(t.created_at),preview:t.preview}:null}function Zp(t){const e=H(t)?t:{};return{room:Gp(e.room),sessions:Lt(e.sessions,["items","sessions"]).map(Yp).filter(n=>n!==null),keepers:Lt(e.keepers,["items","keepers"]).map(Xp).filter(n=>n!==null),recent_messages:Lt(e.recent_messages,["messages"]).map(Bp).filter(n=>n!==null),pending_confirms:Lt(e.pending_confirms,["items","confirms"]).map(Qp).filter(n=>n!==null),available_actions:Lt(e.available_actions,["actions"]).filter(H).map(n=>({action_type:x(n.action_type)??"unknown",target_type:x(n.target_type)??"unknown",description:x(n.description),confirm_required:ss(n.confirm_required)}))}}function Yn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ai(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ja(t){Oa.value=[{...t,id:Hp++,at:new Date().toISOString()},...Oa.value].slice(0,20)}function Cr(t){return t.confirm_required?Yn(t.preview)||"Confirmation required":Yn(t.result)||Yn(t.executed_action)||Yn(t.delegated_tool_result)||t.status}async function vt(){Cn.value=!0,ie.value=null;try{const t=await Ml();pe.value=Zp(t)}catch(t){ie.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Cn.value=!1}}async function Jt(){wn.value=!0,Je.value=null;try{const t=await Li({targetType:"room"});kr.value=Ar(t)}catch(t){Je.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{wn.value=!1}}async function Ve(t){if(!t){jt.value=null;return}wn.value=!0,Je.value=null;try{const e=await Li({targetType:"team_session",targetId:t,includeWorkers:!0});jt.value=Ar(e)}catch(e){Je.value=e instanceof Error?e.message:"Failed to load session digest"}finally{wn.value=!1}}async function tm(t){var e;Q.value=!0,ie.value=null;try{const n=await Va(t);return ja({actor:t.actor,action_type:t.action_type,target_label:ai(t),outcome:n.confirm_required?"preview":"executed",message:Cr(n),delegated_tool:n.delegated_tool}),await vt(),await Jt(),(e=jt.value)!=null&&e.target_id&&await Ve(jt.value.target_id),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";throw ie.value=a,ja({actor:t.actor,action_type:t.action_type,target_label:ai(t),outcome:"error",message:a}),n}finally{Q.value=!1}}async function em(t,e){var n;Q.value=!0,ie.value=null;try{const a=await Kl(t,e);return ja({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Cr(a),delegated_tool:a.delegated_tool}),await vt(),await Jt(),(n=jt.value)!=null&&n.target_id&&await Ve(jt.value.target_id),a}catch(a){const s=a instanceof Error?a.message:"Operator confirmation failed";throw ie.value=s,ja({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:s}),a}finally{Q.value=!1}}vd(()=>{var t;vt(),Jt(),(t=jt.value)!=null&&t.target_id&&Ve(jt.value.target_id)});function wr(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function nm(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Tr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function L(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let si=!1,am=0,ms=null;async function sm(){ms||(ms=Hu(()=>import("./mermaid.core-CkuFjOK1.js").then(e=>e.bE),[]).then(e=>e.default));const t=await ms;return si||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),si=!0),t}function ae(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Kn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function cn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Un(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function $e(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Un(t/e*100)}function om(t,e){const n=Un(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Ir(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const im=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Rr=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],rm=Rr.map(t=>t.id),lm=["chain_start","node_start","node_complete","chain_complete","chain_error"],cm={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function oi(t){return!!t&&rm.includes(t)}function dm(){const t=j.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function Nr(t){const e=dm();if(t==="operations")return e;if(t==="chains"){const n=Ke.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function um(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function pm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function lt(t){return so.value===t}function Hn(){return Io.value}function mm(t){var s,i,r,d,c,m,u;const e=Io.value,n=Ce.value,a=qn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((s=e==null?void 0:e.operations.summary)==null?void 0:s.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((c=(d=e==null?void 0:e.swarm_status)==null?void 0:d.recommended_next_action)==null?void 0:c.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(m=a==null?void 0:a.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function vm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function _m(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function fm(){const t=jn(j.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${To(t.action_type)}</span>
        <span class="command-chip">${wo(t)}</span>
        <span class="command-chip">${uu(j.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function gm(){const t=X.value,e=cm[t],n=mm(t);return o`
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
  `}function Xn({label:t,value:e,subtext:n,percent:a,color:s}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${om(a,s)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Un(a))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Qn({label:t,value:e,detail:n,percent:a,tone:s}){return o`
    <article class="command-signal-rail ${L(s)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${L(s)}" style=${`width: ${Math.max(8,Math.round(Un(a)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function $m(){var F,tt,W,et;const t=Hn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.detachments.summary,s=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(F=t==null?void 0:t.swarm_status)==null?void 0:F.overview,d=t==null?void 0:t.swarm_proof,c=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,p=(n==null?void 0:n.active)??0,_=(a==null?void 0:a.active)??0,$=(r==null?void 0:r.moving_lanes)??0,k=(r==null?void 0:r.active_lanes)??0,A=(d==null?void 0:d.workers.done)??0,w=(d==null?void 0:d.workers.expected)??0,M=(i==null?void 0:i.bad)??0,z=(i==null?void 0:i.warn)??0,E=(s==null?void 0:s.pending)??0,I=(s==null?void 0:s.total)??0,R=p+_,V=((tt=c==null?void 0:c.cache)==null?void 0:tt.l1_hit_rate)??((et=(W=c==null?void 0:c.signals)==null?void 0:W.cache_contention)==null?void 0:et.l1_hit_rate)??0,G=p>0||_>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",v=p>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${G}</h3>
        <p>${v}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(p>0?"ok":"warn")}">활성 작전 ${p}</span>
          <span class="command-chip ${L($>0?"ok":(k>0,"warn"))}">이동 레인 ${$}/${Math.max(k,$)}</span>
          <span class="command-chip ${L(M>0?"bad":z>0?"warn":"ok")}">치명 알림 ${M}</span>
          <span class="command-chip ${L(E>0?"warn":"ok")}">승인 대기 ${E}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Xn}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${$e(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${Xn}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${p}개 작전 + ${_}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${$e(R,Math.max(m,R||1))}
          color="#4ade80"
        />
        <${Xn}
          label="스웜 이동감"
          value=${`${$}/${Math.max(k,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Z(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${$e($,Math.max(k,$||1))}
          color="#fbbf24"
        />
        <${Xn}
          label="증거 수집률"
          value=${`${A}/${Math.max(w,A)}`}
          subtext=${d!=null&&d.status?`증거 소스 ${d.source} · ${d.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${$e(A,Math.max(w,A||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Qn}
        label="승인 대기열"
        value=${`${E}건 대기`}
        detail=${`현재 정책 창에서 ${I}개 결정을 추적 중입니다`}
        percent=${$e(E,Math.max(I,E||1))}
        tone=${E>0?"warn":"ok"}
      />
      <${Qn}
        label="알림 압력"
        value=${`${M} bad / ${z} warn`}
        detail=${M>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${$e(M*2+z,Math.max((M+z)*2,1))}
        tone=${M>0?"bad":z>0?"warn":"ok"}
      />
      <${Qn}
        label="디스패치 점유"
          value=${`${_}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${$e(_,Math.max(m,_||1))}
        tone=${_>0?"ok":"warn"}
      />
      <${Qn}
        label="캐시 신뢰도"
        value=${V?Kn(V):"n/a"}
        detail=${V?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Un((V??0)*100)}
        tone=${V>=.75?"ok":V>=.4?"warn":"bad"}
      />
    </div>
  `}function hm(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Pr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((s,i)=>{t.has(i)||t.set(i,s)}),t}function ym(){const e=Pr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Mr(){const e=Pr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function bm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function km(t){return t.status==="claimed"||t.status==="in_progress"}function xm(t){const e=Fn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(s=>s.tool===t);if(a)return a}return null}function vs(t){var e;return((e=Fn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Sm(t){const e=Fn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function se(t){try{await t()}catch{}}function Lo(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Oe(t){const e=Lo(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function _s(t){const e=Lo(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Am(){var e,n,a;const t=Ce.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((a=t.summary)==null?void 0:a.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function Cm(t){const e=Lo(t.status);return e==="active"||e==="running"}function wm(){var i,r,d,c;const t=((i=pe.value)==null?void 0:i.sessions)??[],e=Ce.value,n=((r=e==null?void 0:e.detachment)==null?void 0:r.session_id)??null;if(n){const m=t.find(u=>u.session_id===n);if(m)return m}const a=((d=e==null?void 0:e.operation)==null?void 0:d.operation_id)??Mr();if(a){const m=t.find(u=>u.command_plane_operation_id===a);if(m)return m}const s=((c=e==null?void 0:e.detachment)==null?void 0:c.detachment_id)??null;if(s){const m=t.find(u=>u.command_plane_detachment_id===s);if(m)return m}return t.find(Cm)??t[0]??null}function Tm(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Im(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,a=t.spawn_role??t.worker_class??t.spawn_agent??"worker",s=t.lane_id??t.capsule_mode??t.control_domain??"session",i=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:a,lane:s,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?Z(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Kn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:i,note:t.routing_reason??null}}function ii(t){return L(t.severity)}function Rm({worker:t}){return o`
    <article class="command-card compact warroom-worker-card ${L(Oe(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(Oe(t.status))}">${t.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Source</span><span>${t.source}</span>
        <span>Task</span><span>${t.task}</span>
        <span>Heartbeat</span><span>${t.heartbeat}</span>
        <span>Detail</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>o`<span class="command-tag">${e}</span>`)}
      </div>
      ${t.note?o`<div class="command-card-foot">${t.note}</div>`:null}
    </article>
  `}function Zt({label:t,surface:e,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){ke(e),gt("command",{...Nr(e),...n});return}gt("intervene")}}
    >
      ${t}
    </button>
  `}function Nm(){var _,$,k,A,w;const t=Hn(),e=qn.value,n=jn(j.value),a=vm(n),s=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,r=(_=t==null?void 0:t.swarm_status)==null?void 0:_.overview,d=t==null?void 0:t.operations.microarch,c=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,u=($=d==null?void 0:d.signals)==null?void 0:$.issue_pressure,p=d==null?void 0:d.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(s==null?void 0:s.total_units)??0}</strong><small>${(s==null?void 0:s.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((k=t==null?void 0:t.detachments.summary)==null?void 0:k.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(c==null?void 0:c.pending)??0}</strong><small>${(c==null?void 0:c.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${a==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((A=e==null?void 0:e.summary)==null?void 0:A.active_chains)??0}</strong><small>${((w=e==null?void 0:e.summary)==null?void 0:w.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${a==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${Z(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${a==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(p==null?void 0:p.l1_hit_rate)!=null?`${Kn(p.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function Lr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Dr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const s of t){const i=s.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const a=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
    <div>
      <div class="swarm-health-bar">
        ${a.filter(s=>s.count>0).map(s=>o`
          <div class="swarm-health-seg ${s.key}" style="flex: ${s.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${a.filter(s=>s.count>0).map(s=>o`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${s.color}"></span>
            ${s.count} ${s.key}
          </span>
        `)}
      </div>
    </div>
  `}function Pm({total:t}){const n=Math.min(t,20),a=t>20?t-20:0,s=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${s.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${a>0?o`<span class="swarm-worker-count">+${a}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Mm({lane:t}){const e=t.counts??{},n=Lr(t),a=e.workers??0,s=e.operations??0,i=e.detachments??0,r=s+i,d=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${L(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${L(n)}">${t.phase}</span>
          <span class="command-chip ${L(n)}">${t.motion_state}</span>
          <span class="command-chip">${Z(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${L(n)}" style=${`width:${d}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${a>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Pm} total=${a} />
              </div>
            `:null}
        ${r>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${r>0?Math.round(s/r*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${s} · 실행체 ${i}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?o`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?o`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(c=>o`<span class="command-chip ${L(c.severity)}">${c.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Er({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const a=Lr(n),s=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${L(a)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${L(a)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${s}</span>
              <span>작전 ${i}</span>
              <span>실행체 ${r}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function Lm({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,a=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(t.tone)}"></span>
      <span class="swarm-event-time">${a}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Dm({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${L(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Em({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${L(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Z(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function zm(){const t=Hn(),e=jn(j.value),n=_m(e),a=t==null?void 0:t.swarm_status,s=t==null?void 0:t.swarm_proof,i=(a==null?void 0:a.lanes.filter(p=>p.present))??[],r=(a==null?void 0:a.gaps.items)??[],d=(a==null?void 0:a.timeline.slice(0,8))??[],c=a==null?void 0:a.overview,m=a==null?void 0:a.recommended_next_action,u=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${D} panelId="command.swarm" compact=${!0} />
      </div>
      ${a?o`
            <${Er} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(c==null?void 0:c.active_lanes)??0}</strong><small>${(c==null?void 0:c.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(c==null?void 0:c.stalled_lanes)??0}</strong><small>${(c==null?void 0:c.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Z(c==null?void 0:c.last_movement_at)}</strong><small>${a.generated_at?`스냅샷 ${Z(a.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${Dr} lanes=${i} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(p=>o`<${Mm} lane=${p} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Em} proof=${s} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(r.some(p=>p.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?o`<div class="swarm-event-rail">${r.slice(0,4).map(p=>o`<${Dm} gap=${p} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${d.length}</span>
                  </div>
                  ${d.length>0?o`<div class="swarm-event-rail">${d.map(p=>o`<${Lm} event=${p} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Om(){return o`
    <div class="command-surface-tabs grouped">
      ${im.map(t=>o`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Rr.filter(e=>e.group===t.id).map(e=>o`
                <button
                  class="command-surface-tab ${X.value===e.id?"active":""}"
                  onClick=${()=>{ke(e.id),gt("command",Nr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function jm(){var F,tt,W,et,b,Tt,Xt,me,ve;const t=Hn(),e=qt.value,n=Fe.value,a=hm(),s=a?Yt.value.find(O=>O.name===a)??null:null,i=a?Et.value.filter(O=>O.assignee===a&&km(O)):[],r=((F=t==null?void 0:t.operations.summary)==null?void 0:F.active)??0,d=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,c=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,m=e==null?void 0:e.detachments.detachments.find(O=>{const It=O.detachment.heartbeat_deadline,_e=It?Date.parse(It):Number.NaN;return O.detachment.status==="stalled"||!Number.isNaN(_e)&&_e<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(O=>O.severity==="bad"),p=!!(n!=null&&n.room||n!=null&&n.project),_=(s==null?void 0:s.current_task)??null,$=bm(s==null?void 0:s.last_seen),k=$!=null?$<=120:null,A=[p?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},a?s?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${a} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Et.value.length>0?"masc_claim":"masc_add_task"}:_?k===!1?{title:"Task 준비도",tone:"warn",detail:`${a} current_task=${_} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${a} current_task=${_}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((et=t.topology.summary)==null?void 0:et.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Tt=t.topology.summary)==null?void 0:Tt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},c>0?{title:"디스패치 준비도",tone:"warn",detail:`${c}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&d===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:c>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${d}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],w=p?!a||!s?"masc_join":i.length===0?Et.value.length>0?"masc_claim":"masc_add_task":_?k===!1?"masc_heartbeat":!t||(((Xt=t.topology.summary)==null?void 0:Xt.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":c>0?"masc_policy_approve":r>0&&d===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",M=xm(w),E=Sm(w==="masc_set_room"?["repo-root-room"]:w==="masc_plan_set_task"?["claimed-not-current"]:w==="masc_heartbeat"?["heartbeat-stale"]:w==="masc_dispatch_tick"?["no-detachments"]:w==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),I=vs("room_task_hygiene"),R=vs("cpv2_benchmark"),V=vs("supervisor_session"),G=((me=Fn.value)==null?void 0:me.docs)??[],v=[I,R,V].filter(O=>O!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(M==null?void 0:M.title)??w}</strong>
            <span class="command-chip ok">${w}</span>
          </div>
          <p>${(M==null?void 0:M.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ve=M==null?void 0:M.success_signals)!=null&&ve.length?o`<div class="command-tag-row">
                ${M.success_signals.map(O=>o`<span class="command-tag ok">${O}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${A.map(O=>o`
            <article class="command-readiness-row ${L(O.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${O.title}</strong>
                  <span class="command-chip ${L(O.tone)}">${O.tone}</span>
                </div>
                <p>${O.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${O.tool}</div>
            </article>
          `)}
        </div>

        ${E.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${E.length}</span>
                </div>
                <div class="command-guide-list">
                  ${E.map(O=>o`
                    <article class="command-guide-inline">
                      <strong>${O.title}</strong>
                      <div>${O.symptom}</div>
                      <div class="command-card-sub">${O.fix_tool} 로 해결: ${O.fix_summary}</div>
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
        ${oo.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ma.value?o`<div class="empty-state error">${Ma.value}</div>`:o`
                <div class="command-path-grid">
                  ${v.map(O=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${O.title}</strong>
                        <span class="command-chip">${O.id}</span>
                      </div>
                      <p>${O.summary}</p>
                      <div class="command-card-sub">${O.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${O.steps.slice(0,4).map(It=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${It.tool}</span>
                            <span>${It.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${G.length>0?o`<div class="command-doc-links">
                      ${G.map(O=>o`<span class="command-tag">${O.title}: ${O.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Fm(){return o`
    <${$m} />
    <${Nm} />
    <${jm} />
  `}function qm(){return Ia.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Na.value?o`<div class="empty-state error">${Na.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function zr({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,s=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${pm(t.unit.kind)}</span>
            <span class="command-chip ${L(t.health)}">${t.health??"ok"}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${a}</span>
            <span>Ops ${s}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(r=>o`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(r=>o`<${zr} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Km({source:t}){const e=nl(null),[n,a]=xi(null);return rt(()=>{let s=!1;const i=e.current;return i?(i.innerHTML="",a(null),(async()=>{try{const d=await sm(),{svg:c}=await d.render(`command-chain-${++am}`,t);if(s||!e.current)return;e.current.innerHTML=c}catch(d){if(s)return;a(d instanceof Error?d.message:"Mermaid render failed")}})(),()=>{s=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Um({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,s=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${ae(a==null?void 0:a.status)}">${(a==null?void 0:a.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(a==null?void 0:a.kind)??"chain_dsl"}</span>
        ${a!=null&&a.chain_id?o`<span class="command-tag">${a.chain_id}</span>`:null}
        ${s?o`<span class="command-tag ${ae(a==null?void 0:a.status)}">${Kn(s.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Ir(t.history)}</div>
    </button>
  `}function Hm({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${ae(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${Ir(t)}</div>
    </article>
  `}function Wm({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${ae(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Bm({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,s=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${L(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${ae(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{ke("swarm"),gt("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{Po(e.operation_id),ke("chains"),gt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>se(()=>Ep(e.operation_id))}>
                ${lt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${lt(s)} onClick=${()=>se(()=>Op(e.operation_id))}>
                ${lt(s)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${lt(a)} onClick=${()=>se(()=>zp(e.operation_id))}>
                ${lt(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Gm({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${L(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Tr(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${nm(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Jm({alert:t}){return o`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Z(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function Do({event:t}){return o`
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
      <pre class="command-trace-detail">${wr(t.detail)}</pre>
    </article>
  `}function Vm({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return o`
    <article class="command-card ${L(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${L(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Z(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${lt(e)} onClick=${()=>se(()=>Fp(t.decision_id))}>
                ${lt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>se(()=>qp(t.decision_id))}>
                ${lt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Ym({row:t}){var d,c,m;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,s=!!((d=e.policy)!=null&&d.frozen),i=!!((c=e.policy)!=null&&c.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${L(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${s?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>se(()=>Kp(e.unit_id,!s))}>
          ${lt(n)?"Applying…":s?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${lt(a)} onClick=${()=>se(()=>Up(e.unit_id,!i))}>
          ${lt(a)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Xm({item:t}){return o`
    <article class="command-guide-card ${L(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Or({blocker:t}){return o`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Qm({worker:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?o`<div class="command-card-foot">${Z(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Zm(){var G,v,F,tt,W,et,b,Tt,Xt,me,ve,O,It,_e,tn,en,Wn,Bn,Gn,Jn;const t=Hn(),e=Ce.value,n=pe.value,a=jt.value,s=wm(),i=e!=null&&e.operation?((G=qn.value)==null?void 0:G.operations.find(q=>{var Te;return q.operation.operation_id===((Te=e.operation)==null?void 0:Te.operation_id)}))??null:null,r=(e==null?void 0:e.workers)??[],d=(a==null?void 0:a.worker_cards)??[],c=r.length>0?r.map(Tm):d.map(Im),m=Am(),u=((v=t==null?void 0:t.decisions.summary)==null?void 0:v.pending)??0,p=(n==null?void 0:n.pending_confirms)??[],_=(e==null?void 0:e.blockers)??[],$=(a==null?void 0:a.recommended_actions)??[],k=(a==null?void 0:a.attention_items)??[],A=((F=e==null?void 0:e.recent_messages[0])==null?void 0:F.timestamp)??null,w=((tt=e==null?void 0:e.recent_trace_events[0])==null?void 0:tt.timestamp)??null,M=A??w??null,z=s==null?void 0:s.summary,E=((W=e==null?void 0:e.summary)==null?void 0:W.expected_workers)??(typeof(z==null?void 0:z.planned_worker_count)=="number"?z.planned_worker_count:void 0)??(a==null?void 0:a.worker_cards.length)??0,I=((et=e==null?void 0:e.summary)==null?void 0:et.joined_workers)??(typeof(z==null?void 0:z.active_agent_count)=="number"?z.active_agent_count:void 0)??c.length,R=_.length>0||u>0||p.length>0?"warn":m||s?"ok":"warn",V=((b=t==null?void 0:t.swarm_status)==null?void 0:b.lanes.filter(q=>q.present))??[];return rt(()=>{vt()},[]),rt(()=>{s!=null&&s.session_id&&Ve(s.session_id)},[s==null?void 0:s.session_id,n,(Tt=e==null?void 0:e.detachment)==null?void 0:Tt.session_id]),!m&&!s?La.value||Cn.value?o`<div class="empty-state">live war room 불러오는 중…</div>`:o`
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
          <${Zt} label="작전 보기" surface="operations" />
          <${Zt} label="스웜 보기" surface="swarm" />
          <${Zt} label="개입 열기" />
          <${Zt} label="제어 보기" surface="control" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${L(R)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((Xt=e==null?void 0:e.operation)==null?void 0:Xt.objective)??(s==null?void 0:s.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((me=e==null?void 0:e.operation)==null?void 0:me.operation_id)??"operation 없음"}
              ${s!=null&&s.session_id?` · session ${s.session_id}`:""}
              ${(ve=e==null?void 0:e.detachment)!=null&&ve.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${Zt}
              label="스웜 상세"
              surface="swarm"
              params=${{...(O=e==null?void 0:e.operation)!=null&&O.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${Zt} label="트레이스" surface="trace" />
            ${i?o`<${Zt}
                  label="체인"
                  surface="chains"
                  params=${{operation:i.operation.operation_id}}
                />`:null}
            <${Zt} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${I??0}/${E??0}</strong>
            <small>${((It=e==null?void 0:e.summary)==null?void 0:It.completed_workers)??0} 완료 · ${c.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(_e=e==null?void 0:e.provider)!=null&&_e.runtime_blocker?"blocked":(tn=e==null?void 0:e.provider)!=null&&tn.provider_reachable?"ready":s?_s(s.status):"check"}</strong>
            <small>slots ${((en=e==null?void 0:e.provider)==null?void 0:en.active_slots_now)??0}/${((Wn=e==null?void 0:e.provider)==null?void 0:Wn.actual_slots)??((Bn=e==null?void 0:e.provider)==null?void 0:Bn.total_slots)??0} · ctx ${((Gn=e==null?void 0:e.provider)==null?void 0:Gn.actual_ctx)??((Jn=e==null?void 0:e.provider)==null?void 0:Jn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${L(_.length>0||u>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${_.length+u+p.length}</strong>
            <small>blockers ${_.length} · approvals ${u} · confirms ${p.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Z(M)}</strong>
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
            ${V.length>0?o`
                  <${Er} lanes=${V} />
                  <${Dr} lanes=${V} />
                `:s?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${s.session_id}</strong>
                        <span class="command-chip ${L(Oe(s.status))}">${_s(s.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${s.progress_pct!=null?`${s.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${cn(s.elapsed_sec)}</span>
                        <span>Remaining</span><span>${cn(s.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${c.length>0?o`<div class="command-card-stack">
                  ${c.map(q=>o`<${Rm} worker=${q} />`)}
                </div>`:o`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0?o`<div class="command-trace-stack">
                  ${e.recent_messages.map(q=>o`
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
                </div>`:$.length>0||k.length>0?o`<div class="command-card-stack">
                    ${$.slice(0,4).map(q=>o`
                      <article class="command-guide-card ${ii(q)}">
                        <div class="command-guide-head">
                          <strong>${q.action_type}</strong>
                          <span class="command-chip ${ii(q)}">${q.target_type}</span>
                        </div>
                        <p>${q.reason}</p>
                      </article>
                    `)}
                    ${k.slice(0,3).map(q=>o`
                      <article class="command-alert ${L(q.severity)}">
                        <div class="command-card-head">
                          <strong>${q.kind}</strong>
                          <span class="command-chip ${L(q.severity)}">${q.severity}</span>
                        </div>
                        <p>${q.summary}</p>
                      </article>
                    `)}
                  </div>`:s!=null&&s.recent_events&&s.recent_events.length>0?o`<div class="command-trace-stack">
                      ${s.recent_events.slice(0,6).map((q,Te)=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${Te+1}</strong>
                              <span class="command-chip">${s.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${wr(q)}</pre>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${D} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(q=>o`<${Do} event=${q} />`)}
                </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${_.length>0?_.map(q=>o`<${Or} blocker=${q} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${u>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${u}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${p.length>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${p.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${p.slice(0,3).map(q=>o`<span class="command-tag">${q.confirm_token}</span>`)}
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
              ${e!=null&&e.operation?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${L(Oe(e.operation.status))}">${e.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${e.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${e.operation.trace_id}</span>
                        <span>Autonomy</span><span>${e.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${Z(e.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${e!=null&&e.detachment?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${e.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${L(Oe(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Tr(e.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:null}
              ${s?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${s.session_id}</strong>
                          <div class="command-card-sub">team session focus</div>
                        </div>
                        <span class="command-chip ${L(Oe(s.status))}">${_s(s.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${s.progress_pct!=null?`${s.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${cn(s.elapsed_sec)}</span>
                        <span>Remaining</span><span>${cn(s.remaining_sec)}</span>
                        <span>Done delta</span><span>${s.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function tv(){var c,m,u,p,_,$,k,A,w,M,z,E,I,R,V,G,v,F,tt,W,et;const t=Ce.value,e=ym(),n=Mr(),a=(c=t==null?void 0:t.provider)!=null&&c.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",s=((u=t==null?void 0:t.provider)==null?void 0:u.actual_slots)??((p=t==null?void 0:t.provider)==null?void 0:p.total_slots)??0,i=((_=t==null?void 0:t.provider)==null?void 0:_.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((k=t==null?void 0:t.provider)==null?void 0:k.ctx_per_slot)??0,d=((A=t==null?void 0:t.provider)==null?void 0:A.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${zm} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${La.value?o`<div class="empty-state">Loading swarm live state…</div>`:Da.value?o`<div class="empty-state error">${Da.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((w=t.summary)==null?void 0:w.joined_workers)??0}/${((M=t.summary)==null?void 0:M.expected_workers)??0}</strong><small>${((z=t.summary)==null?void 0:z.live_workers)??0}개 가동 · ${((E=t.summary)==null?void 0:E.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${a}</strong><small>slots ${s}/${i} · ctx ${r}/${d}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(V=t.summary)!=null&&V.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
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
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>o`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(b=>o`<${Xm} item=${b} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(b=>o`<${Qm} worker=${b} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?Z(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?Z(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>o`
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
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(b=>o`<${Or} blocker=${b} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>o`
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
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${D} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>o`<${Do} event=${b} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function ev(){const t=qt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${Bm} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Gm} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function nv(){var d,c,m,u,p,_,$,k,A,w,M,z,E,I,R,V;const t=qn.value,e=(t==null?void 0:t.operations)??[],n=Ke.value,a=e.find(G=>G.operation.operation_id===n)??e[0]??null,s=((d=a==null?void 0:a.operation.chain)==null?void 0:d.run_id)??null,i=((c=Sn.value)==null?void 0:c.run)??(a==null?void 0:a.preview_run)??null,r=!((m=Sn.value)!=null&&m.run)&&!!(a!=null&&a.preview_run);return rt(()=>{s?Lp(s):Mp()},[s]),o`
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

        ${Ea.value?o`<div class="empty-state error">${Ea.value}</div>`:null}

        ${io.value&&!t?o`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(G=>o`
                    <${Um}
                      overlay=${G}
                      selected=${(a==null?void 0:a.operation.operation_id)===G.operation.operation_id}
                      onSelect=${()=>Po(G.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(G=>o`<${Hm} item=${G} />`)}
                </div>
              `:o`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        ${a?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${a.operation.objective}</strong>
                    <div class="command-card-sub">${a.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${ae((k=a.operation.chain)==null?void 0:k.status)}">
                    ${((A=a.operation.chain)==null?void 0:A.status)??a.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((w=a.operation.chain)==null?void 0:w.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((M=a.operation.chain)==null?void 0:M.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${s??"not materialized"}</span>
                  <span>Progress</span><span>${Kn((z=a.runtime)==null?void 0:z.progress)}</span>
                  <span>Elapsed</span><span>${cn((E=a.runtime)==null?void 0:E.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((I=a.operation.chain)==null?void 0:I.last_sync_at)??a.operation.updated_at)}</span>
                </div>
                ${(R=a.operation.chain)!=null&&R.goal?o`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((V=a.operation.chain)==null?void 0:V.chain_id)??"graph"}</span>
                      </div>
                      <${Km} source=${a.mermaid} />
                    </div>
                  `:o`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${za.value?o`<div class="empty-state">Loading run detail…</div>`:An.value?o`<div class="empty-state error">${An.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?o`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(G=>o`<${Wm} node=${G} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function av(){const t=qt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${D} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${zr} node=${e} />`)}`:o`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function sv(){const t=qt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${D} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Jm} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function ov(){const t=qt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${D} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${Do} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function iv(){const t=qt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Vm} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Ym} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function rv(){if(X.value==="warroom")return o`<${Zm} />`;if(X.value==="summary")return o`<${Fm} />`;if(X.value==="swarm")return o`<${tv} />`;if(!qt.value)return o`<${qm} />`;switch(X.value){case"chains":return o`<${nv} />`;case"topology":return o`<${av} />`;case"alerts":return o`<${sv} />`;case"trace":return o`<${ov} />`;case"control":return o`<${iv} />`;case"operations":default:return o`<${ev} />`}}function lv(){return rt(()=>{xe(),ne(),Dp(),Ht()},[]),rt(()=>{if(j.value.tab!=="command")return;const t=j.value.params.surface,e=j.value.params.operation,n=jn(j.value);if(oi(t))ke(t);else if(n){const a=or(n);oi(a)&&ke(a)}else t||ke("warroom");e&&Po(e),(t==="swarm"||t==="warroom"||X.value==="warroom")&&Ht(),(t==="warroom"||X.value==="warroom")&&vt()},[j.value.tab,j.value.params.surface,j.value.params.operation,j.value.params.operation_id,j.value.params.run_id,j.value.params.source,j.value.params.action_type,j.value.params.target_type,j.value.params.target_id,j.value.params.focus_kind]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,xe(),ne(),(X.value==="swarm"||X.value==="warroom")&&Ht(),X.value==="warroom"&&vt()},250))},n=new EventSource(um()),a=lm.map(s=>{const i=()=>e();return n.addEventListener(s,i),{type:s,handler:i}});return n.onerror=()=>{e()},()=>{a.forEach(({type:s,handler:i})=>{n.removeEventListener(s,i)}),n.close(),t&&window.clearTimeout(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{se(()=>jp())}}
            disabled=${lt("dispatch:tick")}
          >
            ${lt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{xe(),ne(),Ht(),X.value==="warroom"&&vt()}}
            disabled=${Ta.value}
          >
            ${Ta.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Ra.value?o`<div class="empty-state error">${Ra.value}</div>`:null}
      ${Pa.value?o`<div class="empty-state error">${Pa.value}</div>`:null}
      <${xt} surfaceId="command" />
      <${fm} />
      ${X.value==="warroom"?null:o`<${gm} />`}
      <${Om} />
      <${rv} />
    </section>
  `}const jr="masc_dashboard_agent_name";function cv(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(jr))==null?void 0:a.trim())||"dashboard"}const os=g(cv()),Ue=g(""),ro=g("운영 점검"),He=g(""),Tn=g(""),In=g("2"),Rn=g(""),Dt=g("note"),Nn=g(""),Pn=g(""),Mn=g(""),Ln=g("2"),Fa=g("운영자 중지 요청"),qa=g(""),We=g(""),Zn=g(null);function dv(t){const e=t.trim()||"dashboard";os.value=e,localStorage.setItem(jr,e)}function ri(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function uv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Ye(t){return typeof t=="string"?t.trim().toLowerCase():""}function pv(t){var a;const e=Ye(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Ye((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function fs(t){const e=Ye(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function li(t){return t.some(e=>Ye(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function mv(t){return t.target_type==="team_session"}function vv(t){return t.target_type==="keeper"}function ta(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function ea(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function on(t){switch(Ye(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function ci(t){return t?"확인 후 실행":"즉시 실행"}function _v(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function ft(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function fv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ft(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function gv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){Ue.value=ft(e,"message")??t.summary;return}t.action_type==="task_inject"&&(He.value=ft(e,"title")??"운영자 주입 작업",Tn.value=ft(e,"description")??t.summary,In.value=ft(e,"priority")??In.value);return}if(t.target_type==="team_session"){if(t.target_id&&(Rn.value=t.target_id),t.action_type==="team_stop"){Fa.value=ft(e,"reason")??t.summary;return}Dt.value=fv(t);const n=ft(e,"message");n&&(Nn.value=n),Dt.value==="task"&&(Pn.value=ft(e,"task_title")??ft(e,"title")??"운영자 주입 작업",Mn.value=ft(e,"task_description")??ft(e,"description")??t.summary,Ln.value=ft(e,"task_priority")??ft(e,"priority")??Ln.value);return}t.target_type==="keeper"&&(t.target_id&&(qa.value=t.target_id),We.value=ft(e,"message")??t.summary)}function $v(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(a=>a.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(a=>a.name===t.target_id):!0}async function we(t){const e=os.value.trim()||"dashboard";try{const n=await tm({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(a,"error"),null}}async function di(){const t=Ue.value.trim();if(!t)return;await we({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Ue.value="")}async function hv(){await we({action_type:"room_pause",target_type:"room",payload:{reason:ro.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function ui(){await we({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function yv(){const t=He.value.trim();if(!t)return;await we({action_type:"task_inject",target_type:"room",payload:{title:t,description:Tn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(In.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(He.value="",Tn.value="")}async function bv(){var r;const t=pe.value,e=Rn.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}const n={},a=Nn.value.trim();a&&(n.message=a);let s="team_note";Dt.value==="broadcast"?s="team_broadcast":Dt.value==="task"&&(s="team_task_inject"),Dt.value==="task"&&(n.task_title=Pn.value.trim()||"운영자 주입 작업",n.task_description=Mn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Ln.value,10)||2),await we({action_type:s,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Nn.value="",Dt.value==="task"&&(Pn.value="",Mn.value=""))}async function kv(){var n;const t=pe.value,e=Rn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){P("먼저 세션을 고르세요","warning");return}await we({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Fa.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function xv(){var s;const t=pe.value,e=qa.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=We.value.trim();if(!e){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await we({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(We.value="")}async function Sv(t){const e=os.value.trim()||"dashboard";try{await em(e,t),P("확인 실행을 완료했습니다","success")}catch(n){const a=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(a,"error")}}function Av(){var R,V,G;const t=pe.value,e=j.value.tab==="intervene"?jn(j.value):null,n=kr.value,a=jt.value,s=(t==null?void 0:t.room)??{},i=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],d=(t==null?void 0:t.pending_confirms)??[],c=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],u=(t==null?void 0:t.available_actions)??[],p=i.find(v=>v.session_id===Rn.value)??i[0]??null,_=r.find(v=>v.name===qa.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],k=$.filter(mv),A=$.filter(vv),w=i.filter(v=>pv(v)!=="ok"),M=r.filter(v=>fs(v)!=="ok"),z=c.slice(0,5),E=$v(e,i,r);rt(()=>{Jt()},[]),rt(()=>{if(j.value.tab!=="intervene"){Zn.value=null;return}if(!e){Zn.value=null;return}Zn.value!==e.id&&(Zn.value=e.id,gv(e))},[j.value.tab,j.value.params.source,j.value.params.action_type,j.value.params.target_type,j.value.params.target_id,j.value.params.focus_kind,e==null?void 0:e.id]),rt(()=>{const v=(p==null?void 0:p.session_id)??null;Ve(v)},[p==null?void 0:p.session_id]);const I=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:d.length,detail:d.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:d.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:k.length>0?k.length:i.length,detail:k.length>0?((R=k[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":i.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:k.length>0?li(k):i.length===0?"warn":w.some(v=>Ye(v.status)==="paused")?"bad":w.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:A.length>0?A.length:M.length,detail:A.length>0?((V=A[0])==null?void 0:V.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":M.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:A.length>0?li(A):M.some(v=>fs(v)==="bad")?"bad":M.length>0?"warn":"ok"}];return o`
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
            value=${os.value}
            onInput=${v=>dv(v.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{vt(),Jt(),Ve((p==null?void 0:p.session_id)??null)}}
            disabled=${Cn.value||Q.value}
          >
            ${Cn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ie.value?o`<section class="ops-banner error">${ie.value}</section>`:null}
      ${Je.value?o`<section class="ops-banner error">${Je.value}</section>`:null}
      ${e?o`
        <section class="ops-banner ${E?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${To(e.action_type)}</span>
            <span>${wo(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${E?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const v=[];if(d.length>0&&v.push({label:`확인 대기 ${d.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const F=document.querySelector(".ops-pending-section");F==null||F.scrollIntoView({behavior:"smooth"})}}),s.paused&&v.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void ui()}),M.length>0){const F=M.filter(tt=>fs(tt)==="bad");v.push({label:F.length>0?`Keeper ${F.length}개 오프라인`:`Keeper ${M.length}개 점검 필요`,desc:F.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:F.length>0?"bad":"warn",onClick:()=>{const tt=document.querySelector(".ops-keeper-section");tt==null||tt.scrollIntoView({behavior:"smooth"})}})}return v.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${v.slice(0,3).map(F=>o`
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
          ${I.map(v=>o`
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
                value=${Ue.value}
                onInput=${v=>{Ue.value=v.target.value}}
                onKeyDown=${v=>{v.key==="Enter"&&di()}}
                disabled=${Q.value}
              />
              <button class="control-btn" onClick=${()=>{di()}} disabled=${Q.value||Ue.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${ro.value}
                onInput=${v=>{ro.value=v.target.value}}
                disabled=${Q.value}
              />
              <button class="control-btn ghost" onClick=${()=>{hv()}} disabled=${Q.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{ui()}} disabled=${Q.value}>
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
              <button class="control-btn" onClick=${()=>{yv()}} disabled=${Q.value||He.value.trim()===""}>
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
            ${wn.value&&!n?o`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:m.length>0?o`
              <div class="ops-log-list">
                ${m.map(v=>o`
                  <article key=${`${v.action_type}:${v.target_type}:${v.target_id??"room"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${ta(v.action_type)}</strong>
                      <span>${ea(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${ci(v.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${v.reason}</div>
                  </article>
                `)}
              </div>
            `:o`
              <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-pending-section">
            <div class="card-title-row">
              <div class="card-title">승인 대기</div>
              <${D} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${d.length>0?o`
              <div class="ops-confirmation-list">
                ${d.map(v=>o`
                  <article key=${v.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${ta(v.action_type)}</strong>
                      <span>${ea(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                      <span>${v.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${v.preview?o`<pre class="ops-code-block compact">${ri(v.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Sv(v.confirm_token)}} disabled=${Q.value}>
                        실행
                      </button>
                      <span class="ops-token">${v.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${D} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${z.length>0?o`
              <div class="ops-feed-list">
                ${z.map(v=>o`
                  <article key=${v.seq??v.id??v.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${v.from}</strong>
                      <span>${v.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${v.content}</div>
                  </article>
                `)}
              </div>
            `:o`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
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
              ${i.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:i.map(v=>{var F;return o`
                <button
                  key=${v.session_id}
                  class="ops-entity-card ${(p==null?void 0:p.session_id)===v.session_id?"active":""}"
                  onClick=${()=>{Rn.value=v.session_id}}
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
            ${p&&a?o`
              <div class="ops-log-list">
                ${a.attention_items.length>0?a.attention_items.map(v=>o`
                  <article key=${`${v.kind}:${v.target_id??"session"}`} class="ops-log-entry ${v.severity}">
                    <div class="ops-log-head">
                      <strong>${v.kind}</strong>
                      <span>${ea(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${v.summary}</div>
                  </article>
                `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${a.worker_cards.length>0?a.worker_cards.map(v=>o`
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
            `:o`
              <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 액션</div>
              <${D} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${p?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${p.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${on(p.status)}</span>
                  <span>경과: ${p.elapsed_sec??0}초</span>
                  <span>남은 시간: ${p.remaining_sec??0}초</span>
                </div>
                ${p.recent_events&&p.recent_events.length>0?o`
                  <pre class="ops-code-block compact">${ri(p.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${Dt.value}
                onChange=${v=>{Dt.value=v.target.value}}
                disabled=${Q.value||!p}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{bv()}} disabled=${Q.value||!p}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${_v(Dt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Nn.value}
              onInput=${v=>{Nn.value=v.target.value}}
              disabled=${Q.value||!p}
            ></textarea>

            ${Dt.value==="task"?o`
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
                value=${Mn.value}
                onInput=${v=>{Mn.value=v.target.value}}
                disabled=${Q.value||!p}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Ln.value}
                onChange=${v=>{Ln.value=v.target.value}}
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
                value=${Fa.value}
                onInput=${v=>{Fa.value=v.target.value}}
                disabled=${Q.value||!p}
              />
              <button class="control-btn ghost" onClick=${()=>{kv()}} disabled=${Q.value||!p}>
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
              ${r.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(v=>o`
                <button
                  key=${v.name}
                  class="ops-entity-card ${(_==null?void 0:_.name)===v.name?"active":""}"
                  onClick=${()=>{qa.value=v.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${v.name}</strong>
                    <span class="status-badge ${v.status??"idle"}">${on(v.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${v.model??"model 확인 필요"}</span>
                    <span>${typeof v.context_ratio=="number"?`${Math.round(v.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${uv(v.last_turn_ago_s)}</span>
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

            ${_?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${_.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${_.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${_.generation??0}</span>
                  <span>활성 목표: ${((G=_.active_goal_ids)==null?void 0:G.length)??0}</span>
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
              onInput=${v=>{We.value=v.target.value}}
              disabled=${Q.value||!_}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{xv()}} disabled=${Q.value||!_||We.value.trim()===""}>
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
              ${u.length?u.map(v=>o`
                    <article key=${`${v.action_type}:${v.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${ta(v.action_type)}</strong>
                        <span>${ea(v.target_type)}</span>
                        <span>${ci(v.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${v.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${D} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${Oa.value.length===0?o`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:Oa.value.map(v=>o`
                <article key=${v.id} class="ops-log-entry ${v.outcome}">
                  <div class="ops-log-head">
                    <strong>${ta(v.action_type)}</strong>
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
  `}function Cv({text:t}){if(!t)return null;const e=wv(t);return o`<div class="markdown-content">${e}</div>`}function wv(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],d=s.slice(r.length).trim(),c=[];for(a++;a<e.length&&!e[a].startsWith(r);)c.push(e[a]),a++;a++,n.push(o`<pre><code class=${d?`language-${d}`:""}>${c.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],d=s.trim().replace(/^<think>/,"").trim();for(d&&d!=="</think>"&&r.push(d),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const m=e[a].replace("</think>","").trim();m&&r.push(m),a++}const c=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${gs(c)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${gs(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${gs(i.join(`
`))}</p>`)}return n}function gs(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Fr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],va=g(null),_a=g([]),Xe=g(!1),be=g(null),pn=g(""),mn=g(!1);function Tv(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Iv=g(Tv());function Rv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function pi(t){return t.updated_at!==t.created_at}async function Eo(t){be.value=t,va.value=null,_a.value=[],Xe.value=!0;try{const e=await Bl(t);if(be.value!==t)return;va.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},_a.value=e.comments??[]}catch{be.value===t&&(va.value=null,_a.value=[])}finally{be.value===t&&(Xe.value=!1)}}async function mi(t){const e=pn.value.trim();if(e){mn.value=!0;try{await Gl(t,Iv.value,e),pn.value="",P("Comment posted","success"),await Eo(t),zt()}catch{P("Failed to post comment","error")}finally{mn.value=!1}}}function Nv(){const t=$n.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Fr.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{$n.value=e.id,zt()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${De.value?"is-active":""}"
          onClick=${()=>{De.value=!De.value,zt()}}
        >
          ${De.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${zt} disabled=${yn.value}>
          ${yn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function $s(){var e;const t=((e=Fr.find(n=>n.id===$n.value))==null?void 0:e.label)??$n.value;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${Xa.value.length}</strong>
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
        <strong>${Zs.value?o`<${ot} timestamp=${Zs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Pv({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Di(t.id,n),zt()}catch{P("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>rl(t.id)}>
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
              ${pi(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${ot} timestamp=${t.created_at} /></span>
            ${pi(t)?o`<span>Updated <${ot} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Rv(t.content)}</div>
      </div>
    </div>
  `}function Mv({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${ot} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Lv({postId:t}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${pn.value}
        onInput=${e=>{pn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&mi(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${mn.value}
      />
      <button
        onClick=${()=>mi(t)}
        disabled=${mn.value||pn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${mn.value?"...":"Post"}
      </button>
    </div>
  `}function Dv({post:t}){be.value!==t.id&&!Xe.value&&Eo(t.id);const e=async n=>{try{await Di(t.id,n),zt()}catch{P("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>gt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Cv} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${ot} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments" semanticId="memory.feed">
        ${Xe.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Mv} comments=${_a.value} />`}
        <${Lv} postId=${t.id} />
      <//>
    </div>
  `}function Ev(){const t=Xa.value,e=j.value.params.post??null,n=e?t.find(a=>a.id===e)??(be.value===e?va.value:null):null;return e&&!n&&be.value!==e&&!Xe.value&&Eo(e),e?n?o`
          <${xt} surfaceId="memory" />
          <${$s} />
          <${Dv} post=${n} />
        `:o`
          <div>
            <${xt} surfaceId="memory" />
            <${$s} />
            <button class="back-btn" onClick=${()=>gt("memory")}>← Back to Memory</button>
            ${Xe.value?o`<div class="loading-indicator">Loading post...</div>`:o`<div class="empty-state">Post not found</div>`}
          </div>
        `:o`
    <div>
      <${xt} surfaceId="memory" />
      <${$s} />
      <${Nv} />
      ${yn.value?o`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?o`<div class="empty-state">No posts in durable memory right now</div>`:o`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(a=>o`<${Pv} key=${a.id} post=${a} />`)}
                </div>
              <//>
            `}
    </div>
  `}function qr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let d="mitosis-safe";return t>=.8?d="mitosis-critical":t>=.5&&(d="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${d}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${d}">${Math.round(t*100)}%</span>
    </div>
  `}const hs=600*1e3,zv=1200*1e3,vi=.8;function te(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ne(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Ov(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function jv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Fv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function qv(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Kv(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Uv(t){var c,m;const e=Wi.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-te(n)):Number.POSITIVE_INFINITY,s=!!((c=t.current_task)!=null&&c.trim())||e.activeAssignedCount>0;let i="watching",r="ok",d="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",d=n?"Offline or inactive":"No recent presence"):a>zv?(i="quiet",r="bad",d=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>hs?"warn":"ok",d=a>hs?"Execution looks quiet for too long":"Task and live signal aligned"):a>hs?(i="quiet",r="warn",d="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",d="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:d}}function Hv(t){const e=Jc.value.get(t.name)??"idle",n=Xc.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=vi)&&(s="warning",i="warn",r=a>=vi?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:qv(t),note:r}}function rn({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Wv({item:t}){const e=t.kind==="agent"?()=>es(t.agent.name):()=>So(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${ot} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function _i({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>es(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${qr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${de} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Ov(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${ot} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${ot} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function Bv({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>So(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${qr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${de} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${jv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${ot} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Kv(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Fv(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function Gv(){const t=[...Yt.value].map(Uv).sort((u,p)=>{const _=Ne(p.tone)-Ne(u.tone);if(_!==0)return _;const $=p.activeTaskCount-u.activeTaskCount;return $!==0?$:te(p.lastSignalAt)-te(u.lastSignalAt)}),e=[...ce.value].map(Hv).sort((u,p)=>{const _=Ne(p.tone)-Ne(u.tone);if(_!==0)return _;const $=(p.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return $!==0?$:te(p.keeper.last_heartbeat)-te(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline"),a=t.filter(u=>u.state==="offline"),s=n.length,i=t.filter(u=>u.state==="working").length,r=t.filter(u=>u.lastSignalAt&&Date.now()-te(u.lastSignalAt)<=12e4).length,d=t.filter(u=>u.tone!=="ok"),c=e.filter(u=>u.tone!=="ok"),m=[...c.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...d.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,p)=>{const _=Ne(p.tone)-Ne(u.tone);return _!==0?_:te(p.timestamp)-te(u.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <${xt} surfaceId="execution" />
      <div class="stats-grid">
        <${rn} label="Workers online" value=${s} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${rn} label="Working now" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${rn} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${rn} label="Worker alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${rn} label="Continuity alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${T} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?o`<div class="empty-state">No execution alerts right now</div>`:m.map(u=>o`<${Wv} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?o`<div class="empty-state">No active workers visible</div>`:n.map(u=>o`<${_i} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(u=>o`<${Bv} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${a.length===0?o`<div class="empty-state">No offline workers right now</div>`:a.map(u=>o`<${_i} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ka=g("all"),Ua=g("all"),lo=re(()=>{let t=hn.value;return Ka.value!=="all"&&(t=t.filter(e=>e.horizon===Ka.value)),Ua.value!=="all"&&(t=t.filter(e=>e.status===Ua.value)),t}),Jv=re(()=>{const t={short:[],mid:[],long:[]};for(const e of lo.value){const n=t[e.horizon];n&&n.push(e)}return t}),Vv=re(()=>{const t=Array.from(qi.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Yv(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function zo(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function fa(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Xv(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function fi(t){return t.toFixed(4)}function gi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Qv({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${fa(t.horizon)}">
            ${zo(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Yv(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${ot} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${de} status=${t.status} />
        <div class="goal-updated">
          <${ot} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function $i({label:t,timestamp:e,source:n,note:a}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?o`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${ot} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function ys({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${T} title="${zo(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(a=>o`<${Qv} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function Zv(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ka.value===t?"active":""}"
            onClick=${()=>{Ka.value=t}}
          >
            ${t==="all"?"All":zo(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ua.value===t?"active":""}"
            onClick=${()=>{Ua.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function t_(){const t=hn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${fa("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function e_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${de} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${fi(t.baseline_metric)}</span>
          <span>Current ${fi(t.current_metric)}</span>
          <span class=${gi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${gi(t)}
          </span>
          <span>Elapsed ${Xv(t.elapsed_seconds)}</span>
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
  `}function bs({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${ot} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function n_(){const{todo:t,inProgress:e,done:n}=Bc.value;return o`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${bs} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${bs} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${bs} key=${a.id} task=${a} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function a_(){const t=Jv.value,e=Vv.value,n=e.filter(d=>d.status==="running").length,a=e.filter(d=>d.recoverable).length,s=hn.value.filter(d=>d.status==="active").length,i=ho.value,r=i==="idle"?"No loop running":i==="error"?ba.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <${xt} surfaceId="planning" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${lo.value.length}</div>
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
            <button class="control-btn ghost" onClick=${eo} disabled=${ze.value}>
              ${ze.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Ge(),eo()}}
              disabled=${Ee.value||ze.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${$i} label="Goals" timestamp=${Ui.value} source="/api/v1/dashboard/planning" />
          <${$i}
            label="MDAL loops"
            timestamp=${Hi.value}
            source="/api/v1/dashboard/planning"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section" semanticId="planning.goal_pipeline">
        <${t_} />
        <${Zv} />
      <//>

      ${Ee.value&&hn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:lo.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${ys} horizon="short" items=${t.short??[]} />
              <${ys} horizon="mid" items=${t.mid??[]} />
              <${ys} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section" semanticId="planning.mdal_loops">
        ${ze.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
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
                  ${e.map(d=>o`<${e_} key=${d.loop_id} loop=${d} />`)}
                </div>
              `}
      <//>

      <${n_} />
    </div>
  `}const vn=g("debates"),Ha=g([]),Wa=g([]),Ba=g(!1),_n=g(!1),Dn=g(""),fn=g(""),Ga=g(null),Rt=g(null),co=g(!1);async function is(){Ba.value=!0,Dn.value="";try{const t=await Il();Ha.value=Array.isArray(t.debates)?t.debates:[],Wa.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){Dn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Ba.value=!1}}pd(is);async function hi(){const t=fn.value.trim();if(t){_n.value=!0;try{const e=await yc(t);fn.value="",P(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await is()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";P(n,"error")}finally{_n.value=!1}}}async function s_(t){Ga.value=t,Rt.value=null,co.value=!0;try{Rt.value=await bc(t)}catch(e){Dn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{co.value=!1}}function o_(){return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Ha.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Wa.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${vn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function i_({debate:t}){const e=Ga.value===t.id;return o`
    <button class="council-row ${e?"selected":""}" onClick=${()=>s_(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?o`<span><${ot} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function r_({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?o`<span><${ot} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function l_(){const t=vn.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{vn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{vn.value="voting"}}>Voting</button>
    </div>
  `}function c_(){return o`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${fn.value}
            onInput=${t=>{fn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&hi()}}
            disabled=${_n.value}
          />
          <button
            class="control-btn secondary"
            onClick=${hi}
            disabled=${_n.value||fn.value.trim()===""}
          >
            ${_n.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${is} disabled=${Ba.value}>
            ${Ba.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Dn.value?o`<div class="council-error">${Dn.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Ha.value.length===0?o`<div class="empty-state">No debates yet</div>`:Ha.value.map(t=>o`<${i_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Ga.value?`Debate Detail (${Ga.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${co.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Rt.value?o`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${Rt.value.status}</span>
                  <span>Total arguments: ${Rt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${Rt.value.support_count}</span>
                  <span>Oppose: ${Rt.value.oppose_count}</span>
                  <span>Neutral: ${Rt.value.neutral_count}</span>
                </div>
                ${Rt.value.summary_text?o`<pre class="council-detail">${Rt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function d_(){return o`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Wa.value.length===0?o`<div class="empty-state">No active sessions</div>`:Wa.value.map(t=>o`<${r_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function u_(){return rt(()=>{is()},[]),o`
    <div>
      <${xt} surfaceId="governance" />
      <${o_} />
      <${l_} />
      ${vn.value==="debates"?o`<${c_} />`:o`<${d_} />`}
    </div>
  `}const Me=g(""),ks=g("ability_check"),xs=g("10"),Ss=g("12"),na=g(""),aa=g("idle"),ee=g(""),sa=g("keeper-late"),As=g("player"),Cs=g(""),kt=g("idle"),ws=g(null),oa=g(""),Ts=g(""),Is=g("player"),Rs=g(""),Ns=g(""),Ps=g(""),gn=g("20"),Ms=g("20"),Ls=g(""),ia=g("idle"),uo=g(null),Kr=g("overview"),Ds=g("all"),Es=g("all"),zs=g("all"),p_=12e4,rs=g(null),yi=g(Date.now());function m_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function v_(t,e){return e>0?Math.round(t/e*100):0}const __={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},f_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ra(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function g_(t){const e=t.trim().toLowerCase();return __[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function $_(t){const e=t.trim().toLowerCase();return f_[e]??"상황에 따라 선택되는 전술 액션입니다."}function oe(t){return typeof t=="object"&&t!==null}function ht(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function Nt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function En(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const h_=new Set(["str","dex","con","int","wis","cha"]);function y_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!oe(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const d=Number.parseFloat(i.trim());if(Number.isFinite(d)){a[r]=Math.max(0,Math.trunc(d));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function b_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(gn.value.trim(),10);Number.isFinite(a)&&a>n&&(gn.value=String(n))}function po(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function k_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function x_(t){Kr.value=t}function Ur(t){const e=rs.value;return e==null||e<=t}function S_(t){const e=rs.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ja(){rs.value=null}function Hr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function A_(t,e){Hr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(rs.value=Date.now()+p_,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ga(t){return Ur(t)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function mo(t,e,n){return Hr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function C_({hp:t,max:e}){const n=v_(t,e),a=m_(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function w_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function T_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Wr({actor:t}){var c,m,u,p;const e=(c=t.archetype)==null?void 0:c.trim(),n=(m=t.persona)==null?void 0:m.trim(),a=(u=t.portrait)==null?void 0:u.trim(),s=(p=t.background)==null?void 0:p.trim(),i=t.traits??[],r=t.skills??[],d=Object.entries(t.stats_raw??{}).filter(([_,$])=>Number.isFinite($)).filter(([_])=>!h_.has(_.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${_=>{const $=_.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${de} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${T_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${C_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${w_} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${ra(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${d.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${d.map(([_,$])=>o`
                <span class="trpg-custom-stat-chip">${ra(_)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(_=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${ra(_)}</span>
                  <span class="trpg-annot-desc">${g_(_)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(_=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${ra(_)}</span>
                  <span class="trpg-annot-desc">${$_(_)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function I_({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Br({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${k_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${po(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${ot} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function R_({events:t}){const e="__none__",n=Ds.value,a=Es.value,s=zs.value,i=Array.from(new Set(t.map(po).map(p=>p.trim()).filter(p=>p!==""))).sort((p,_)=>p.localeCompare(_)),r=Array.from(new Set(t.map(p=>(p.type??"").trim()).filter(p=>p!==""))).sort((p,_)=>p.localeCompare(_)),d=t.some(p=>(p.type??"").trim()===""),c=Array.from(new Set(t.map(p=>(p.phase??"").trim()).filter(p=>p!==""))).sort((p,_)=>p.localeCompare(_)),m=t.some(p=>(p.phase??"").trim()===""),u=t.filter(p=>{if(n!=="all"&&po(p)!==n)return!1;const _=(p.type??"").trim(),$=(p.phase??"").trim();if(a===e){if(_!=="")return!1}else if(a!=="all"&&_!==a)return!1;if(s===e){if($!=="")return!1}else if(s!=="all"&&$!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${p=>{Ds.value=p.target.value}}>
          <option value="all">all</option>
          ${i.map(p=>o`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${p=>{Es.value=p.target.value}}>
          <option value="all">all</option>
          ${d?o`<option value=${e}>(none)</option>`:null}
          ${r.map(p=>o`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${p=>{zs.value=p.target.value}}>
          <option value="all">all</option>
          ${m?o`<option value=${e}>(none)</option>`:null}
          ${c.map(p=>o`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ds.value="all",Es.value="all",zs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Br} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function N_({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function Gr({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function P_({state:t,nowMs:e}){var m;const n=Wt.value||((m=t.session)==null?void 0:m.room)||"",a=aa.value,s=t.party??[];if(!s.find(u=>u.id===Me.value)&&s.length>0){const u=s[0];u&&(Me.value=u.id)}const r=async()=>{var p,_;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!ga(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"unknown";if(mo("라운드 실행",n,u)){aa.value="running";try{const $=await cc(n);uo.value=$,aa.value="ok";const k=oe($.summary)?$.summary:null,A=k?En(k,"advanced",!1):!1,w=k?ht(k,"progress_reason",""):"";P(A?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,A?"success":"warning"),Ot()}catch($){uo.value=null,aa.value="error";const k=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";P(k,"error")}finally{Ja()}}},d=async()=>{var p,_;if(!n||!ga(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"unknown";if(mo("턴 강제 진행",n,u))try{await pc(n),P("턴을 다음 단계로 이동했습니다.","success"),Ot()}catch{P("턴 이동에 실패했습니다.","error")}finally{Ja()}},c=async()=>{if(!n||!ga(e))return;const u=Me.value.trim();if(!u){P("먼저 Actor를 선택하세요.","warning");return}const p=Number.parseInt(xs.value,10),_=Number.parseInt(Ss.value,10);if(Number.isNaN(p)||Number.isNaN(_)){P("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(na.value,10),k=na.value.trim()===""||Number.isNaN($)?void 0:$;try{await uc({roomId:n,actorId:u,action:ks.value.trim()||"ability_check",statValue:p,dc:_,rawD20:k}),P("주사위 판정을 기록했습니다.","success"),Ot()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Wt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Me.value}
            onChange=${u=>{Me.value=u.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(u=>o`<option value=${u.id}>${u.name} (${u.id})</option>`)}
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
              onInput=${u=>{ks.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${xs.value}
              onInput=${u=>{xs.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ss.value}
              onInput=${u=>{Ss.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${na.value}
              onInput=${u=>{na.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&c()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${c}>Roll</button>
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

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function M_({state:t}){var s;const e=Wt.value||((s=t.session)==null?void 0:s.room)||"",n=ia.value,a=async()=>{if(!e){P("Room ID가 비어 있습니다.","warning");return}const i=oa.value.trim(),r=Ts.value.trim();if(!r&&!i){P("이름 또는 Actor ID를 입력하세요.","warning");return}const d=Number.parseInt(gn.value.trim(),10),c=Number.parseInt(Ms.value.trim(),10),m=Number.isFinite(c)?Math.max(1,c):20,u=Number.isFinite(d)?Math.max(0,Math.min(m,d)):m;let p={};try{p=y_(Ls.value)}catch(_){P(_ instanceof Error?_.message:"능력치 JSON 오류","error");return}ia.value="spawning";try{const _=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await mc(e,{actor_id:i||void 0,name:r||void 0,role:Is.value,idempotencyKey:_,portrait:Ns.value.trim()||void 0,background:Ps.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(p).length>0?p:void 0}),k=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!k)throw new Error("생성 응답에 actor_id가 없습니다.");const A=Rs.value.trim();A&&await vc(e,k,A),Me.value=k,ee.value=k,i||(oa.value=""),ia.value="ok",P(`Actor 생성 완료: ${k}`,"success"),await Ot()}catch(_){ia.value="error",P(_ instanceof Error?_.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ts.value}
            onInput=${i=>{Ts.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Is.value}
            onChange=${i=>{Is.value=i.target.value}}
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
            onInput=${i=>{Rs.value=i.target.value}}
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
              value=${oa.value}
              onInput=${i=>{oa.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ns.value}
              onInput=${i=>{Ns.value=i.target.value}}
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
              onInput=${i=>{gn.value=i.target.value}}
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
              value=${Ms.value}
              onInput=${i=>{const r=i.target.value;Ms.value=r,b_(r)}}
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
              onInput=${i=>{Ps.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ls.value}
              onInput=${i=>{Ls.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function L_({state:t,nowMs:e}){var _;const n=Wt.value||((_=t.session)==null?void 0:_.room)||"",a=t.join_gate,s=ws.value,i=oe(s)?s:null,r=(t.party??[]).filter($=>$.role!=="dm"),d=ee.value.trim(),c=r.some($=>$.id===d),m=c?d:d?"__manual__":"",u=async()=>{const $=ee.value.trim(),k=sa.value.trim();if(!n||!$){P("Room/Actor가 필요합니다.","warning");return}kt.value="checking";try{const A=await _c(n,$,k||void 0);ws.value=A,kt.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch(A){kt.value="error";const w=A instanceof Error?A.message:"참가 가능 여부 확인에 실패했습니다.";P(w,"error")}},p=async()=>{var M,z;const $=ee.value.trim(),k=sa.value.trim(),A=Cs.value.trim();if(!n||!$||!k){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ga(e))return;const w=((M=t.current_round)==null?void 0:M.phase)??((z=t.session)==null?void 0:z.status)??"unknown";if(mo("Mid-Join 승인 요청",n,w)){kt.value="requesting";try{const E=await fc({room_id:n,actor_id:$,keeper_name:k,role:As.value,...A?{name:A}:{}});ws.value=E;const I=oe(E)?En(E,"granted",!1):!1,R=oe(E)?ht(E,"reason_code",""):"";I?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),kt.value=I?"ok":"error",Ot()}catch(E){kt.value="error";const I=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";P(I,"error")}finally{Ja()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${a!=null&&a.phase_open?"OPEN":"CLOSED"}</strong>
        ${a!=null&&a.window?o`<span style="margin-left:8px;">(${a.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(a==null?void 0:a.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${m}
            onChange=${$=>{const k=$.target.value;if(k==="__manual__"){(c||!d)&&(ee.value="");return}ee.value=k}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>o`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ee.value}
                onInput=${$=>{ee.value=$.target.value}}
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
            value=${sa.value}
            onInput=${$=>{sa.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${As.value}
            onChange=${$=>{As.value=$.target.value}}
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
            value=${Cs.value}
            onInput=${$=>{Cs.value=$.target.value}}
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
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${En(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Nt(i,"effective_score",0)}/${Nt(i,"required_points",0)}</span>
            ${ht(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ht(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Jr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Vr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Yr(){const t=uo.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=oe(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(oe).slice(-8),i=t.canon_check,r=oe(i)?i:null,d=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],c=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],m=n?En(n,"advanced",!1):!1,u=n?ht(n,"progress_reason",""):"",p=n?ht(n,"progress_detail",""):"",_=n?Nt(n,"player_successes",0):0,$=n?Nt(n,"player_required_successes",0):0,k=n?En(n,"dm_success",!1):!1,A=n?Nt(n,"timeouts",0):0,w=n?Nt(n,"unavailable",0):0,M=n?Nt(n,"reprompts",0):0,z=n?Nt(n,"npc_attacks",0):0,E=n?Nt(n,"keeper_timeout_sec",0):0,I=n?Nt(n,"roll_audit_count",0):0;return o`
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
        ${u?o`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${p?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${p}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${M}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${z}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${I}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(R=>{const V=ht(R,"status","unknown"),G=ht(R,"actor_id","-"),v=ht(R,"role","-"),F=ht(R,"reason",""),tt=ht(R,"action_type",""),W=ht(R,"reply","");return o`
                <div class="trpg-round-item ${V.includes("fallback")||V.includes("timeout")?"failed":"active"}">
                  <span>${G} (${v})</span>
                  <span style="margin-left:auto; font-size:11px;">${V}</span>
                  ${tt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${F?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${F}</div>`:null}
                  ${W?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${W.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ht(r,"status","unknown")}</strong>
            </div>
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${c.map(R=>o`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${d.map(R=>o`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function D_({state:t,nowMs:e}){var r,d,c;const n=Wt.value||((r=t.session)==null?void 0:r.room)||"",a=((d=t.current_round)==null?void 0:d.phase)??((c=t.session)==null?void 0:c.status)??"unknown",s=Ur(e),i=S_(e);return o`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>A_(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ja(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function E_({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>x_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function z_({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${Br} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${I_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${Vr} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Jr} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${Wr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Gr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function O_({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${R_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Yr} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Vr} state=${t} />
        <//>
      </div>
    </div>
  `}function j_({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${D_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${P_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${M_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${L_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Yr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Jr} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${Wr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Gr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function F_(){var d,c,m,u,p;const t=Fi.value,e=Qs.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const _=window.setInterval(()=>{yi.value=Date.now()},1e3);return()=>{window.clearInterval(_)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ot()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=Kr.value,r=yi.value;return o`
    <div>
      <${xt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Wt.value||((d=t.session)==null?void 0:d.room)||"-"} · phase: ${((c=t.current_round)==null?void 0:c.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ot()}>새로고침</button>
      </div>

      <${N_} outcome=${s} />

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
          <div class="stat-value">${a.length}</div>
        </div>
      </div>

      <${E_} active=${i} />

      ${i==="overview"?o`<${z_} state=${t} />`:i==="timeline"?o`<${O_} state=${t} />`:o`<${j_} state=${t} nowMs=${r} />`}
    </div>
  `}function q_(){return o`
    <div>
      <${xt} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${F_} />
      <//>
    </div>
  `}const bi=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],vo=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function K_(){const t=Se.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${_o.value} events</span>
    </div>
  `}function U_({currentTab:t,currentSectionLabel:e}){const n=Se.value;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${D} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${Yt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${ce.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Et.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${_o.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{On(),Ji(),t==="command"&&(xe(),ne(),(X.value==="swarm"||X.value==="warroom")&&Ht(),X.value==="warroom"&&vt()),t==="mission"&&pa(),t==="execution"&&Kt(),t==="intervene"&&(vt(),Jt()),t==="memory"&&zt(),t==="planning"&&Ge(),t==="lab"&&Ot()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>gt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function H_(){const t=pe.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,a=(t==null?void 0:t.keepers.length)??0;return o`
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
          <strong>${a}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{vt(),Jt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>gt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function W_(){const t=j.value.tab,e=vo.find(a=>a.id===t),n=bi.find(a=>a.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${xt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${D} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${bi.map(a=>o`
          <div class="rail-nav-group" key=${a.id}>
            <div class="rail-group-label">${a.label}</div>
            <div class="rail-group-copy">${a.description}</div>
            <div class="rail-tab-list">
              ${vo.filter(s=>s.group===a.id).map(s=>o`
                  <button
                    class="rail-tab-btn ${t===s.id?"active":""}"
                    onClick=${()=>gt(s.id)}
                  >
                    <span class="rail-tab-icon">${s.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${s.label}</strong>
                      <span>${s.description}</span>
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

      <${U_} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${H_} />
    </aside>
  `}function B_(){switch(j.value.tab){case"mission":return o`<${ti} />`;case"execution":return o`<${Gv} />`;case"memory":return o`<${Ev} />`;case"governance":return o`<${u_} />`;case"planning":return o`<${a_} />`;case"intervene":return o`<${Av} />`;case"command":return o`<${lv} />`;case"lab":return o`<${q_} />`;default:return o`<${ti} />`}}function G_(){rt(()=>{ll(),Ii(),Vi(),Kt(),Ji(),pa();const n=_d();return fd(),()=>{fl(),n(),gd()}},[]),rt(()=>{const n=setInterval(()=>{const a=j.value.tab;a==="command"?(xe(),ne(),(X.value==="swarm"||X.value==="warroom")&&Ht(),X.value==="warroom"&&vt()):a==="mission"?pa():a==="execution"?Kt():a==="intervene"?(vt(),Jt()):a==="memory"?zt():a==="planning"?Ge():a==="lab"&&Ot()},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=j.value.tab;n==="command"&&(xe(),ne(),(X.value==="swarm"||X.value==="warroom")&&Ht(),X.value==="warroom"&&vt()),n==="mission"&&pa(),n==="execution"&&Kt(),n==="intervene"&&(vt(),Jt()),n==="memory"&&zt(),n==="planning"&&Ge(),n==="lab"&&Ot()},[j.value.tab]);const t=j.value.tab,e=vo.find(n=>n.id===t);return o`
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
          <${K_} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${W_} />
        <main class="dashboard-main">
          ${Xs.value&&!Se.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${B_} />`}
        </main>
      </div>

      <${nu} />
      <${zd} />
      <${Pd} />
    </div>
  `}const ki=document.getElementById("app");ki&&al(o`<${G_} />`,ki);export{Hu as _};
