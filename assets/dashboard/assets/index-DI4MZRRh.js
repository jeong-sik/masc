var il=Object.defineProperty;var rl=(t,e,n)=>e in t?il(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ne=(t,e,n)=>rl(t,typeof e!="symbol"?e+"":e,n);import{e as ll,_ as cl,c as f,b as Nt,y as rt,d as Ti,A as dl,G as ul}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=ll.bind(cl);const pl=["mission","execution","live","memory","governance","planning","intervene","command","lab"],Ii={tab:"mission",params:{},postId:null};function Ko(t){return!!t&&pl.includes(t)}function Ua(t){try{return decodeURIComponent(t)}catch{return t}}function Ha(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ml(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ni(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=Ua(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=Ua(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],s=e.tab;return{tab:Ko(n)?n:Ko(s)?s:"mission",params:e,postId:null}}function bs(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Ii;const n=Ua(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Ha(a),r=ml(s);return Ni(r,i)}function vl(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Ii,params:Ha(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ha(e.replace(/^\?/,""));return Ni(s,a)}function Ri(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const O=f(bs(window.location.hash));window.addEventListener("hashchange",()=>{O.value=bs(window.location.hash)});function gt(t,e){const n={tab:t,params:e??{}};window.location.hash=Ri(n)}function _l(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function fl(){if(window.location.hash&&window.location.hash!=="#"){O.value=bs(window.location.hash);return}const t=vl(window.location.pathname,window.location.search);if(t){O.value=t;const e=Ri(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",O.value=bs(window.location.hash)}const Uo="masc_dashboard_sse_session_id",gl=1e3,$l=15e3,de=f(!1),Zs=f(0),Pi=f(null),ks=f([]);function hl(){let t=sessionStorage.getItem(Uo);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Uo,t)),t}const yl=200;function bl(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ks.value=[a,...ks.value].slice(0,yl)}function Wa(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Ho(t,e){const n=Wa(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function wt(t,e,n,s,a={}){bl(t,e,n,{eventType:s,...a})}let Dt=null,qe=null,Ba=0;function Li(){qe&&(clearTimeout(qe),qe=null)}function kl(){if(qe)return;Ba++;const t=Math.min(Ba,5),e=Math.min($l,gl*Math.pow(2,t));qe=setTimeout(()=>{qe=null,Mi()},e)}function Mi(){Li(),Dt&&(Dt.close(),Dt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",hl());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);Dt=i,i.onopen=()=>{Dt===i&&(Ba=0,de.value=!0)},i.onerror=()=>{Dt===i&&(de.value=!1,i.close(),Dt=null,kl())},i.onmessage=r=>{try{const c=JSON.parse(r.data);Zs.value++,Pi.value=c,xl(c)}catch{}}}function xl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":wt(n,"Joined","system","agent_joined");break;case"agent_left":wt(n,"Left","system","agent_left");break;case"broadcast":wt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":wt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":wt(n,Ho("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Wa(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":wt(n,Ho("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Wa(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":wt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":wt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":wt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":wt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:wt(n,e,"system","unknown")}}function Sl(){Li(),Dt&&(Dt.close(),Dt=null),de.value=!1}function Di(){return new URLSearchParams(window.location.search)}function Ei(){const t=Di(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function zi(){return{...Ei(),"Content-Type":"application/json"}}const Al=15e3,ho=3e4,Cl=6e4,Wo=new Set([408,425,429,500,502,503,504]);class Fn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ne(this,"method");Ne(this,"path");Ne(this,"status");Ne(this,"statusText");Ne(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function yo(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Fn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function wl(){var e,n;const t=Di();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function it(t){const e=await yo(t,{headers:Ei()},Al);if(!e.ok)throw new Fn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Tl(t){return new Promise(e=>setTimeout(e,t))}function Il(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Nl(t){if(t instanceof Fn)return t.timeout||typeof t.status=="number"&&Wo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Il(t.message);return e!==null&&Wo.has(e)}async function ji(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Nl(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await Tl(i),s+=1}}async function Ht(t,e,n,s=ho){const a=await yo(t,{method:"POST",headers:{...zi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Fn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Rl(t,e,n,s=ho){const a=await yo(t,{method:"POST",headers:{...zi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new Fn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Pl(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Ll(t){var e,n,s,a,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function pe(t,e){const n=await Rl("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Cl),s=Pl(n);return Ll(s)}function Ml(){return it("/api/v1/dashboard/shell")}function Dl(){return it("/api/v1/dashboard/execution")}function El(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),it(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function zl(){return it("/api/v1/dashboard/governance")}function jl(){return it("/api/v1/dashboard/semantics")}function Ol(){return it("/api/v1/dashboard/mission")}function Fl(){return it("/api/v1/dashboard/planning")}function ql(){return it("/api/v1/operator")}function Oi(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return it(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Kl(){return it("/api/v1/command-plane")}function Ul(){return it("/api/v1/command-plane/summary")}function Hl(){return it("/api/v1/chains/summary")}function Wl(t){return it(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Bl(){return it("/api/v1/command-plane/help")}function Gl(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return it(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Jl(t,e){return Ht(t,e)}function Vl(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return ho}}function ta(t){return Ht("/api/v1/operator/action",t,void 0,Vl(t))}function Yl(t,e){return Ht("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function un(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Xl(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Ql(t){if(!K(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),s=h(t.content,"").trim();if(!e||!n)return null;const a=J(t.score,0),i=J(t.votes_up,0),r=J(t.votes_down,0),c=J(t.votes,a||i-r),d=J(t.comment_count,J(t.reply_count,0)),m=(()=>{const b=t.flair;if(typeof b=="string"&&b.trim())return b.trim();if(K(b)){const I=h(b.name,"").trim();if(I)return I}return h(t.flair_name,"").trim()||void 0})(),u=h(t.created_at_iso,"").trim()||un(t.created_at),p=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?un(t.updated_at):u),$=h(t.title,"").trim()||Xl(s),x=Array.isArray(t.tags)?t.tags.filter(b=>typeof b=="string"&&b.trim()!==""):[];return{id:e,author:n,title:$,content:s,tags:x,votes:c,vote_balance:a,comment_count:d,created_at:u,updated_at:p,flair:m,hearth:h(t.hearth,"").trim()||null,visibility:h(t.visibility,"").trim()||void 0,expires_at:h(t.expires_at_iso,"").trim()||(t.expires_at!==void 0?un(t.expires_at):"")||null,hearth_count:J(t.hearth_count,0)}}function Zl(t){if(!K(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),s=h(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:h(t.content,""),created_at:un(t.created_at)}}async function tc(t){return ji("fetchBoardPost",async()=>{const e=await it(`/api/v1/board/${t}?format=flat`),n=K(e.post)?e.post:e,s=Ql(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(e.comments)?e.comments:[]).map(Zl).filter(r=>r!==null);return{...s,comments:i}})}function Fi(t,e){return Ht("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:wl()})}function ec(t,e,n){return Ht("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function nc(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function pt(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function Bo(t){const e=nc(pt(t.outcome,t.result,t.result_code));if(!e)return;const n=pt(t.reason,t.reason_code,t.description,t.detail),s=pt(t.summary,t.summary_ko,t.summary_en,t.note),a=pt(t.details,t.details_text,t.text,t.note),i=pt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=pt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=pt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const p=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof p=="string"?[p]:Array.isArray(p)?p.map(v=>{if(typeof v=="string")return v.trim();if(K(v)){const $=h(v.summary,"").trim();if($)return $;const x=h(v.text,"").trim();if(x)return x;const b=h(v.type,"").trim();return b||h(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),m=(()=>{const p=J(t.turn,Number.NaN);if(Number.isFinite(p))return p;const v=J(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const $=J(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const x=J(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),u=pt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function sc(t,e){const n=K(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>K(r)?h(r.type,"")==="session.outcome":!1),i=K(n.session_outcome)?n.session_outcome:{};if(K(i)&&Object.keys(i).length>0){const r=Bo(i);if(r)return r}if(K(a))return Bo(K(a.payload)?a.payload:{})}function K(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function J(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ac(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Ga(t,e=!1){return typeof t=="boolean"?t:e}function sn(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(K(e)){const n=h(e.name,"").trim(),s=h(e.id,"").trim(),a=h(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function oc(t){const e={};if(!K(t)&&!Array.isArray(t))return e;if(K(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=h(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!K(n))continue;const s=pt(n.to,n.target,n.actor_id,n.name,n.id),a=pt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function ic(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function bt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const rc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function lc(t){const e=K(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(rc.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function cc(t,e){if(t!=="dice.rolled")return;const n=J(e.raw_d20,0),s=J(e.total,0),a=J(e.bonus,0),i=h(e.action,"roll"),r=J(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function dc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function uc(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function pc(t,e,n,s){const a=n||e||h(s.actor_id,"")||h(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(s.proposed_action,h(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(s.reply,h(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(s.reply,h(s.content,h(s.text,"Narration")));case"dice.rolled":{const i=h(s.action,"roll"),r=J(s.total,0),c=J(s.dc,0),d=h(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",p=d?` (${d})`:"";return`${m} ${i}: ${r}${u}${p}`}case"turn.started":return`Turn ${J(s.turn,1)} started`;case"phase.changed":return`Phase: ${h(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(s.name,K(s.actor)?h(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${h(s.keeper_name,h(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${h(s.keeper_name,h(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${J(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${J(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||h(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||h(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(s.reason_code,"unknown")}`;case"memory.signal":{const i=K(s.entity_refs)?s.entity_refs:{},r=h(i.requested_tier,""),c=h(i.effective_tier,""),d=Ga(i.guardrail_applied,!1),m=h(s.summary_en,h(s.summary_ko,"Memory signal"));if(!r&&!c)return m;const u=r&&c?`${r}->${c}`:c||r;return`${m} [${u}${d?" (guardrail)":""}]`}case"world.event":{if(h(s.event_type,"")==="canon.check"){const r=h(s.status,"unknown"),c=h(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return h(s.description,h(s.summary,"World event"))}case"combat.attack":return h(s.summary,h(s.result,"Attack resolved"));case"combat.defense":return h(s.summary,h(s.result,"Defense resolved"));case"session.outcome":return h(s.summary,h(s.outcome,"Session ended"));default:{const i=dc(s);return i?`${t}: ${i}`:t}}}function mc(t,e){const n=K(t)?t:{},s=h(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[a]||h(K(n.payload)?n.payload.actor_name:"",""),r=K(n.payload)?n.payload:{},c=h(n.ts,h(n.timestamp,new Date().toISOString())),d=h(n.phase,h(r.phase,"")),m=h(n.category,"");return{type:s,actor:i||a||h(r.actor_name,""),actor_id:a||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:d||void 0,category:m||uc(s),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:pc(s,a,i,r),dice_roll:cc(s,r),timestamp:c}}function vc(t,e,n){var F,tt;const s=h(t.room_id,"")||n||"default",a=K(t.state)?t.state:{},i=K(a.party)?a.party:{},r=K(a.actor_control)?a.actor_control:{},c=K(a.join_gate)?a.join_gate:{},d=K(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(i).map(([W,et])=>{const k=K(et)?et:{},Rt=bt(k,"max_hp",void 0,10),ee=bt(k,"hp",void 0,Rt),_e=bt(k,"max_mp",void 0,0),fe=bt(k,"mp",void 0,0),j=bt(k,"level",void 0,1),Pt=bt(k,"xp",void 0,0),ge=Ga(k.alive,ee>0),en=r[W],nn=typeof en=="string"?en:void 0,Jn=ic(k.role,W,nn),Vn=ac(k.generation),Yn=pt(k.joined_at,k.joinedAt,k.started_at,k.startedAt),Xn=pt(k.claimed_at,k.claimedAt,k.assigned_at,k.assignedAt,k.assigned_time),q=pt(k.last_seen,k.lastSeen,k.last_seen_at,k.lastSeenAt,k.last_active,k.lastActive),Ie=pt(k.scene,k.current_scene,k.currentScene,k.world_scene,k.scene_name,k.sceneName),ol=pt(k.location,k.current_location,k.currentLocation,k.position,k.zone,k.area);return{id:W,name:h(k.name,W),role:Jn,keeper:nn,archetype:h(k.archetype,""),persona:h(k.persona,""),portrait:h(k.portrait,"")||void 0,background:h(k.background,"")||void 0,traits:sn(k.traits),skills:sn(k.skills),stats_raw:lc(k),status:ge?"active":"dead",generation:Vn,joined_at:Yn||void 0,claimed_at:Xn||void 0,last_seen:q||void 0,scene:Ie||void 0,location:ol||void 0,inventory:sn(k.inventory),notes:sn(k.notes),relationships:oc(k.relationships),stats:{hp:ee,max_hp:Rt,mp:fe,max_mp:_e,level:j,xp:Pt,strength:bt(k,"strength","str",10),dexterity:bt(k,"dexterity","dex",10),constitution:bt(k,"constitution","con",10),intelligence:bt(k,"intelligence","int",10),wisdom:bt(k,"wisdom","wis",10),charisma:bt(k,"charisma","cha",10)}}}),u=m.filter(W=>W.status!=="dead"),p=sc(t,e),v={phase_open:Ga(c.phase_open,!0),min_points:J(c.min_points,3),window:h(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(d).map(([W,et])=>{const k=K(et)?et:{};return{actor_id:W,score:J(k.score,0),last_reason:h(k.last_reason,"")||null,reasons:sn(k.reasons)}}),x=m.reduce((W,et)=>(W[et.id]=et.name,W),{}),b=e.map(W=>mc(W,x)),A=J(a.turn,1),I=h(a.phase,"round"),z=h(a.map,""),E=K(a.world)?a.world:{},N=z||h(E.ascii_map,h(E.map,"")),R=b.filter((W,et)=>{const k=e[et];if(!K(k))return!1;const Rt=K(k.payload)?k.payload:{};return J(Rt.turn,-1)===A}),Y=(R.length>0?R:b).slice(-12),G=h(a.status,"active");return{session:{id:s,room:s,status:G==="ended"?"ended":G==="paused"?"paused":"active",round:A,actors:u,created_at:((F=b[0])==null?void 0:F.timestamp)??new Date().toISOString()},current_round:{round_number:A,phase:I,events:Y,timestamp:((tt=b[b.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:N||void 0,join_gate:v,contribution_ledger:$,outcome:p,party:u,story_log:b,history:[]}}async function _c(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await it(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function fc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([it(`/api/v1/trpg/state${e}`),_c(t)]);return vc(n,s,t)}function gc(t){return Ht("/api/v1/trpg/rounds/run",{room_id:t})}function $c(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function hc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ht("/api/v1/trpg/dice/roll",e)}function yc(t,e){const n=$c();return Ht("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function bc(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Ht("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function kc(t,e,n){return Ht("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function xc(t,e,n){const s=await pe("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Sc(t){const e=await pe("trpg.mid_join.request",t);return JSON.parse(e)}async function Ac(t,e){await pe("masc_broadcast",{agent_name:t,message:e})}async function Cc(t=40){return(await pe("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function wc(t,e=20){return pe("masc_task_history",{task_id:t,limit:e})}async function Tc(t){const e=await pe("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ic(t){return ji("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await it(`/api/v1/council/debates/${e}/summary`);if(!K(n))return null;const s=h(n.id,"").trim();return s?{id:s,topic:h(n.topic,""),status:h(n.status,"open"),support_count:J(n.support_count,0),oppose_count:J(n.oppose_count,0),neutral_count:J(n.neutral_count,0),total_arguments:J(n.total_arguments,0),created_at:un(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function Nc(t,e,n){return pe("masc_keeper_msg",{name:t,message:e})}const Rc=f(""),Yt=f({}),vt=f({}),Ja=f({}),Va=f({}),Ya=f({}),Xa=f({}),Xt=f({});function dt(t,e,n){t.value={...t.value,[e]:n}}function Zt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function X(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function It(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function De(t){return typeof t=="boolean"?t:void 0}function Qa(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Za(t){return Array.isArray(t)?t.map(e=>X(e)).filter(e=>!!e):[]}function Pc(t){var n;const e=(n=X(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Lc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ma(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!Zt(s))continue;const a=X(s.name);if(!a)continue;const i=X(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function Mc(t){if(!Zt(t))return null;const e=X(t.name);return e?{name:e,trigger:X(t.trigger),outcome:X(t.outcome),summary:X(t.summary),reason:X(t.reason)}:null}function Dc(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Ec(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function qi(t,e,n){return X(t)??Ec(e,n)}function Ki(t,e){return typeof t=="boolean"?t:e==="recover"}function xs(t){if(!Zt(t))return null;const e=X(t.health_state),n=X(t.next_action_path),s=X(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:X(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:Qa(t.last_reply_at),last_reply_preview:X(t.last_reply_preview)??null,last_error:X(t.last_error)??null,next_eligible_at_s:It(t.next_eligible_at_s)??null,recoverable:Ki(t.recoverable,n),summary:qi(t.summary,e,X(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ui(t){return Zt(t)?{hour:It(t.hour),checked:It(t.checked)??0,acted:It(t.acted)??0,acted_names:Za(t.acted_names),activity_report:X(t.activity_report),quiet_hours_overridden:De(t.quiet_hours_overridden),skipped_reason:X(t.skipped_reason),acted_rows:ma(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ma(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ma(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Mc).filter(e=>e!==null):[]}:null}function zc(t){return Zt(t)?{enabled:De(t.enabled)??!1,interval_s:It(t.interval_s)??0,quiet_start:It(t.quiet_start),quiet_end:It(t.quiet_end),quiet_active:De(t.quiet_active),use_planner:De(t.use_planner),delegate_llm:De(t.delegate_llm),agent_count:It(t.agent_count),agents:Za(t.agents),last_tick_ago_s:It(t.last_tick_ago_s)??null,last_tick_ago:X(t.last_tick_ago),total_ticks:It(t.total_ticks),total_checkins:It(t.total_checkins),last_skip_reason:X(t.last_skip_reason)??null,last_tick_result:Ui(t.last_tick_result),active_self_heartbeats:Za(t.active_self_heartbeats)}:null}function jc(t){return Zt(t)?{status:t.status,diagnostic:xs(t.diagnostic)}:null}function Oc(t){return Zt(t)?{recovered:De(t.recovered)??!1,skipped_reason:X(t.skipped_reason)??null,before:xs(t.before),after:xs(t.after),down:t.down,up:t.up}:null}function Fc(t,e){var z,E;if(!(t!=null&&t.name))return null;const n=X((z=t.agent)==null?void 0:z.status)??X(t.status)??"unknown",s=X((E=t.agent)==null?void 0:E.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,p=d&&u!=null?Math.max(0,m-u):null,v=r<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=s??(a&&!i?"keeper keepalive is not running":null),b=n==="offline"||n==="inactive"?"offline":x?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",A=x?Dc(x):e!=null&&e.quiet_active&&v!=="fresh"?"quiet_hours":a&&!i?"disabled":r<=0?"never_started":p!=null&&p>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",I=b==="offline"||b==="degraded"||b==="stale"?"recover":A==="quiet_hours"?"manual_lodge_poke":A==="unknown"?"probe":"direct_message";return{health_state:b,quiet_reason:A,next_action_path:I,last_reply_status:v,last_reply_at:$,last_reply_preview:null,last_error:x,next_eligible_at_s:p!=null&&p>0?p:null,recoverable:Ki(void 0,I),summary:qi(void 0,b,A),keepalive_running:i}}function qc(t,e){if(!Zt(t))return null;const n=Pc(t.role),s=X(t.content)??X(t.preview);if(!s)return null;const a=Qa(t.ts_unix)??Qa(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:Lc(n),text:s,timestamp:a,delivery:"history"}}function Kc(t,e,n){const s=Zt(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,r)=>qc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:xs(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Go(t,e){const n=vt.value[t]??[];vt.value={...vt.value,[t]:[...n,e].slice(-50)}}function Uc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Hc(t,e){const s=(vt.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>Uc(a,i)));vt.value={...vt.value,[t]:[...e,...s].slice(-50)}}function ea(t,e){Yt.value={...Yt.value,[t]:e},Hc(t,e.history)}function Jo(t,e){const n=Yt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};ea(t,{...n,diagnostic:{...s,...e}})}async function bo(){try{await qn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Wc(t){Rc.value=t.trim()}async function Hi(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Yt.value[n])return Yt.value[n];dt(Ja,n,!0),dt(Xt,n,null);try{const s=await pe("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Kc(n,s,a);return ea(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return dt(Xt,n,a),null}finally{dt(Ja,n,!1)}}async function Bc(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Go(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),dt(Va,n,!0),dt(Xt,n,null);try{const i=await Nc(n,s);vt.value={...vt.value,[n]:(vt.value[n]??[]).map(r=>r.id===a?{...r,delivery:"delivered"}:r)},Go(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Jo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await bo()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw vt.value={...vt.value,[n]:(vt.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:r}:c)},Jo(n,{last_reply_status:"error",last_error:r}),dt(Xt,n,r),i}finally{dt(Va,n,!1)}}async function Gc(t,e){const n=t.trim();if(!n)return null;dt(Ya,n,!0),dt(Xt,n,null);try{const s=await ta({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=jc(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const r=Yt.value[n];ea(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await bo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw dt(Xt,n,a),s}finally{dt(Ya,n,!1)}}async function Jc(t,e){const n=t.trim();if(!n)return null;dt(Xa,n,!0),dt(Xt,n,null);try{const s=await ta({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Oc(s.result),i=(a==null?void 0:a.after)??null;if(i){const r=Yt.value[n];ea(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??vt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await bo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw dt(Xt,n,a),s}finally{dt(Xa,n,!1)}}function $e(t){return(t??"").trim().toLowerCase()}function $t(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function us(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Qn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function an(t){return t.last_heartbeat??Qn(t.last_turn_ago_s)??Qn(t.last_proactive_ago_s)??Qn(t.last_handoff_ago_s)??Qn(t.last_compaction_ago_s)}function Vc(t){const e=t.title.trim();return e||us(t.content)}function Yc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Xc(t,e,n,s,a={}){var E;const i=$e(t),r=e.filter(N=>$e(N.assignee)===i&&(N.status==="claimed"||N.status==="in_progress")).length,c=n.filter(N=>$e(N.from)===i).sort((N,R)=>$t(R.timestamp)-$t(N.timestamp))[0],d=s.filter(N=>$e(N.agent)===i||$e(N.author)===i).sort((N,R)=>$t(R.timestamp)-$t(N.timestamp))[0],m=(a.boardPosts??[]).filter(N=>$e(N.author)===i).sort((N,R)=>$t(R.updated_at||R.created_at)-$t(N.updated_at||N.created_at))[0],u=(a.keepers??[]).filter(N=>$e(N.name)===i&&an(N)!==null).sort((N,R)=>$t(an(R)??0)-$t(an(N)??0))[0],p=c?$t(c.timestamp):0,v=d?$t(d.timestamp):0,$=m?$t(m.updated_at||m.created_at):0,x=u?$t(an(u)??0):0,b=a.lastSeen?$t(a.lastSeen):0,A=((E=a.currentTask)==null?void 0:E.trim())||(r>0?`${r} claimed tasks`:null);if(p===0&&v===0&&$===0&&x===0&&b===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:A};const z=[c?{timestamp:c.timestamp,ts:p,text:us(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${us(Vc(m))}`}:null,u?{timestamp:an(u),ts:x,text:Yc(u)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:v,text:us(d.text)}:null].filter(N=>N!==null).sort((N,R)=>R.ts-N.ts)[0];return z&&z.ts>=b?{activeAssignedCount:r,lastActivityAt:z.timestamp,lastActivityText:z.text}:{activeAssignedCount:r,lastActivityAt:a.lastSeen??null,lastActivityText:A??"Presence heartbeat"}}const Ct=f([]),Ot=f([]),Ge=f([]),te=f([]),xt=f(null),Qc=f(null),to=f(new Map),yn=f([]),bn=f("recent"),Ee=f(!0),Wi=f(null),Vt=f(""),kn=f([]),ze=f(!1),Bi=f(new Map),ko=f("unknown"),Ss=f(null),eo=f(!1),xn=f(!1),no=f(!1),je=f(!1),xo=f(null),As=f(!1),Cs=f(null),Gi=f(null),so=f(null),Ji=f(null),Vi=f(null),Zc=f(null);Nt(()=>Ct.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const td=Nt(()=>{const t=Ot.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),na=Nt(()=>{const t=new Map,e=Ot.value,n=Ge.value,s=ks.value,a=yn.value,i=te.value;for(const r of Ct.value)t.set(r.name.trim().toLowerCase(),Xc(r.name,e,n,s,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:a,keepers:i}));return t});function ed(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const nd=Nt(()=>{const t=new Map;for(const e of te.value)t.set(e.name,ed(e));return t}),sd=12e4;function ad(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}const od=Nt(()=>{const t=Date.now(),e=new Set,n=to.value;for(const s of te.value){const a=ad(s,n);a!=null&&t-a>sd&&e.add(s.name)}return e});let va=null;function id(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function ct(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function w(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Et(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ao(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function Yi(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function rd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function ld(t){if(!ct(t))return null;const e=y(t.name);return e?{name:e,agent_type:y(t.agent_type),status:Yi(t.status),current_task:y(t.current_task)??null,joined_at:y(t.joined_at),last_seen:y(t.last_seen),capabilities:Et(t.capabilities),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:Et(t.traits),interests:Et(t.interests),activityLevel:w(t.activityLevel)??w(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function cd(t){if(!ct(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:rd(t.status),priority:w(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function dd(t){if(!ct(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",s=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:w(t.seq),from:e,content:n,timestamp:s,type:y(t.type)}}function Vo(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function ud(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Vo(s)-Vo(a)).slice(-500)}function pd(t){return Array.isArray(t)?t.map(e=>{if(!ct(e))return null;const n=w(e.ts_unix);if(n==null)return null;const s=ct(e.handoff)?e.handoff:null;return{ts:n,context_ratio:w(e.context_ratio)??0,context_tokens:w(e.context_tokens)??0,context_max:w(e.context_max)??0,latency_ms:w(e.latency_ms)??0,generation:w(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:w(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:w(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?w(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Yo(t){if(!ct(t))return null;const e=y(t.health_state),n=y(t.next_action_path),s=y(t.last_reply_status);if(!e||!n||!s)return null;const a=y(t.quiet_reason)??null,i=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:ao(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:w(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function md(t,e){return(Array.isArray(t)?t:ct(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!ct(s))return null;const a=ct(s.agent)?s.agent:null,i=ct(s.context)?s.context:null,r=ct(s.metrics_window)?s.metrics_window:void 0,c=y(s.name);if(!c)return null;const d=w(s.context_ratio)??w(i==null?void 0:i.context_ratio),m=y(s.status)??y(a==null?void 0:a.status)??"offline",u=Yi(m),p=y(s.model)??y(s.active_model)??y(s.primary_model),v=Et(s.skill_secondary),$=i?{source:y(i.source),context_ratio:w(i.context_ratio),context_tokens:w(i.context_tokens),context_max:w(i.context_max),message_count:w(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,x=a?{name:y(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:y(a.error),agent_type:y(a.agent_type),status:y(a.status),current_task:y(a.current_task)??null,joined_at:y(a.joined_at),last_seen:y(a.last_seen),last_seen_ago_s:w(a.last_seen_ago_s),capabilities:Et(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,b=pd(s.metrics_series),A={name:c,emoji:y(s.emoji),koreanName:y(s.koreanName)??y(s.korean_name),agent_name:y(s.agent_name),trace_id:y(s.trace_id),model:p,primary_model:y(s.primary_model),active_model:y(s.active_model),next_model_hint:y(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:w(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:w(s.proactive_idle_sec),proactive_cooldown_sec:w(s.proactive_cooldown_sec),last_heartbeat:y(s.last_heartbeat)??y(a==null?void 0:a.last_seen),generation:w(s.generation),turn_count:w(s.turn_count)??w(s.total_turns),keeper_age_s:w(s.keeper_age_s),last_turn_ago_s:w(s.last_turn_ago_s),last_handoff_ago_s:w(s.last_handoff_ago_s),last_compaction_ago_s:w(s.last_compaction_ago_s),last_proactive_ago_s:w(s.last_proactive_ago_s),last_proactive_preview:y(s.last_proactive_preview)??null,context_ratio:d,context_tokens:w(s.context_tokens)??w(i==null?void 0:i.context_tokens),context_max:w(s.context_max)??w(i==null?void 0:i.context_max),context_source:y(s.context_source)??y(i==null?void 0:i.source),context:$,traits:Et(s.traits),interests:Et(s.interests),primaryValue:y(s.primaryValue)??y(s.primary_value),activityLevel:w(s.activityLevel)??w(s.activity_level),memory_recent_note:y(s.memory_recent_note)??null,recent_input_preview:y(s.recent_input_preview)??null,recent_output_preview:y(s.recent_output_preview)??null,recent_tool_names:Et(s.recent_tool_names)??[],conversation_tail_count:w(s.conversation_tail_count),k2k_count:w(s.k2k_count),handoff_count_total:w(s.handoff_count_total)??w(s.trace_history_count),compaction_count:w(s.compaction_count),last_compaction_saved_tokens:w(s.last_compaction_saved_tokens),diagnostic:Yo(s.diagnostic),skill_primary:y(s.skill_primary)??null,skill_secondary:v,skill_reason:y(s.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:r,agent:x};return A.diagnostic=Yo(s.diagnostic)??Fc(A,(e==null?void 0:e.lodge)??null),A}).filter(s=>s!==null)}function Xi(t){return ct(t)?{...t,lodge:zc(t.lodge)??void 0}:null}function vd(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function _d(t){if(!ct(t))return null;const e=w(t.iteration);if(e==null)return null;const n=w(t.metric_before)??0,s=w(t.metric_after)??n,a=ct(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:w(t.delta)??s-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:w(t.elapsed_ms)??0,cost_usd:w(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(a.worker_model)??"",tool_call_count:w(a.tool_call_count)??0,tool_names:Et(a.tool_names)??[],session_id:y(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function fd(t){var i,r;if(!ct(t))return null;const e=y(t.loop_id);if(!e)return null;const n=w(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(_d).filter(c=>c!==null):[],a=w(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:vd(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:w(t.current_iteration)??((r=s[0])==null?void 0:r.iteration)??0,max_iterations:w(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:y(t.target)??"",stagnation_streak:w(t.stagnation_streak)??0,stagnation_limit:w(t.stagnation_limit)??0,elapsed_seconds:w(t.elapsed_seconds)??0,updated_at:ao(t.updated_at)??null,stopped_at:ao(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:w(t.latest_tool_call_count)??0,latest_tool_names:Et(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function qn(){eo.value=!0;try{await Promise.all([Zi(),Bt()]),Gi.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{eo.value=!1}}async function Qi(){As.value=!0,Cs.value=null;try{const t=await jl();xo.value=t,Zc.value=new Date().toISOString()}catch(t){Cs.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{As.value=!1}}function gd(t){var e;return((e=xo.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function $d(t){var n;const e=((n=xo.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(i=>i.id===t);if(a)return a}return null}function hd(t){var s,a;kn.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!ct(i))return null;const r=y(i.id),c=y(i.title),d=y(i.horizon),m=y(i.status),u=y(i.created_at),p=y(i.updated_at);return!r||!c||!d||!m||!u||!p?null:{id:r,horizon:d,title:c,metric:y(i.metric)??null,target_value:y(i.target_value)??null,due_date:y(i.due_date)??null,priority:w(i.priority)??3,status:m,parent_goal_id:y(i.parent_goal_id)??null,last_review_note:y(i.last_review_note)??null,last_review_at:y(i.last_review_at)??null,created_at:u,updated_at:p}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const i of n){const r=fd(i);r&&e.set(r.loop_id,r)}Bi.value=e,Ss.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,ko.value=Ss.value?"error":e.size===0?"idle":"ready"}async function Zi(){try{const t=await Ml(),e=Xi(t.status);e&&(xt.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Bt(){var t;try{const e=await Dl(),n=Xi(e.status),s=(t=xt.value)==null?void 0:t.room;n&&(xt.value=n);const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ct.value=(Array.isArray(e.agents)?e.agents:[]).map(ld).filter(r=>r!==null),Ot.value=(Array.isArray(e.tasks)?e.tasks:[]).map(cd).filter(r=>r!==null);const i=(Array.isArray(e.messages)?e.messages:[]).map(dd).filter(r=>r!==null);Ge.value=a?i:ud(Ge.value,i),te.value=md(e.keepers,n??xt.value),Qc.value=null,Gi.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function Ft(){xn.value=!0;try{const t=await El(bn.value,{excludeSystem:Ee.value});yn.value=t.posts??[],so.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{xn.value=!1}}async function qt(){var t;no.value=!0;try{const e=Vt.value||((t=xt.value)==null?void 0:t.room)||"default";Vt.value||(Vt.value=e);const n=await fc(e);Wi.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{no.value=!1}}async function Je(){ze.value=!0,je.value=!0;try{const t=await Fl();hd(t),Ji.value=new Date().toISOString(),Vi.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),ko.value="error",Ss.value=t instanceof Error?t.message:String(t)}finally{ze.value=!1,je.value=!1}}async function oo(){return Je()}let ps=null;function yd(t){ps=t}let ms=null;function bd(t){ms=t}let vs=null;function kd(t){vs=t}const be={};function he(t,e,n=500){be[t]&&clearTimeout(be[t]),be[t]=setTimeout(()=>{e(),delete be[t]},n)}function xd(){const t=Pi.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(to.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),to.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&he("execution",Bt),id(e.type)&&(va||(va=setTimeout(()=>{qn(),ms==null||ms(),vs==null||vs(),va=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&he("execution",Bt),e.type==="broadcast"&&he("execution",Bt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&he("execution",Bt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&he("board",Ft),e.type.startsWith("decision_")&&he("council",()=>ps==null?void 0:ps()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&he("mdal",oo,350)}});return()=>{t();for(const e of Object.keys(be))clearTimeout(be[e]),delete be[e]}}let pn=null;function Sd(){pn||(pn=setInterval(()=>{de.value,qn()},1e4))}function Ad(){pn&&(clearInterval(pn),pn=null)}function Cd({metric:t}){return o`
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
  `}function wd({panel:t}){return o`
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
            ${t.metrics.map(e=>o`<${Cd} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function D({panelId:t,compact:e=!1,label:n="Why"}){const s=$d(t);return s?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${wd} panel=${s} />
    </details>
  `:As.value?o`<span class="semantic-inline-state">Loading semantics…</span>`:null}function St({surfaceId:t,compact:e=!1}){const n=gd(t);return n?o`
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
            ${n.panels.map(s=>o`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:As.value?o`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:Cs.value?o`<div class="semantic-surface-card ${e?"compact":""}">${Cs.value}</div>`:null}function T({title:t,class:e,semanticId:n,children:s}){return o`
    <div class="card ${e??""}">
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${D} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${s}
    </div>
  `}const sa=f(null),io=f(!1),ws=f(null);function U(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function B(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function So(t){return typeof t=="boolean"?t:void 0}function Gt(t,e=[]){if(Array.isArray(t))return t;if(!U(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function aa(t){if(!U(t))return null;const e=P(t.kind),n=P(t.summary),s=P(t.target_type);return!e||!n||!s?null:{kind:e,severity:P(t.severity)??"warn",summary:n,target_type:s,target_id:P(t.target_id)??null,actor:P(t.actor)??null,evidence:t.evidence}}function oa(t){if(!U(t))return null;const e=P(t.action_type),n=P(t.target_type),s=P(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:P(t.target_id)??null,severity:P(t.severity)??"warn",reason:s,confirm_required:So(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Td(t){if(!U(t))return null;const e=P(t.session_id);return e?{session_id:e,goal:P(t.goal),status:P(t.status),health:P(t.health),scale_profile:P(t.scale_profile),control_profile:P(t.control_profile),planned_worker_count:B(t.planned_worker_count),active_agent_count:B(t.active_agent_count),last_turn_age_sec:B(t.last_turn_age_sec)??null,attention_count:B(t.attention_count),recommended_action_count:B(t.recommended_action_count),top_attention:aa(t.top_attention),top_recommendation:oa(t.top_recommendation)}:null}function Id(t){if(!U(t))return null;const e=P(t.session_id);if(!e)return null;const n=U(t.status)?t.status:t,s=U(n.summary)?n.summary:void 0;return{session_id:e,status:P(t.status)??P(s==null?void 0:s.status)??(U(n.session)?P(n.session.status):void 0),progress_pct:B(t.progress_pct)??B(s==null?void 0:s.progress_pct),elapsed_sec:B(t.elapsed_sec)??B(s==null?void 0:s.elapsed_sec),remaining_sec:B(t.remaining_sec)??B(s==null?void 0:s.remaining_sec),done_delta_total:B(t.done_delta_total)??B(s==null?void 0:s.done_delta_total),summary:U(t.summary)?t.summary:s,team_health:U(t.team_health)?t.team_health:U(n.team_health)?n.team_health:void 0,communication_metrics:U(t.communication_metrics)?t.communication_metrics:U(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:U(t.orchestration_state)?t.orchestration_state:U(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:U(t.cascade_metrics)?t.cascade_metrics:U(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:U(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,i])=>{const r=P(i);return r?[a,r]:null}).filter(a=>a!==null)):U(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const r=P(i);return r?[a,r]:null}).filter(a=>a!==null)):void 0,session:U(t.session)?t.session:U(n.session)?n.session:void 0,recent_events:Gt(t.recent_events,["events"]).filter(U)}}function Nd(t){if(!U(t))return null;const e=P(t.name);return e?{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:B(t.context_ratio),generation:B(t.generation),active_goal_ids:Gt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:B(t.last_turn_ago_s),model:P(t.model)}:null}function Rd(t){if(!U(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function Pd(t){if(!U(t))return null;const e=P(t.action_type),n=P(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:P(t.description),confirm_required:So(t.confirm_required)}}function Ld(t){const e=U(t)?t:{};return{room_health:P(e.room_health),cluster:P(e.cluster),project:P(e.project),current_room:P(e.current_room)??null,paused:So(e.paused),tempo_interval_s:B(e.tempo_interval_s),active_agents:B(e.active_agents),keeper_pressure:B(e.keeper_pressure),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),incident_count:B(e.incident_count),recommended_action_count:B(e.recommended_action_count),top_attention:aa(e.top_attention),top_action:oa(e.top_action)}}function Md(t){const e=U(t)?t:{},n=U(e.swarm_overview)?e.swarm_overview:{};return{health:P(e.health),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),swarm_overview:{active_lanes:B(n.active_lanes),moving_lanes:B(n.moving_lanes),stalled_lanes:B(n.stalled_lanes),projected_lanes:B(n.projected_lanes),last_movement_at:P(n.last_movement_at)??null},top_attention:aa(e.top_attention),top_action:oa(e.top_action),session_cards:Gt(e.session_cards).map(Td).filter(s=>s!==null)}}function Dd(t){const e=U(t)?t:{};return{sessions:Gt(e.sessions,["items"]).map(Id).filter(n=>n!==null),keepers:Gt(e.keepers,["items"]).map(Nd).filter(n=>n!==null),pending_confirms:Gt(e.pending_confirms).map(Rd).filter(n=>n!==null),available_actions:Gt(e.available_actions).map(Pd).filter(n=>n!==null)}}function Ed(t){const e=U(t)?t:{};return{generated_at:P(e.generated_at),summary:Ld(e.summary),incidents:Gt(e.incidents).map(aa).filter(n=>n!==null),recommended_actions:Gt(e.recommended_actions).map(oa).filter(n=>n!==null),command_focus:Md(e.command_focus),operator_targets:Dd(e.operator_targets)}}async function _s(){io.value=!0,ws.value=null;try{const t=await Ol();sa.value=Ed(t)}catch(t){ws.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{io.value=!1}}function me({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function tr(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function ot({timestamp:t}){const e=tr(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}let zd=0;const ke=f([]);function L(t,e="success",n=4e3){const s=++zd;ke.value=[...ke.value,{id:s,message:t,type:e}],setTimeout(()=>{ke.value=ke.value.filter(a=>a.id!==s)},n)}function jd(t){ke.value=ke.value.filter(e=>e.id!==t)}function Od(){const t=ke.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>jd(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Fd="masc_dashboard_agent_name",Ze=f(null),Ts=f(!1),Sn=f(""),Is=f([]),An=f([]),Ke=f(""),mn=f(!1);function ia(t){Ze.value=t,Ao()}function Xo(){Ze.value=null,Sn.value="",Is.value=[],An.value=[],Ke.value=""}function qd(){const t=Ze.value;return t?Ct.value.find(e=>e.name===t)??null:null}function er(t){return t?Ot.value.filter(e=>e.assignee===t):[]}function nr(t){return t?te.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Kd(t){const e=nr(t);if(!e)return[];if(e.recent_tool_names&&e.recent_tool_names.length>0)return e.recent_tool_names;const n=e.metrics_window;return(Array.isArray(n==null?void 0:n.top_tools)?n.top_tools:[]).map(a=>typeof a=="object"&&a!==null&&"tool"in a&&typeof a.tool=="string"?a.tool:null).filter(a=>a!==null)}async function Ao(){const t=Ze.value;if(t){Ts.value=!0,Sn.value="",Is.value=[],An.value=[];try{const e=await Cc(80);Is.value=e.filter(a=>a.includes(t)).slice(0,20);const n=er(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await wc(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));An.value=s}catch(e){Sn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ts.value=!1}}}async function Qo(){var s;const t=Ze.value,e=Ke.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Fd))==null?void 0:s.trim())||"dashboard";mn.value=!0;try{await Ac(n,`@${t} ${e}`),Ke.value="",L(`Mention sent to ${t}`,"success"),Ao()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";L(i,"error")}finally{mn.value=!1}}function Ud({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${me} status=${t.status} />
    </div>
  `}function Hd({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Wd(){var m,u,p,v,$,x,b;const t=Ze.value;if(!t)return null;const e=qd(),n=nr(t),s=er(t),a=Is.value,i=Kd(t),r=(e==null?void 0:e.capabilities)??[],c=((m=xt.value)==null?void 0:m.room)??((u=xt.value)==null?void 0:u.project)??"default",d=((p=xt.value)==null?void 0:p.cluster)??"확인 없음";return o`
    <div
      class="agent-detail-overlay"
      onClick=${A=>{A.target.classList.contains("agent-detail-overlay")&&Xo()}}
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
                        <${me} status=${e.status} />
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
            ${(((v=e==null?void 0:e.traits)==null?void 0:v.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${($=e==null?void 0:e.traits)==null?void 0:$.map(A=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            ${(((x=e==null?void 0:e.interests)==null?void 0:x.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(b=e==null?void 0:e.interests)==null?void 0:b.map(A=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            ${r.length>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${r.map(A=>o`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${A}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${ot} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${c}</span>
                    <span>Cluster: ${d}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Ao()}} disabled=${Ts.value}>
              ${Ts.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Xo}>Close</button>
          </div>
        </div>

        ${Sn.value?o`<div class="council-error">${Sn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${s.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${s.map(A=>o`<${Ud} key=${A.id} task=${A} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((A,I)=>o`<div key=${I} class="agent-activity-line">${A}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Capabilities & Tools">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${r.length>0?r.map(A=>o`<span class="pill">${A}</span>`):o`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${i.length>0?i.map(A=>o`<span class="pill">${A}</span>`):o`<span class="empty-state" style="font-size:12px;">No tool telemetry</span>`}
              </div>
            </div>
            ${n?o`
                  <div style="font-size:12px; color:#888;">
                    Linked keeper: <span style="color:#4ade80;">${n.name}</span>
                    ${n.skill_primary?o` · route <span style="color:#22d3ee;">${n.skill_primary}</span>`:null}
                  </div>
                `:null}
          </div>
        <//>

        <${T} title="Task History">
          ${An.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${An.value.map(A=>o`<${Hd} key=${A.taskId} row=${A} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ke.value}
              onInput=${A=>{Ke.value=A.target.value}}
              onKeyDown=${A=>{A.key==="Enter"&&Qo()}}
              disabled=${mn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Qo()}}
              disabled=${mn.value||Ke.value.trim()===""}
            >
              ${mn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Kt=f(null),sr=f(null),Ut=f(null),Cn=f(!1),ue=f(null),wn=f(!1),Ve=f(null),Q=f(!1),Ns=f([]);let Bd=1;function H(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function S(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function at(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ra(t){return typeof t=="boolean"?t:void 0}function Gd(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function zt(t,e=[]){if(Array.isArray(t))return t;if(!H(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Jd(t){return H(t)?{id:S(t.id),seq:at(t.seq),from:S(t.from)??S(t.from_agent)??"system",content:S(t.content)??"",timestamp:S(t.timestamp)??new Date().toISOString(),type:S(t.type)}:null}function Vd(t){return H(t)?{room_id:S(t.room_id),current_room:S(t.current_room)??S(t.room),project:S(t.project),cluster:S(t.cluster),paused:ra(t.paused),pause_reason:S(t.pause_reason)??null,paused_by:S(t.paused_by)??null,paused_at:S(t.paused_at)??null}:{}}function Zo(t){if(!H(t))return;const e=Object.entries(t).map(([n,s])=>{const a=S(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function ar(t){if(!H(t))return null;const e=S(t.kind),n=S(t.summary),s=S(t.target_type);return!e||!n||!s?null:{kind:e,severity:S(t.severity)??"warn",summary:n,target_type:s,target_id:S(t.target_id)??null,actor:S(t.actor)??null,evidence:t.evidence}}function or(t){if(!H(t))return null;const e=S(t.action_type),n=S(t.target_type),s=S(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:S(t.target_id)??null,severity:S(t.severity)??"warn",reason:s,confirm_required:ra(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Yd(t){return H(t)?{actor:S(t.actor)??null,spawn_agent:S(t.spawn_agent)??null,spawn_role:S(t.spawn_role)??null,spawn_model:S(t.spawn_model)??null,worker_class:S(t.worker_class)??null,parent_actor:S(t.parent_actor)??null,capsule_mode:S(t.capsule_mode)??null,runtime_pool:S(t.runtime_pool)??null,lane_id:S(t.lane_id)??null,controller_level:S(t.controller_level)??null,control_domain:S(t.control_domain)??null,supervisor_actor:S(t.supervisor_actor)??null,model_tier:S(t.model_tier)??null,task_profile:S(t.task_profile)??null,risk_level:S(t.risk_level)??null,routing_confidence:at(t.routing_confidence)??null,routing_reason:S(t.routing_reason)??null,status:S(t.status)??"unknown",turn_count:at(t.turn_count)??0,empty_note_turn_count:at(t.empty_note_turn_count)??0,has_turn:ra(t.has_turn)??!1,last_turn_ts_iso:S(t.last_turn_ts_iso)??null}:null}function Xd(t){if(!H(t))return null;const e=S(t.session_id);return e?{session_id:e,goal:S(t.goal),status:S(t.status),health:S(t.health),scale_profile:S(t.scale_profile),control_profile:S(t.control_profile),planned_worker_count:at(t.planned_worker_count),active_agent_count:at(t.active_agent_count),last_turn_age_sec:at(t.last_turn_age_sec)??null,attention_count:at(t.attention_count),recommended_action_count:at(t.recommended_action_count),top_attention:ar(t.top_attention),top_recommendation:or(t.top_recommendation)}:null}function ir(t){const e=H(t)?t:{};return{trace_id:S(e.trace_id),target_type:S(e.target_type)??"room",target_id:S(e.target_id)??null,health:S(e.health),swarm_status:H(e.swarm_status)?e.swarm_status:void 0,attention_items:zt(e.attention_items).map(ar).filter(n=>n!==null),recommended_actions:zt(e.recommended_actions).map(or).filter(n=>n!==null),session_cards:zt(e.session_cards).map(Xd).filter(n=>n!==null),worker_cards:zt(e.worker_cards).map(Yd).filter(n=>n!==null)}}function Qd(t){if(!H(t))return null;const e=H(t.status)?t.status:void 0,n=H(t.summary)?t.summary:H(e==null?void 0:e.summary)?e.summary:void 0,s=H(t.session)?t.session:H(e==null?void 0:e.session)?e.session:void 0,a=S(t.session_id)??S(n==null?void 0:n.session_id)??S(s==null?void 0:s.session_id);if(!a)return null;const i=Zo(t.report_paths)??Zo(e==null?void 0:e.report_paths),r=zt(t.recent_events,["events"]).filter(H);return{session_id:a,status:S(t.status)??S(n==null?void 0:n.status)??S(s==null?void 0:s.status),progress_pct:at(t.progress_pct)??at(n==null?void 0:n.progress_pct),elapsed_sec:at(t.elapsed_sec)??at(n==null?void 0:n.elapsed_sec),remaining_sec:at(t.remaining_sec)??at(n==null?void 0:n.remaining_sec),done_delta_total:at(t.done_delta_total)??at(n==null?void 0:n.done_delta_total),summary:n,team_health:H(t.team_health)?t.team_health:H(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:H(t.communication_metrics)?t.communication_metrics:H(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:H(t.orchestration_state)?t.orchestration_state:H(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:H(t.cascade_metrics)?t.cascade_metrics:H(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:s,recent_events:r}}function Zd(t){if(!H(t))return null;const e=S(t.name);if(!e)return null;const n=H(t.context)?t.context:void 0;return{name:e,agent_name:S(t.agent_name),status:S(t.status),autonomy_level:S(t.autonomy_level),context_ratio:at(t.context_ratio)??at(n==null?void 0:n.context_ratio),generation:at(t.generation),active_goal_ids:Gd(t.active_goal_ids),last_autonomous_action_at:S(t.last_autonomous_action_at)??null,last_turn_ago_s:at(t.last_turn_ago_s),model:S(t.model)??S(t.active_model)??S(t.primary_model)}}function tu(t){if(!H(t))return null;const e=S(t.confirm_token)??S(t.token);return e?{confirm_token:e,actor:S(t.actor),action_type:S(t.action_type),target_type:S(t.target_type),target_id:S(t.target_id)??null,delegated_tool:S(t.delegated_tool),created_at:S(t.created_at),preview:t.preview}:null}function eu(t){const e=H(t)?t:{};return{room:Vd(e.room),sessions:zt(e.sessions,["items","sessions"]).map(Qd).filter(n=>n!==null),keepers:zt(e.keepers,["items","keepers"]).map(Zd).filter(n=>n!==null),recent_messages:zt(e.recent_messages,["messages"]).map(Jd).filter(n=>n!==null),pending_confirms:zt(e.pending_confirms,["items","confirms"]).map(tu).filter(n=>n!==null),available_actions:zt(e.available_actions,["actions"]).filter(H).map(n=>({action_type:S(n.action_type)??"unknown",target_type:S(n.target_type)??"unknown",description:S(n.description),confirm_required:ra(n.confirm_required)}))}}function Zn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ti(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Rs(t){Ns.value=[{...t,id:Bd++,at:new Date().toISOString()},...Ns.value].slice(0,20)}function rr(t){return t.confirm_required?Zn(t.preview)||"Confirmation required":Zn(t.result)||Zn(t.executed_action)||Zn(t.delegated_tool_result)||t.status}async function ut(){Cn.value=!0,ue.value=null;try{const t=await ql();Kt.value=eu(t)}catch(t){ue.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Cn.value=!1}}async function Qt(){wn.value=!0,Ve.value=null;try{const t=await Oi({targetType:"room"});sr.value=ir(t)}catch(t){Ve.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{wn.value=!1}}async function Ye(t){if(!t){Ut.value=null;return}wn.value=!0,Ve.value=null;try{const e=await Oi({targetType:"team_session",targetId:t,includeWorkers:!0});Ut.value=ir(e)}catch(e){Ve.value=e instanceof Error?e.message:"Failed to load session digest"}finally{wn.value=!1}}async function nu(t){var e;Q.value=!0,ue.value=null;try{const n=await ta(t);return Rs({actor:t.actor,action_type:t.action_type,target_label:ti(t),outcome:n.confirm_required?"preview":"executed",message:rr(n),delegated_tool:n.delegated_tool}),await ut(),await Qt(),(e=Ut.value)!=null&&e.target_id&&await Ye(Ut.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw ue.value=s,Rs({actor:t.actor,action_type:t.action_type,target_label:ti(t),outcome:"error",message:s}),n}finally{Q.value=!1}}async function su(t,e){var n;Q.value=!0,ue.value=null;try{const s=await Yl(t,e);return Rs({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:rr(s),delegated_tool:s.delegated_tool}),await ut(),await Qt(),(n=Ut.value)!=null&&n.target_id&&await Ye(Ut.value.target_id),s}catch(s){const a=s instanceof Error?s.message:"Operator confirmation failed";throw ue.value=a,Rs({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),s}finally{Q.value=!1}}kd(()=>{var t;ut(),Qt(),(t=Ut.value)!=null&&t.target_id&&Ye(Ut.value.target_id)});function au(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function ou(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function iu(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function ei(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function lr(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function ru(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function cr(t){if(!t)return null;const e=Yt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function lu({keeper:t,showRawStatus:e=!1}){if(rt(()=>{t!=null&&t.name&&Hi(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Yt.value[t.name],s=cr(t),a=Ja.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${au(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${ou((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${lr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${ru(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function cu({keeperName:t,placeholder:e}){const[n,s]=Ti("");rt(()=>{t&&Hi(t)},[t]);const a=vt.value[t]??[],i=Va.value[t]??!1,r=Xt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await Bc(t,d)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${t}`;L(u,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${ei(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${ei(d)}`}>${iu(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${lr(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?o`<div class="keeper-conversation-error">${d.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${d=>{s(d.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{c()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function du({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=cr(e),a=Ya.value[e.name]??!1,i=Xa.value[e.name]??!1,r=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??r==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Gc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to probe ${e.name}`;L(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Jc(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to recover ${e.name}`;L(m,"error")})}}
        disabled=${i||!c||!t.trim()}
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
  `}const Co=f(null);function wo(t){Co.value=t,Wc(t.name)}function ni(){Co.value=null}const Le=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function uu(t){if(!t)return 0;const e=Le.findIndex(n=>n.level===t);return e>=0?e:0}function pu({keeper:t}){const e=uu(t.autonomy_level),n=Le[e]??Le[0];if(!n)return null;const s=(e+1)/Le.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Le.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Le.map((a,i)=>o`
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
            <strong><${ot} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function fs(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function mu(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function vu(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function _u({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${fs(t.context_tokens)}</div>
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
  `}function fu({keeper:t}){var u,p;const e=t.metrics_series??[];if(e.length<2){const v=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,$=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((v,$)=>{const x=a+$/(i-1)*(n-2*a),b=s-a-(v.context_ratio??0)*(s-2*a);return{x,y:b,p:v}}),c=r.map(({x:v,y:$})=>`${v.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((p=e[e.length-1])==null?void 0:p.context_ratio)??0)*100,m=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${r.filter(({p:v})=>v.is_compaction).map(({x:v,y:$})=>o`
          <circle cx="${v.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const _a=f("");function gu({keeper:t}){var a,i,r,c;const e=_a.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${_a.value}
        onInput=${d=>{_a.value=d.target.value}}
      />
      ${s.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${fs(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${fs(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${fs(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function $u({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function hu({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function yu({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function si({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function fa(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function bu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:fa(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:fa(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:fa(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function ku({keeper:t}){var d,m,u,p,v,$,x;const e=((d=Kt.value)==null?void 0:d.room)??{},n=(((m=Kt.value)==null?void 0:m.available_actions)??[]).filter(b=>b.target_type==="keeper"||b.target_type==="room").slice(0,8),s=vu(t),a=((u=t.agent)==null?void 0:u.capabilities)??[],i=e.current_room??e.room_id??((p=xt.value)==null?void 0:p.room)??"default",r=e.project??((v=xt.value)==null?void 0:v.project)??"확인 없음",c=e.cluster??(($=xt.value)==null?void 0:$.cluster)??"확인 없음";return o`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${i}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${r}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${c}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((x=t.agent)==null?void 0:x.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${t.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(b=>o`<span class="pill">${b}</span>`):o`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${a.length>0?a.map(b=>o`<span class="pill">${b}</span>`):o`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(b=>o`<span class="pill">${mu(b.action_type)}</span>`):o`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function dr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function xu(){try{const t=await ta({actor:dr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Ui(t.result);await qn(),e!=null&&e.skipped_reason?L(e.skipped_reason,"warning"):L(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";L(e,"error")}}function Su({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${lu} keeper=${t} />
          <${du}
            actor=${dr()}
            keeper=${t}
            onPokeLodge=${()=>{xu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${cu}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Au(){var e,n,s;const t=Co.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&ni()}}
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
            <${me} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>ni()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${_u} keeper=${t} />

        ${""}
        <${fu} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${gu} keeper=${t} />
          <//>

          ${""}
          <${T} title="Profile">
            <${si} traits=${t.traits??[]} label="Traits" />
            <${si} traits=${t.interests??[]} label="Interests" />
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
                <${pu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${$u} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${T} title="Equipment (${t.inventory.length})">
                <${hu} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(t.relationships).length})">
                <${yu} rels=${t.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${bu} keeper=${t} />
          <//>

          <${T} title="Neighborhood & Tools">
            <${ku} keeper=${t} />
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
        <${Su} keeper=${t} />
      </div>
    </div>
  `:null}const Ps="masc_dashboard_workflow_context",Cu=900*1e3;function To(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function Tt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function ne(t){const e=Tt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function ur(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function ro(t){return To(t)?t:null}function wu(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Tu(t){if(!t)return null;try{const e=JSON.parse(t);if(!To(e))return null;const n=Tt(e.id),s=Tt(e.source_surface),a=Tt(e.source_label),i=Tt(e.summary),r=Tt(e.created_at);return!n||s!=="mission"||!a||!i||!r?null:{id:n,source_surface:"mission",source_label:a,action_type:Tt(e.action_type),target_type:Tt(e.target_type),target_id:Tt(e.target_id),focus_kind:Tt(e.focus_kind),summary:i,payload_preview:Tt(e.payload_preview),suggested_payload:ro(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:r}}catch{return null}}function Io(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Cu}function Iu(){const t=ur(),e=Tu((t==null?void 0:t.getItem(Ps))??null);return e?Io(e)?e:(t==null||t.removeItem(Ps),null):null}const pr=f(Iu());function Nu(t){const e=t&&Io(t)?t:null;pr.value=e;const n=ur();if(!n)return;if(!e){n.removeItem(Ps);return}const s=wu(e);s&&n.setItem(Ps,s)}function mr(t){if(!t)return null;const e=ro(t.suggested_payload);if(e)return e;if(To(t.preview)){const n=ro(t.preview.payload);if(n)return n}return null}function vr(t){if(!t)return null;const e=ne(t.message);if(e)return e;const n=ne(t.task_title)??ne(t.title),s=ne(t.task_description)??ne(t.description),a=ne(t.reason),i=ne(t.priority)??ne(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function _r(t,e,n,s,a,i){return["mission",t,e??"action",n??"target",s??"room",a??"focus",i].join(":")}function tn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=mr(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,r=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:_r(n,(t==null?void 0:t.action_type)??null,i,r,c,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:r,focus_kind:c,summary:d,payload_preview:vr(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Ru(t,e){return e.source==="mission"&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)}function Kn(t){const{params:e}=t;if(e.source!=="mission")return null;const n=pr.value;if(n&&Io(n)&&Ru(n,e))return n;const s=new Date().toISOString();return{id:_r("상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,s),source_surface:"mission",source_label:"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,summary:e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Pu(t){return{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function fr(t){const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.target_type==="room"?"summary":"swarm"}function Lu(t){return{source:"mission",surface:fr(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function No(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Ro(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Mu(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}function yt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function mt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Tn(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function ga(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function nt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function At(t){return t==="bad"||t==="offline"||t==="critical"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"?"warn":"ok"}function Ce(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function Du(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:t<86400?`${Math.round(t/3600)}h`:`${Math.round(t/86400)}d`}function ai(t){const e=Tn(t.ts);if(e!=null)return e;const n=mt(t.ts_iso);if(!n)return 0;const s=Date.parse(n);return Number.isNaN(s)?0:s}function Eu(t){return[...new Set(t.filter(Boolean))]}function zu(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function ju(t){return vr(mr(t))}function Ou(t){return No(t?tn(t,null,"상황판 추천 액션"):null)}function la(t,e=tn()){Nu(e),gt(t,t==="intervene"?Pu(e):Lu(e))}function Fu(t){la("intervene",tn(null,t,"상황판 incident"))}function qu(t){la("command",tn(null,t,"상황판 incident"))}function Ku(t,e,n="상황판 추천 액션"){la("intervene",tn(t,e,n))}function Uu(t,e,n="상황판 추천 액션"){la("command",tn(t,e,n))}function oi(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),gt(t,n)}function gr(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Hu(t,e){const n=t.trim().toLowerCase();return[...e].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const i=(s.content??"").trim().toLowerCase();return i.includes(`@${n}`)||i.includes(n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function Wu(t){const e=yt(t.session)?t.session:{},n=yt(t.summary)?t.summary:{};return Eu([...ga(e.agent_names),...ga(n.active_agents),...ga(n.planned_participants)])}function Bu(t){const e=yt(t.session)?t.session:{};return mt(e.goal)??mt(e.session_id)??t.session_id}function Gu(t){const e=yt(t.session)?t.session:{};return mt(e.room_id)}function Ju(t){const e=yt(t.session)?t.session:{};return mt(e.created_at_iso)}function Vu(t){const e=yt(t.session)?t.session:{};return mt(e.updated_at_iso)}function Yu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return mt(e.mode)}function Xu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return Tn(e.broadcast_count)??0}function Qu(t){const e=yt(t.communication_metrics)?t.communication_metrics:{};return Tn(e.portal_count)??0}function Zu(t){const e=yt(t.team_health)?t.team_health:{};return{active:Tn(e.active_agents_count)??0,required:Tn(e.required_agents)??0}}function tp(t){const n=[...t.recent_events??[]].sort((u,p)=>ai(p)-ai(u))[0];if(!n)return{at:null,summary:"최근 session event가 없습니다."};const s=yt(n.detail)?n.detail:{},a=mt(n.event_type)??"event",i=mt(s.actor),r=mt(s.task_title)??mt(s.title),c=nt(mt(s.result),120),d=nt(mt(s.reason),120),m=r?`${i?`${i} · `:""}${r}`:c??d??a.replace(/_/g," ");return{at:mt(n.ts_iso),summary:m}}function ep(){const t=sa.value;return t?t.operator_targets.sessions.map(e=>{var i,r;const n=Zu(e),s=tp(e),a=t.command_focus.session_cards.find(c=>c.session_id===e.session_id);return{session:e,goal:Bu(e),room:Gu(e),status:e.status??"unknown",memberNames:Wu(e),startedAt:Ju(e),stoppedAt:Vu(e),elapsedSec:e.elapsed_sec??null,lastEventAt:s.at,lastEventSummary:s.summary,communicationMode:Yu(e),broadcastCount:Xu(e),portalCount:Qu(e),activeCount:n.active,requiredCount:n.required,attentionSummary:((i=a==null?void 0:a.top_attention)==null?void 0:i.summary)??((r=a==null?void 0:a.top_recommendation)==null?void 0:r.reason)??null}}).sort((e,n)=>{const s=Date.parse(e.lastEventAt??e.startedAt??"")||0;return(Date.parse(n.lastEventAt??n.startedAt??"")||0)-s}):[]}function $r(t){if(t.recent_tool_names&&t.recent_tool_names.length>0)return t.recent_tool_names;const e=yt(t.metrics_window)?t.metrics_window:{};return(Array.isArray(e.top_tools)?e.top_tools:[]).map(s=>yt(s)?mt(s.tool):null).filter(s=>s!==null)}function np(t){return te.value.find(e=>e.agent_name===t||e.name===t)??null}function hr(t,e){const n=nt(t.current_task,100);if(!n)return"명시된 current task 없음";const s=e.find(i=>i.id===n);if(s)return`${s.id} · ${nt(s.title,92)}`;const a=e.find(i=>i.title===n);return a?`${a.id} · ${nt(a.title,92)}`:n}function sp(t){const e=new Map;for(const n of t)for(const s of n.memberNames)e.has(s)||e.set(s,n);return[...Ct.value].map(n=>{var v,$;const s=e.get(n.name),a=np(n.name),i=gr(n.name,Ge.value),r=Hu(n.name,Ge.value),c=na.value.get(n.name.trim().toLowerCase()),d=s?s.memberNames.filter(x=>x!==n.name):[],m=s?`${s.goal}${s.room?` · ${s.room}`:""}`:((v=sa.value)==null?void 0:v.summary.current_room)??"room",u=(a==null?void 0:a.skill_primary)??(n.capabilities&&n.capabilities.length>0?n.capabilities.slice(0,3).join(", "):null)??n.agent_type??null,p=hr(n,Ot.value);return{agent:n,where:m,withWhom:d,activeSince:(s==null?void 0:s.startedAt)??n.joined_at??n.last_seen??null,currentWork:p,how:u,recentInput:nt(r==null?void 0:r.content,120)??nt(a==null?void 0:a.recent_input_preview,120)??null,recentOutput:nt(i==null?void 0:i.content,120)??nt(a==null?void 0:a.recent_output_preview,120)??nt(($=a==null?void 0:a.diagnostic)==null?void 0:$.last_reply_preview,120)??null,recentEvent:nt(c==null?void 0:c.lastActivityText,120)??(s==null?void 0:s.lastEventSummary)??null,recentTools:a?$r(a):[]}}).sort((n,s)=>{const a=d=>d==="busy"?4:d==="active"?3:d==="listening"?2:d==="idle"?1:0,i=a(s.agent.status)-a(n.agent.status);if(i!==0)return i;const r=Date.parse(n.agent.last_seen??n.activeSince??"")||0;return(Date.parse(s.agent.last_seen??s.activeSince??"")||0)-r})}function ap(){return[...te.value].map(t=>{var e,n,s,a;return{keeper:t,activeSince:((e=t.agent)==null?void 0:e.joined_at)??t.created_at??t.last_heartbeat??null,currentWork:nt((n=t.agent)==null?void 0:n.current_task,110)??nt(t.skill_primary,110)??nt(t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:nt(t.recent_input_preview,120)??null,recentOutput:nt(t.recent_output_preview,120)??nt((s=t.diagnostic)==null?void 0:s.last_reply_preview,120)??nt(t.last_proactive_preview,120)??null,recentEvent:nt(t.last_proactive_reason,120)??nt((a=t.diagnostic)==null?void 0:a.summary,120)??null,recentTools:$r(t)}}).sort((t,e)=>{const n=Date.parse(t.keeper.last_heartbeat??t.activeSince??"")||0;return(Date.parse(e.keeper.last_heartbeat??e.activeSince??"")||0)-n})}function op({cluster:t,project:e,room:n,generatedAt:s}){return o`
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
        <strong>${s?Ce(s):"fresh"}</strong>
      </div>
    </div>
  `}function Re({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${At(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function ip({row:t}){const e=t.memberNames.slice(0,4).map(n=>{const s=Ct.value.find(i=>i.name===n),a=gr(n,Ge.value);return{name:n,currentTask:s?hr(s,Ot.value):"agent snapshot 없음",output:nt(a==null?void 0:a.content,96)}});return o`
    <article class="mission-crew-card ${At(t.status)}">
      <div class="mission-card-head">
        <div>
          <strong>${t.goal}</strong>
          <div class="mission-card-target">${t.session.session_id}${t.room?` · ${t.room}`:""}</div>
        </div>
        <span class="command-chip ${At(t.status)}">${t.status}</span>
      </div>

      <div class="mission-fact-grid">
        <div class="mission-fact-tile">
          <span>멤버</span>
          <strong>${t.memberNames.length}</strong>
          <small>${t.memberNames.slice(0,3).join(", ")||"n/a"}</small>
        </div>
        <div class="mission-fact-tile">
          <span>가동 시간</span>
          <strong>${Du(t.elapsedSec)}</strong>
          <small>${t.startedAt?`${Ce(t.startedAt)} 시작`:"시작 시각 없음"}</small>
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
        <small>${t.lastEventAt?Ce(t.lastEventAt):"시각 없음"}</small>
      </div>

      ${e.length>0?o`
            <div class="mission-member-stack">
              ${e.map(n=>o`
                <button class="mission-member-row" onClick=${()=>ia(n.name)}>
                  <strong>${n.name}</strong>
                  <span>${n.currentTask}</span>
                  <small>${n.output??"최근 출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      ${t.attentionSummary?o`<div class="mission-inline-note">attention: ${t.attentionSummary}</div>`:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>oi("intervene",t.session.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>oi("command",t.session.session_id)}>세션 원인 보기</button>
      </div>
    </article>
  `}function rp({row:t}){const e=t.recentTools.length>0?t.recentTools.join(", "):"도구 텔레메트리 없음",n=t.withWhom.length>0?t.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return o`
    <button class="mission-activity-card ${At(t.agent.status)}" onClick=${()=>ia(t.agent.name)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.agent.emoji??""}</span>
          <div>
            <strong>${t.agent.name}</strong>
            ${t.agent.koreanName?o`<span>${t.agent.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${At(t.agent.status)}">${t.agent.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>어디서 · ${t.where}</span>
        <span>누구와 · ${n}</span>
        <span>언제부터 · ${t.activeSince?Ce(t.activeSince):"n/a"}</span>
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
  `}function lp({row:t}){const e=[`gen ${t.keeper.generation??0}`,`handoff ${t.keeper.handoff_count_total??0}`,`compact ${t.keeper.compaction_count??0}`,t.keeper.context_ratio!=null?`ctx ${Math.round(t.keeper.context_ratio*100)}%`:null].filter(n=>n!==null).join(" · ");return o`
    <button class="mission-activity-card ${At(t.keeper.status)}" onClick=${()=>wo(t.keeper)}>
      <div class="mission-activity-head">
        <div class="mission-activity-title">
          <span class="agent-emoji">${t.keeper.emoji??""}</span>
          <div>
            <strong>${t.keeper.name}</strong>
            ${t.keeper.koreanName?o`<span>${t.keeper.koreanName}</span>`:null}
          </div>
        </div>
        <span class="command-chip ${At(t.keeper.status)}">${t.keeper.status}</span>
      </div>

      <div class="mission-activity-meta">
        <span>언제부터 · ${t.activeSince?Ce(t.activeSince):"n/a"}</span>
        <span>최근 heartbeat · ${t.keeper.last_heartbeat?Ce(t.keeper.last_heartbeat):"n/a"}</span>
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
  `}function cp({item:t}){return o`
    <article class="mission-action-card ${At(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${At(t.severity)}">${t.kind}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Fu(t)}>이 이슈로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>qu(t)}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function dp({action:t,incident:e}){const n=ju(t);return o`
    <article class="mission-action-card ${At(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${At(t.severity)}">${Ro(t.action_type)}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-action-detail">
        <span>${zu(t)}</span>
        <span>${Ou(t)}</span>
      </div>
      ${n?o`<div class="mission-action-preview">${n}</div>`:null}
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Ku(t,e,"상황판 추천 액션")}>이 액션으로 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Uu(t,e,"상황판 추천 액션")}>이 이슈의 원인 보기</button>
      </div>
    </article>
  `}function ii(){const t=sa.value;if(io.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ws.value&&!t)return o`<div class="empty-state error">${ws.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=ep(),n=sp(e),s=ap(),a=n.filter(d=>["active","busy","listening","idle"].includes(d.agent.status)).length,i=n.filter(d=>d.recentOutput).length+s.filter(d=>d.recentOutput).length,r=t.incidents[0]??null,c=t.recommended_actions[0]??null;return o`
    <section class="dashboard-panel mission-view">
      <${St} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>사람 운영자가 누가 어디서 누구와 무엇을 하고 있는지 바로 보는 관찰면입니다. 내부 메트릭은 아래가 아니라 Command로 내렸습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${At(t.summary.room_health)}">${t.summary.room_health??"ok"}</span>
          <span class="command-chip">${t.summary.project??"room"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Ce(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <${op}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${Re} label="활성 흐름" value=${e.length} detail="지금 보이는 crew / session" tone=${e.length>0?"ok":"warn"} />
        <${Re} label="응답 가능 에이전트" value=${a} detail="지금 응답 가능한 actor 수" tone=${a>0?"ok":"warn"} />
        <${Re} label="Keeper 수" value=${s.length} detail="연속성 runtime / generation 관찰 대상" tone=${s.length>0?"ok":"warn"} />
        <${Re} label="최근 output" value=${i} detail="main 화면에서 바로 볼 수 있는 최근 출력 수" tone=${i>0?"ok":"warn"} />
        <${Re} label="내부 incident" value=${t.incidents.length} detail="시스템 진단 신호는 아래 보조 카드로만 유지" tone=${(r==null?void 0:r.severity)??"ok"} />
        <${Re} label="추천 액션" value=${t.recommended_actions.length} detail="개입이 필요하면 Intervene로 바로 이동" tone=${(c==null?void 0:c.severity)??"ok"} />
      </div>

      <div class="mission-human-grid">
        <${T} title="같이 움직이는 흐름" class="mission-list-card" semanticId="mission.crews">
          <div class="mission-section-head">
            <h3>누가 누구와 같은 목표를 향하는지</h3>
            <p>team session 단위로 목표, 멤버, 최근 사건, 커뮤니케이션 흔적을 바로 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${e.length>0?e.map(d=>o`<${ip} key=${d.session.session_id} row=${d} />`):o`<div class="empty-state">지금 열려 있는 crew / session 이 없습니다.</div>`}
          </div>
        <//>

        <${T} title="에이전트 활동" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>각 에이전트가 지금 뭘 하는가</h3>
            <p>where / with whom / current task / recent input-output / recent tools 를 preview-first로 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${n.length>0?n.slice(0,10).map(d=>o`<${rp} key=${d.agent.name} row=${d} />`):o`<div class="empty-state">지금 보이는 에이전트 활동이 없습니다.</div>`}
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
            ${s.length>0?s.slice(0,8).map(d=>o`<${lp} key=${d.keeper.name} row=${d} />`):o`<div class="empty-state">지금 보이는 keeper 가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="내부 진단은 여기서만" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>internal signal / recommendation</h3>
            <p>artifact_scope_drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 신호로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${t.incidents.slice(0,2).map(d=>o`<${cp} key=${`${d.kind}:${d.target_id??"room"}`} item=${d} />`)}
            ${t.recommended_actions.slice(0,2).map(d=>o`<${dp} key=${`${d.action_type}:${d.target_id??"room"}`} action=${d} />`)}
            ${t.incidents.length===0&&t.recommended_actions.length===0?o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`:null}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>gt("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>gt("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const up="modulepreload",pp=function(t){return"/dashboard/"+t},ri={},mp=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let r=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(p=>({status:"fulfilled",value:p}),p=>({status:"rejected",reason:p}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=r(n.map(m=>{if(m=pp(m),m in ri)return;ri[m]=!0;const u=m.endsWith(".css"),p=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${p}`))return;const v=document.createElement("link");if(v.rel=u?"stylesheet":up,u||(v.as="script"),v.crossOrigin="",v.href=m,d&&v.setAttribute("nonce",d),document.head.appendChild(v),u)return new Promise(($,x)=>{v.addEventListener("load",$),v.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${m}`)))})}))}function i(r){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=r,window.dispatchEvent(c),!c.defaultPrevented)throw r}return a.then(r=>{for(const c of r||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})},Po=f(null),Wt=f(null),Ls=f(!1),Ms=f(!1),Ds=f(null),Es=f(null),lo=f(null),zs=f(null),V=f("warroom"),Un=f(null),co=f(!1),js=f(null),we=f(null),Os=f(!1),Fs=f(null),Hn=f(null),uo=f(!1),qs=f(null),In=f(null),Ks=f(!1),Nn=f(null),Ue=f(null);let cn=null;function Lo(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"}function C(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function g(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function st(t){return typeof t=="boolean"?t:void 0}function _t(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function yr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function vp(){const e=yr().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function _p(){const e=yr().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function fp(t){if(C(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:_t(t.tool_allowlist),model_allowlist:_t(t.model_allowlist),requires_human_for:_t(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:g(t.escalation_timeout_sec),kill_switch:st(t.kill_switch),frozen:st(t.frozen)}}function gp(t){if(C(t))return{headcount_cap:g(t.headcount_cap),active_operation_cap:g(t.active_operation_cap),max_cost_usd:g(t.max_cost_usd),max_tokens:g(t.max_tokens)}}function Mo(t){if(!C(t))return null;const e=l(t.unit_id),n=l(t.label),s=l(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:_t(t.roster),capability_profile:_t(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:fp(t.policy),budget:gp(t.budget)}}function br(t){if(!C(t))return null;const e=Mo(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:g(t.roster_total),roster_live:g(t.roster_live),active_operation_count:g(t.active_operation_count),health:l(t.health),reasons:_t(t.reasons),children:Array.isArray(t.children)?t.children.map(br).filter(n=>n!==null):[]}:null}function $p(t){if(C(t))return{total_units:g(t.total_units),company_count:g(t.company_count),platoon_count:g(t.platoon_count),squad_count:g(t.squad_count),leaf_agent_unit_count:g(t.leaf_agent_unit_count),live_agent_count:g(t.live_agent_count),managed_unit_count:g(t.managed_unit_count),active_operation_count:g(t.active_operation_count)}}function kr(t){const e=C(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:$p(e.summary),units:Array.isArray(e.units)?e.units.map(br).filter(n=>n!==null):[]}}function hp(t){if(!C(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function ca(t){if(!C(t))return null;const e=l(t.operation_id),n=l(t.objective),s=l(t.assigned_unit_id),a=l(t.trace_id),i=l(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:_t(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:i,chain:hp(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function yp(t){if(!C(t))return null;const e=ca(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function on(t){if(C(t))return{tone:l(t.tone),pending_ops:g(t.pending_ops),blocked_ops:g(t.blocked_ops),in_flight_ops:g(t.in_flight_ops),pipeline_stalls:g(t.pipeline_stalls),bus_traffic:g(t.bus_traffic),l1_hit_rate:g(t.l1_hit_rate),invalidation_count:g(t.invalidation_count),current_pending:g(t.current_pending),current_in_flight:g(t.current_in_flight),cdb_wakeups:g(t.cdb_wakeups),total_stolen:g(t.total_stolen),avg_best_score:g(t.avg_best_score),avg_candidate_count:g(t.avg_candidate_count),best_first_operations:g(t.best_first_operations),active_sessions:g(t.active_sessions),commit_rate:g(t.commit_rate),total_speculations:g(t.total_speculations)}}function bp(t){if(!C(t))return;const e=C(t.pipeline)?t.pipeline:void 0,n=C(t.cache)?t.cache:void 0,s=C(t.ooo)?t.ooo:void 0,a=C(t.speculative)?t.speculative:void 0,i=C(t.search_fabric)?t.search_fabric:void 0,r=C(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:g(e.total_ops),completed_ops:g(e.completed_ops),stalled_cycles:g(e.stalled_cycles),hazards_detected:g(e.hazards_detected),forwarding_used:g(e.forwarding_used),pipeline_flushes:g(e.pipeline_flushes),ipc:g(e.ipc)}:void 0,cache:n?{total_reads:g(n.total_reads),total_writes:g(n.total_writes),l1_hit_rate:g(n.l1_hit_rate),invalidation_count:g(n.invalidation_count),writeback_count:g(n.writeback_count),bus_traffic:g(n.bus_traffic)}:void 0,ooo:s?{agent_count:g(s.agent_count),total_added:g(s.total_added),total_issued:g(s.total_issued),total_completed:g(s.total_completed),total_stolen:g(s.total_stolen),cdb_wakeups:g(s.cdb_wakeups),stall_cycles:g(s.stall_cycles),global_cdb_events:g(s.global_cdb_events),current_pending:g(s.current_pending),current_in_flight:g(s.current_in_flight)}:void 0,speculative:a?{total_speculations:g(a.total_speculations),total_commits:g(a.total_commits),total_aborts:g(a.total_aborts),commit_rate:g(a.commit_rate),total_fast_calls:g(a.total_fast_calls),total_cost_usd:g(a.total_cost_usd),active_sessions:g(a.active_sessions)}:void 0,search_fabric:i?{total_operations:g(i.total_operations),best_first_operations:g(i.best_first_operations),legacy_operations:g(i.legacy_operations),blocked_operations:g(i.blocked_operations),ready_operations:g(i.ready_operations),research_pipeline_operations:g(i.research_pipeline_operations),avg_candidate_count:g(i.avg_candidate_count),avg_best_score:g(i.avg_best_score),top_stage:l(i.top_stage)??null}:void 0,signals:r?{issue_pressure:on(r.issue_pressure),cache_contention:on(r.cache_contention),scheduler_efficiency:on(r.scheduler_efficiency),routing_confidence:on(r.routing_confidence),speculative_posture:on(r.speculative_posture)}:void 0}}function xr(t){const e=C(t)?t:{},n=C(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),paused:g(n.paused),managed:g(n.managed),projected:g(n.projected)}:void 0,microarch:bp(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(yp).filter(s=>s!==null):[]}}function Sr(t){if(!C(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),s=l(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:l(t.leader_id)??null,roster:_t(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function kp(t){if(!C(t))return null;const e=Sr(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:ca(t.operation)}:null}function Ar(t){const e=C(t)?t:{},n=C(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),active:g(n.active),projected:g(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(kp).filter(s=>s!==null):[]}}function xp(t){if(!C(t))return null;const e=l(t.decision_id),n=l(t.trace_id),s=l(t.requested_action),a=l(t.scope_type),i=l(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function Cr(t){const e=C(t)?t:{},n=C(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),pending:g(n.pending),approved:g(n.approved),denied:g(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(xp).filter(s=>s!==null):[]}}function Sp(t){if(!C(t))return null;const e=Mo(t.unit);return e?{unit:e,roster_total:g(t.roster_total),roster_live:g(t.roster_live),headcount_cap:g(t.headcount_cap),active_operations:g(t.active_operations),active_operation_cap:g(t.active_operation_cap),utilization:g(t.utilization)}:null}function Ap(t){const e=C(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Sp).filter(n=>n!==null):[]}}function Cp(t){if(!C(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function wr(t){const e=C(t)?t:{},n=C(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:g(n.total),bad:g(n.bad),warn:g(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Cp).filter(s=>s!==null):[]}}function Tr(t){if(!C(t))return null;const e=l(t.event_id),n=l(t.trace_id),s=l(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function wp(t){const e=C(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(Tr).filter(n=>n!==null):[]}}function Tp(t){if(!C(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Ip(t){if(!C(t))return null;const e=l(t.lane_id),n=l(t.label),s=l(t.kind),a=l(t.phase),i=l(t.motion_state),r=l(t.source_of_truth),c=l(t.movement_reason),d=l(t.current_step);if(!e||!n||!s||!a||!i||!r||!c||!d)return null;const m=C(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:st(t.present)??!1,phase:a,motion_state:i,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:_t(t.blockers),counts:{operations:g(m.operations),detachments:g(m.detachments),workers:g(m.workers),approvals:g(m.approvals),alerts:g(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Tp).filter(u=>u!==null):[]}}function Np(t){if(!C(t))return null;const e=l(t.event_id),n=l(t.lane_id),s=l(t.kind),a=l(t.timestamp),i=l(t.title),r=l(t.detail),c=l(t.tone),d=l(t.source);return!e||!n||!s||!a||!i||!r||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:r,tone:c,source:d}}function Rp(t){if(!C(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,lane_ids:_t(t.lane_ids),count:g(t.count)??0}}function Ir(t){if(!C(t))return;const e=C(t.overview)?t.overview:{},n=C(t.gaps)?t.gaps:{},s=C(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:g(e.active_lanes),moving_lanes:g(e.moving_lanes),stalled_lanes:g(e.stalled_lanes),projected_lanes:g(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Ip).filter(a=>a!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Np).filter(a=>a!==null):[],gaps:{count:g(n.count),items:Array.isArray(n.items)?n.items.map(Rp).filter(a=>a!==null):[]},recommended_next_action:s?{tool:l(s.tool)??"masc_operator_snapshot",label:l(s.label)??"Observe operator state",reason:l(s.reason)??"",lane_id:l(s.lane_id)??null}:void 0}}function Pp(t){if(!C(t))return;const e=C(t.workers)?t.workers:{},n=st(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},...g(t.peak_hot_slots)!=null?{peak_hot_slots:g(t.peak_hot_slots)}:{},...g(t.ctx_per_slot)!=null?{ctx_per_slot:g(t.ctx_per_slot)}:{},workers:{expected:g(e.expected),joined:g(e.joined),current_task_bound:g(e.current_task_bound),fresh_heartbeats:g(e.fresh_heartbeats),done:g(e.done),final:g(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function Lp(t){const e=C(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:kr(e.topology),operations:xr(e.operations),detachments:Ar(e.detachments),alerts:wr(e.alerts),decisions:Cr(e.decisions),capacity:Ap(e.capacity),traces:wp(e.traces),swarm_status:Ir(e.swarm_status)}}function Mp(t){const e=C(t)?t:{},n=kr(e.topology),s=xr(e.operations),a=Ar(e.detachments),i=wr(e.alerts),r=Cr(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:Ir(e.swarm_status),swarm_proof:Pp(e.swarm_proof)}}function Dp(t){return C(t)?{chain_id:l(t.chain_id)??null,started_at:g(t.started_at)??null,progress:g(t.progress)??null,elapsed_sec:g(t.elapsed_sec)??null}:null}function Nr(t){if(!C(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:g(t.duration_ms)??null,message:l(t.message)??null,tokens:g(t.tokens)??null}:null}function Ep(t){if(!C(t))return null;const e=ca(t.operation);return e?{operation:e,runtime:Dp(t.runtime),history:Nr(t.history),mermaid:l(t.mermaid)??null,preview_run:Rr(t.preview_run)}:null}function zp(t){const e=C(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function jp(t){const e=C(t)?t:{},n=C(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:zp(e.connection),summary:n?{linked_operations:g(n.linked_operations),active_chains:g(n.active_chains),running_operations:g(n.running_operations),recent_failures:g(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Ep).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Nr).filter(s=>s!==null):[]}}function Op(t){if(!C(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:g(t.duration_ms)??null,error:l(t.error)??null}:null}function Rr(t){if(!C(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:g(t.duration_ms),success:st(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Op).filter(s=>s!==null):[]}:null}function Fp(t){const e=C(t)?t:{};return{run:Rr(e.run)}}function qp(t){if(!C(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function Kp(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Up(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.tool),a=l(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:_t(t.success_signals),pitfalls:_t(t.pitfalls)}}function Hp(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.summary),a=l(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Up).filter(i=>i!==null):[]}}function Wp(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:_t(t.tools)}}function Bp(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.symptom),a=l(t.why),i=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!s||!a||!i||!r?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:r}}function Gp(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.path_id),a=l(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:_t(t.notes)}}function Jp(t){const e=C(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(qp).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Kp).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Hp).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Wp).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Bp).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Gp).filter(n=>n!==null):[]}}function Vp(t){if(!C(t))return null;const e=l(t.id),n=l(t.title),s=l(t.status),a=l(t.detail),i=l(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function Yp(t){if(!C(t))return null;const e=l(t.code),n=l(t.severity),s=l(t.title),a=l(t.detail),i=l(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function Xp(t){if(!C(t))return null;const e=l(t.from),n=l(t.content),s=l(t.timestamp),a=g(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Qp(t){if(!C(t))return null;const e=l(t.name),n=l(t.role),s=l(t.lane),a=l(t.status),i=l(t.claim_marker),r=l(t.done_marker),c=l(t.final_marker);if(!e||!n||!s||!a||!i||!r||!c)return null;const d=(()=>{if(!C(t.last_message))return null;const m=g(t.last_message.seq),u=l(t.last_message.content),p=l(t.last_message.timestamp);return m==null||!u||!p?null:{seq:m,content:u,timestamp:p}})();return{name:e,role:n,lane:s,joined:st(t.joined)??!1,live_presence:st(t.live_presence)??!1,completed:st(t.completed)??!1,status:a,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:st(t.current_task_matches_run)??!1,squad_member:st(t.squad_member)??!1,detachment_member:st(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:g(t.heartbeat_age_sec)??null,heartbeat_fresh:st(t.heartbeat_fresh)??!1,claim_marker_seen:st(t.claim_marker_seen)??!1,done_marker_seen:st(t.done_marker_seen)??!1,final_marker_seen:st(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:c,last_message:d}}function Zp(t){if(!C(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!C(n))return null;const s=l(n.timestamp),a=g(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:st(t.provider_reachable)??null,provider_status_code:g(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:g(t.expected_slots),actual_slots:g(t.actual_slots),expected_ctx:g(t.expected_ctx),actual_ctx:g(t.actual_ctx),slot_reachable:st(t.slot_reachable)??null,slot_status_code:g(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:g(t.total_slots),ctx_per_slot:g(t.ctx_per_slot),active_slots_now:g(t.active_slots_now),peak_active_slots:g(t.peak_active_slots),sample_count:g(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function tm(t){const e=C(t)?t:{},n=C(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:g(n.expected_workers),joined_workers:g(n.joined_workers),live_workers:g(n.live_workers),squad_roster_size:g(n.squad_roster_size),detachment_roster_size:g(n.detachment_roster_size),current_task_bound:g(n.current_task_bound),fresh_heartbeats:g(n.fresh_heartbeats),claim_markers_seen:g(n.claim_markers_seen),done_markers_seen:g(n.done_markers_seen),final_markers_seen:g(n.final_markers_seen),completed_workers:g(n.completed_workers),peak_hot_slots:g(n.peak_hot_slots),hot_window_ok:st(n.hot_window_ok),pass_hot_concurrency:st(n.pass_hot_concurrency),pass_end_to_end:st(n.pass_end_to_end),pending_decisions:g(n.pending_decisions),pass:st(n.pass)}:void 0,provider:Zp(e.provider),operation:ca(e.operation),squad:Mo(e.squad),detachment:Sr(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Qp).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Vp).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Yp).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Xp).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Tr).filter(s=>s!==null):[],truth_notes:_t(e.truth_notes)}}function Se(t){V.value=t,Lo(t)&&em()}async function Pr(){Ls.value=!0,Ds.value=null;try{const t=await Ul();Po.value=Mp(t)}catch(t){Ds.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Ls.value=!1}}function Do(t){Ue.value=t}async function Eo(){Ms.value=!0,Es.value=null;try{const t=await Kl();Wt.value=Lp(t)}catch(t){Es.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ms.value=!1}}async function em(){Wt.value||Ms.value||await Eo()}async function Ae(){await Pr(),Lo(V.value)&&await Eo()}async function ie(){var t;uo.value=!0,qs.value=null;try{const e=await Hl(),n=jp(e);Hn.value=n;const s=Ue.value;n.operations.length===0?Ue.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Ue.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){qs.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{uo.value=!1}}function nm(){cn=null,In.value=null,Ks.value=!1,Nn.value=null}async function sm(t){cn=t,Ks.value=!0,Nn.value=null;try{const e=await Wl(t);if(cn!==t)return;In.value=Fp(e)}catch(e){if(cn!==t)return;In.value=null,Nn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{cn===t&&(Ks.value=!1)}}async function am(){co.value=!0,js.value=null;try{const t=await Bl();Un.value=Jp(t)}catch(t){js.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{co.value=!1}}async function Jt(t=vp(),e=_p()){Os.value=!0,Fs.value=null;try{const n=await Gl(t,e);we.value=tm(n)}catch(n){Fs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Os.value=!1}}async function ve(t,e,n){lo.value=t,zs.value=null;try{await Jl(e,n),await Pr(),(Wt.value||Lo(V.value))&&await Eo(),await Jt(),await ie()}catch(s){throw zs.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{lo.value=null}}function om(t){return ve(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function im(t){return ve(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function rm(t){return ve(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function lm(t={}){return ve("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function cm(t){return ve(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function dm(t){return ve(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function um(t,e){return ve(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function pm(t,e){return ve(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}bd(()=>{Ae(),ie(),(V.value==="swarm"||V.value==="warroom"||we.value!==null)&&Jt(),V.value==="warroom"&&ut()});function Lr(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Z(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function mm(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Mr(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function M(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let li=!1,vm=0,$a=null;async function _m(){$a||($a=mp(()=>import("./mermaid.core-BZzMR5Fh.js").then(e=>e.bE),[]).then(e=>e.default));const t=await $a;return li||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),li=!0),t}function re(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Wn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function dn(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function Bn(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ye(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Bn(t/e*100)}function fm(t,e){const n=Bn(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Dr(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const gm=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Er=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],$m=Er.map(t=>t.id),hm=["chain_start","node_start","node_complete","chain_complete","chain_error"],ym={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function ci(t){return!!t&&$m.includes(t)}function bm(){const t=O.value.params;return t.source!=="mission"?{}:{source:"mission",...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{}}}function zr(t){const e=bm();if(t==="operations")return e;if(t==="chains"){const n=Ue.value;return n?{...e,surface:t,operation:n}:{...e,surface:t}}return{...e,surface:t}}function km(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function xm(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function lt(t){return lo.value===t}function Gn(){return Po.value}function Sm(t){var a,i,r,c,d,m,u;const e=Po.value,n=we.value,s=Hn.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Am(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Cm(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function wm(){const t=Kn(O.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Ro(t.action_type)}</span>
        <span class="command-chip">${No(t)}</span>
        <span class="command-chip">${Mu(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Tm(){const t=V.value,e=ym[t],n=Sm(t);return o`
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
  `}function ts({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${fm(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Bn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function es({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${M(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${M(a)}" style=${`width: ${Math.max(8,Math.round(Bn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Im(){var F,tt,W,et;const t=Gn(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(F=t==null?void 0:t.swarm_status)==null?void 0:F.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,p=(n==null?void 0:n.active)??0,v=(s==null?void 0:s.active)??0,$=(r==null?void 0:r.moving_lanes)??0,x=(r==null?void 0:r.active_lanes)??0,b=(c==null?void 0:c.workers.done)??0,A=(c==null?void 0:c.workers.expected)??0,I=(i==null?void 0:i.bad)??0,z=(i==null?void 0:i.warn)??0,E=(a==null?void 0:a.pending)??0,N=(a==null?void 0:a.total)??0,R=p+v,Y=((tt=d==null?void 0:d.cache)==null?void 0:tt.l1_hit_rate)??((et=(W=d==null?void 0:d.signals)==null?void 0:W.cache_contention)==null?void 0:et.l1_hit_rate)??0,G=p>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",_=p>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${G}</h3>
        <p>${_}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${M(p>0?"ok":"warn")}">활성 작전 ${p}</span>
          <span class="command-chip ${M($>0?"ok":(x>0,"warn"))}">이동 레인 ${$}/${Math.max(x,$)}</span>
          <span class="command-chip ${M(I>0?"bad":z>0?"warn":"ok")}">치명 알림 ${I}</span>
          <span class="command-chip ${M(E>0?"warn":"ok")}">승인 대기 ${E}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${ts}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ye(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${ts}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${p}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ye(R,Math.max(m,R||1))}
          color="#4ade80"
        />
        <${ts}
          label="스웜 이동감"
          value=${`${$}/${Math.max(x,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Z(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ye($,Math.max(x,$||1))}
          color="#fbbf24"
        />
        <${ts}
          label="증거 수집률"
          value=${`${b}/${Math.max(A,b)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ye(b,Math.max(A,b||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${es}
        label="승인 대기열"
        value=${`${E}건 대기`}
        detail=${`현재 정책 창에서 ${N}개 결정을 추적 중입니다`}
        percent=${ye(E,Math.max(N,E||1))}
        tone=${E>0?"warn":"ok"}
      />
      <${es}
        label="알림 압력"
        value=${`${I} bad / ${z} warn`}
        detail=${I>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ye(I*2+z,Math.max((I+z)*2,1))}
        tone=${I>0?"bad":z>0?"warn":"ok"}
      />
      <${es}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ye(v,Math.max(m,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${es}
        label="캐시 신뢰도"
        value=${Y?Wn(Y):"n/a"}
        detail=${Y?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Bn((Y??0)*100)}
        tone=${Y>=.75?"ok":Y>=.4?"warn":"bad"}
      />
    </div>
  `}function Nm(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function jr(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Rm(){const e=jr().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Or(){const e=jr().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Pm(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Lm(t){return t.status==="claimed"||t.status==="in_progress"}function Mm(t){const e=Un.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ha(t){var e;return((e=Un.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Dm(t){const e=Un.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function le(t){try{await t()}catch{}}function zo(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Oe(t){const e=zo(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function ya(t){const e=zo(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Em(){var e,n,s;const t=we.value;return t?!!(t.run_id||(e=t.operation)!=null&&e.operation_id||(n=t.detachment)!=null&&n.detachment_id||(((s=t.summary)==null?void 0:s.expected_workers)??0)>0||t.workers.length>0||t.recent_messages.length>0||t.recent_trace_events.length>0):!1}function zm(t){const e=zo(t.status);return e==="active"||e==="running"}function jm(){var i,r,c,d;const t=((i=Kt.value)==null?void 0:i.sessions)??[],e=we.value,n=((r=e==null?void 0:e.detachment)==null?void 0:r.session_id)??null;if(n){const m=t.find(u=>u.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??Or();if(s){const m=t.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const m=t.find(u=>u.command_plane_detachment_id===a);if(m)return m}return t.find(zm)??t[0]??null}function Om(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"none",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"clean":"n/a",detail:[t.bound_task_status??null,t.detachment_member?"detachment":null,t.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Fm(t,e){const n=t.actor??t.spawn_role??`worker-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"worker",a=t.lane_id??t.capsule_mode??t.control_domain??"session",i=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"session lane",heartbeat:t.last_turn_ts_iso?Z(t.last_turn_ts_iso):"n/a",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Wn(t.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:i,note:t.routing_reason??null}}function di(t){return M(t.severity)}function qm({worker:t}){return o`
    <article class="command-card compact warroom-worker-card ${M(Oe(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${M(Oe(t.status))}">${t.status}</span>
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
  `}function se({label:t,surface:e,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){Se(e),gt("command",{...zr(e),...n});return}gt("intervene")}}
    >
      ${t}
    </button>
  `}function Km(){var v,$,x,b,A;const t=Gn(),e=Hn.value,n=Kn(O.value),s=Am(n),a=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,r=(v=t==null?void 0:t.swarm_status)==null?void 0:v.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,p=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((x=t==null?void 0:t.detachments.summary)==null?void 0:x.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((b=e==null?void 0:e.summary)==null?void 0:b.active_chains)??0}</strong><small>${((A=e==null?void 0:e.summary)==null?void 0:A.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${r?`${r.stalled_lanes??0}개 정체 · ${Z(r.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(p==null?void 0:p.l1_hit_rate)!=null?`${Wn(p.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function Fr(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function qr({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function Um({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Hm({lane:t}){const e=t.counts??{},n=Fr(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,r=a+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${M(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${M(n)}">${t.phase}</span>
          <span class="command-chip ${M(n)}">${t.motion_state}</span>
          <span class="command-chip">${Z(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${M(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Um} total=${s} />
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
              ${t.hard_flags.map(d=>o`<span class="command-chip ${M(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Kr({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Fr(n),a=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${M(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${M(s)}">${n.motion_state}</span>
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
  `}function Wm({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${M(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Bm({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${M(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Gm({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${M(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${M(e)}">${(t==null?void 0:t.status)??"missing"}</span>
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
  `}function Jm(){const t=Gn(),e=Kn(O.value),n=Cm(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(p=>p.present))??[],r=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${D} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${Kr} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Z(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Z(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${qr} lanes=${i} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(p=>o`<${Hm} lane=${p} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Gm} proof=${a} />

                <div class="command-guide-card ${r.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${M(r.some(p=>p.severity==="bad")?"bad":r.length>0?"warn":"ok")}">${r.length}</span>
                  </div>
                  ${r.length>0?o`<div class="swarm-event-rail">${r.slice(0,4).map(p=>o`<${Bm} gap=${p} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(p=>o`<${Wm} event=${p} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Vm(){return o`
    <div class="command-surface-tabs grouped">
      ${gm.map(t=>o`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Er.filter(e=>e.group===t.id).map(e=>o`
                <button
                  class="command-surface-tab ${V.value===e.id?"active":""}"
                  onClick=${()=>{Se(e.id),gt("command",zr(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Ym(){var F,tt,W,et,k,Rt,ee,_e,fe;const t=Gn(),e=Wt.value,n=xt.value,s=Nm(),a=s?Ct.value.find(j=>j.name===s)??null:null,i=s?Ot.value.filter(j=>j.assignee===s&&Lm(j)):[],r=((F=t==null?void 0:t.operations.summary)==null?void 0:F.active)??0,c=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,d=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,m=e==null?void 0:e.detachments.detachments.find(j=>{const Pt=j.detachment.heartbeat_deadline,ge=Pt?Date.parse(Pt):Number.NaN;return j.detachment.status==="stalled"||!Number.isNaN(ge)&&ge<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(j=>j.severity==="bad"),p=!!(n!=null&&n.room||n!=null&&n.project),v=(a==null?void 0:a.current_task)??null,$=Pm(a==null?void 0:a.last_seen),x=$!=null?$<=120:null,b=[p?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Ot.value.length>0?"masc_claim":"masc_add_task"}:v?x===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${v} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${v}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((et=t.topology.summary)==null?void 0:et.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((k=t.topology.summary)==null?void 0:k.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Rt=t.topology.summary)==null?void 0:Rt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],A=p?!s||!a?"masc_join":i.length===0?Ot.value.length>0?"masc_claim":"masc_add_task":v?x===!1?"masc_heartbeat":!t||(((ee=t.topology.summary)==null?void 0:ee.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":d>0?"masc_policy_approve":r>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",I=Mm(A),E=Dm(A==="masc_set_room"?["repo-root-room"]:A==="masc_plan_set_task"?["claimed-not-current"]:A==="masc_heartbeat"?["heartbeat-stale"]:A==="masc_dispatch_tick"?["no-detachments"]:A==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),N=ha("room_task_hygiene"),R=ha("cpv2_benchmark"),Y=ha("supervisor_session"),G=((_e=Un.value)==null?void 0:_e.docs)??[],_=[N,R,Y].filter(j=>j!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(I==null?void 0:I.title)??A}</strong>
            <span class="command-chip ok">${A}</span>
          </div>
          <p>${(I==null?void 0:I.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(fe=I==null?void 0:I.success_signals)!=null&&fe.length?o`<div class="command-tag-row">
                ${I.success_signals.map(j=>o`<span class="command-tag ok">${j}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${b.map(j=>o`
            <article class="command-readiness-row ${M(j.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${j.title}</strong>
                  <span class="command-chip ${M(j.tone)}">${j.tone}</span>
                </div>
                <p>${j.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${j.tool}</div>
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
                  ${E.map(j=>o`
                    <article class="command-guide-inline">
                      <strong>${j.title}</strong>
                      <div>${j.symptom}</div>
                      <div class="command-card-sub">${j.fix_tool} 로 해결: ${j.fix_summary}</div>
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
        ${co.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:js.value?o`<div class="empty-state error">${js.value}</div>`:o`
                <div class="command-path-grid">
                  ${_.map(j=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${j.title}</strong>
                        <span class="command-chip">${j.id}</span>
                      </div>
                      <p>${j.summary}</p>
                      <div class="command-card-sub">${j.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${j.steps.slice(0,4).map(Pt=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Pt.tool}</span>
                            <span>${Pt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${G.length>0?o`<div class="command-doc-links">
                      ${G.map(j=>o`<span class="command-tag">${j.title}: ${j.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Xm(){return o`
    <${Im} />
    <${Km} />
    <${Ym} />
  `}function Qm(){return Ms.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Es.value?o`<div class="empty-state error">${Es.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Ur({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy;return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${xm(t.unit.kind)}</span>
            <span class="command-chip ${M(t.health)}">${t.health??"ok"}</span>
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
            ${t.children.map(r=>o`<${Ur} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Zm({source:t}){const e=dl(null),[n,s]=Ti(null);return rt(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await _m(),{svg:d}=await c.render(`command-chain-${++vm}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function tv({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${re(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${re(s==null?void 0:s.status)}">${Wn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Dr(t.history)}</div>
    </button>
  `}function ev({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${re(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Z(t.timestamp)}</div>
      <div class="command-card-sub">${Dr(t)}</div>
    </article>
  `}function nv({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${re(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function sv({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${M(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
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
              <span class="command-tag ${re(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Se("swarm"),gt("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{Do(e.operation_id),Se("chains"),gt("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>le(()=>om(e.operation_id))}>
                ${lt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${lt(a)} onClick=${()=>le(()=>rm(e.operation_id))}>
                ${lt(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${lt(s)} onClick=${()=>le(()=>im(e.operation_id))}>
                ${lt(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function av({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${M(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Z(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Mr(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Z(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${mm(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function ov({alert:t}){return o`
    <article class="command-alert ${M(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${M(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Z(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function jo({event:t}){return o`
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
      <pre class="command-trace-detail">${Lr(t.detail)}</pre>
    </article>
  `}function iv({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
    <article class="command-card ${M(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${M(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Z(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${lt(e)} onClick=${()=>le(()=>cm(t.decision_id))}>
                ${lt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>le(()=>dm(t.decision_id))}>
                ${lt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function rv({row:t}){var c,d,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),r=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${M(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${lt(n)} onClick=${()=>le(()=>um(e.unit_id,!a))}>
          ${lt(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${lt(s)} onClick=${()=>le(()=>pm(e.unit_id,!i))}>
          ${lt(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function lv({item:t}){return o`
    <article class="command-guide-card ${M(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${M(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Hr({blocker:t}){return o`
    <article class="command-alert ${M(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${M(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function cv({worker:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${M(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
  `}function dv(){var G,_,F,tt,W,et,k,Rt,ee,_e,fe,j,Pt,ge,en,nn,Jn,Vn,Yn,Xn;const t=Gn(),e=we.value,n=Kt.value,s=Ut.value,a=jm(),i=e!=null&&e.operation?((G=Hn.value)==null?void 0:G.operations.find(q=>{var Ie;return q.operation.operation_id===((Ie=e.operation)==null?void 0:Ie.operation_id)}))??null:null,r=(e==null?void 0:e.workers)??[],c=(s==null?void 0:s.worker_cards)??[],d=r.length>0?r.map(Om):c.map(Fm),m=Em(),u=((_=t==null?void 0:t.decisions.summary)==null?void 0:_.pending)??0,p=(n==null?void 0:n.pending_confirms)??[],v=(e==null?void 0:e.blockers)??[],$=(s==null?void 0:s.recommended_actions)??[],x=(s==null?void 0:s.attention_items)??[],b=((F=e==null?void 0:e.recent_messages[0])==null?void 0:F.timestamp)??null,A=((tt=e==null?void 0:e.recent_trace_events[0])==null?void 0:tt.timestamp)??null,I=b??A??null,z=a==null?void 0:a.summary,E=((W=e==null?void 0:e.summary)==null?void 0:W.expected_workers)??(typeof(z==null?void 0:z.planned_worker_count)=="number"?z.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,N=((et=e==null?void 0:e.summary)==null?void 0:et.joined_workers)??(typeof(z==null?void 0:z.active_agent_count)=="number"?z.active_agent_count:void 0)??d.length,R=v.length>0||u>0||p.length>0?"warn":m||a?"ok":"warn",Y=((k=t==null?void 0:t.swarm_status)==null?void 0:k.lanes.filter(q=>q.present))??[];return rt(()=>{ut()},[]),rt(()=>{a!=null&&a.session_id&&Ye(a.session_id)},[a==null?void 0:a.session_id,n,(Rt=e==null?void 0:e.detachment)==null?void 0:Rt.session_id]),!m&&!a?Os.value||Cn.value?o`<div class="empty-state">live war room 불러오는 중…</div>`:o`
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
          <${se} label="작전 보기" surface="operations" />
          <${se} label="스웜 보기" surface="swarm" />
          <${se} label="개입 열기" />
          <${se} label="제어 보기" surface="control" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${M(R)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((ee=e==null?void 0:e.operation)==null?void 0:ee.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((_e=e==null?void 0:e.operation)==null?void 0:_e.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(fe=e==null?void 0:e.detachment)!=null&&fe.detachment_id?` · detachment ${e.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${se}
              label="스웜 상세"
              surface="swarm"
              params=${{...(j=e==null?void 0:e.operation)!=null&&j.operation_id?{operation_id:e.operation.operation_id}:{},...e!=null&&e.run_id?{run_id:e.run_id}:{}}}
            />
            <${se} label="트레이스" surface="trace" />
            ${i?o`<${se}
                  label="체인"
                  surface="chains"
                  params=${{operation:i.operation.operation_id}}
                />`:null}
            <${se} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${N??0}/${E??0}</strong>
            <small>${((Pt=e==null?void 0:e.summary)==null?void 0:Pt.completed_workers)??0} 완료 · ${d.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(ge=e==null?void 0:e.provider)!=null&&ge.runtime_blocker?"blocked":(en=e==null?void 0:e.provider)!=null&&en.provider_reachable?"ready":a?ya(a.status):"check"}</strong>
            <small>slots ${((nn=e==null?void 0:e.provider)==null?void 0:nn.active_slots_now)??0}/${((Jn=e==null?void 0:e.provider)==null?void 0:Jn.actual_slots)??((Vn=e==null?void 0:e.provider)==null?void 0:Vn.total_slots)??0} · ctx ${((Yn=e==null?void 0:e.provider)==null?void 0:Yn.actual_ctx)??((Xn=e==null?void 0:e.provider)==null?void 0:Xn.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${M(v.length>0||u>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${v.length+u+p.length}</strong>
            <small>blockers ${v.length} · approvals ${u} · confirms ${p.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Z(I)}</strong>
            <small>${b?"message":A?"trace":"waiting"}</small>
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
            ${Y.length>0?o`
                  <${Kr} lanes=${Y} />
                  <${qr} lanes=${Y} />
                `:a?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${M(Oe(a.status))}">${ya(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${dn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${dn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${d.length>0?o`<div class="command-card-stack">
                  ${d.map(q=>o`<${qm} worker=${q} />`)}
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
                </div>`:$.length>0||x.length>0?o`<div class="command-card-stack">
                    ${$.slice(0,4).map(q=>o`
                      <article class="command-guide-card ${di(q)}">
                        <div class="command-guide-head">
                          <strong>${q.action_type}</strong>
                          <span class="command-chip ${di(q)}">${q.target_type}</span>
                        </div>
                        <p>${q.reason}</p>
                      </article>
                    `)}
                    ${x.slice(0,3).map(q=>o`
                      <article class="command-alert ${M(q.severity)}">
                        <div class="command-card-head">
                          <strong>${q.kind}</strong>
                          <span class="command-chip ${M(q.severity)}">${q.severity}</span>
                        </div>
                        <p>${q.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?o`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((q,Ie)=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${Ie+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Lr(q)}</pre>
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
                  ${e.recent_trace_events.map(q=>o`<${jo} event=${q} />`)}
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
              ${v.length>0?v.map(q=>o`<${Hr} blocker=${q} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
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
                        <span class="command-chip ${M(Oe(e.operation.status))}">${e.operation.status}</span>
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
                        <span class="command-chip ${M(Oe(e.detachment.status))}">${e.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${e.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${e.detachment.roster.length}</span>
                        <span>Session</span><span>${e.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Mr(e.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:null}
              ${a?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${a.session_id}</strong>
                          <div class="command-card-sub">team session focus</div>
                        </div>
                        <span class="command-chip ${M(Oe(a.status))}">${ya(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${dn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${dn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function uv(){var d,m,u,p,v,$,x,b,A,I,z,E,N,R,Y,G,_,F,tt,W,et;const t=we.value,e=Rm(),n=Or(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=t==null?void 0:t.provider)==null?void 0:u.actual_slots)??((p=t==null?void 0:t.provider)==null?void 0:p.total_slots)??0,i=((v=t==null?void 0:t.provider)==null?void 0:v.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,c=((b=t==null?void 0:t.provider)==null?void 0:b.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${Jm} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${Os.value?o`<div class="empty-state">Loading swarm live state…</div>`:Fs.value?o`<div class="empty-state error">${Fs.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((A=t.summary)==null?void 0:A.joined_workers)??0}/${((I=t.summary)==null?void 0:I.expected_workers)??0}</strong><small>${((z=t.summary)==null?void 0:z.live_workers)??0}개 가동 · ${((E=t.summary)==null?void 0:E.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${r}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(N=t.summary)!=null&&N.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=t.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Y=t.summary)!=null&&Y.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((G=t.operation)==null?void 0:G.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((_=t.squad)==null?void 0:_.label)??"없음"}</span>
                      <span>실행체</span><span>${((F=t.detachment)==null?void 0:F.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((W=t.summary)==null?void 0:W.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((et=t.provider)==null?void 0:et.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(k=>o`<span class="command-tag">${k}</span>`)}
                        </div>`:null}
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(k=>o`<${lv} item=${k} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(k=>o`<${cv} worker=${k} />`)}
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
                      ${t.provider.timeline.slice(-12).map(k=>o`
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
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(k=>o`<${Hr} blocker=${k} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(k=>o`
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
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${D} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(k=>o`<${jo} event=${k} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function pv(){const t=Wt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${sv} card=${e} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${av} card=${e} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function mv(){var c,d,m,u,p,v,$,x,b,A,I,z,E,N,R,Y;const t=Hn.value,e=(t==null?void 0:t.operations)??[],n=Ue.value,s=e.find(G=>G.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((d=In.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,r=!((m=In.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return rt(()=>{a?sm(a):nm()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${re(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${re(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${Z(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${qs.value?o`<div class="empty-state error">${qs.value}</div>`:null}

        ${uo.value&&!t?o`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(G=>o`
                    <${tv}
                      overlay=${G}
                      selected=${(s==null?void 0:s.operation.operation_id)===G.operation.operation_id}
                      onSelect=${()=>Do(G.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(G=>o`<${ev} item=${G} />`)}
                </div>
              `:o`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${re((x=s.operation.chain)==null?void 0:x.status)}">
                    ${((b=s.operation.chain)==null?void 0:b.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((A=s.operation.chain)==null?void 0:A.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((I=s.operation.chain)==null?void 0:I.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Wn((z=s.runtime)==null?void 0:z.progress)}</span>
                  <span>Elapsed</span><span>${dn((E=s.runtime)==null?void 0:E.elapsed_sec)}</span>
                  <span>Updated</span><span>${Z(((N=s.operation.chain)==null?void 0:N.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((Y=s.operation.chain)==null?void 0:Y.chain_id)??"graph"}</span>
                      </div>
                      <${Zm} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Ks.value?o`<div class="empty-state">Loading run detail…</div>`:Nn.value?o`<div class="empty-state error">${Nn.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?o`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(G=>o`<${nv} node=${G} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function vv(){const t=Wt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${D} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(e=>o`<${Ur} node=${e} />`)}`:o`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function _v(){const t=Wt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${D} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${ov} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function fv(){const t=Wt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${D} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${jo} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function gv(){const t=Wt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${iv} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${rv} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function $v(){if(V.value==="warroom")return o`<${dv} />`;if(V.value==="summary")return o`<${Xm} />`;if(V.value==="swarm")return o`<${uv} />`;if(!Wt.value)return o`<${Qm} />`;switch(V.value){case"chains":return o`<${mv} />`;case"topology":return o`<${vv} />`;case"alerts":return o`<${_v} />`;case"trace":return o`<${fv} />`;case"control":return o`<${gv} />`;case"operations":default:return o`<${pv} />`}}function hv(){return rt(()=>{Ae(),ie(),am(),Jt()},[]),rt(()=>{if(O.value.tab!=="command")return;const t=O.value.params.surface,e=O.value.params.operation,n=Kn(O.value);if(ci(t))Se(t);else if(n){const s=fr(n);ci(s)&&Se(s)}else t||Se("warroom");e&&Do(e),(t==="swarm"||t==="warroom"||V.value==="warroom")&&Jt(),(t==="warroom"||V.value==="warroom")&&ut()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),rt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Ae(),ie(),(V.value==="swarm"||V.value==="warroom")&&Jt(),V.value==="warroom"&&ut()},250))},n=new EventSource(km()),s=hm.map(a=>{const i=()=>e();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),t&&window.clearTimeout(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{le(()=>lm())}}
            disabled=${lt("dispatch:tick")}
          >
            ${lt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ae(),ie(),Jt(),V.value==="warroom"&&ut()}}
            disabled=${Ls.value}
          >
            ${Ls.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Ds.value?o`<div class="empty-state error">${Ds.value}</div>`:null}
      ${zs.value?o`<div class="empty-state error">${zs.value}</div>`:null}
      <${St} surfaceId="command" />
      <${wm} />
      ${V.value==="warroom"?null:o`<${Tm} />`}
      <${Vm} />
      <${$v} />
    </section>
  `}const Wr="masc_dashboard_agent_name";function yv(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Wr))==null?void 0:s.trim())||"dashboard"}const da=f(yv()),He=f(""),po=f("운영 점검"),We=f(""),Rn=f(""),Pn=f("2"),Ln=f(""),jt=f("note"),Mn=f(""),Dn=f(""),En=f(""),zn=f("2"),Us=f("운영자 중지 요청"),Hs=f(""),Be=f(""),ns=f(null);function bv(t){const e=t.trim()||"dashboard";da.value=e,localStorage.setItem(Wr,e)}function ui(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function kv(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Xe(t){return typeof t=="string"?t.trim().toLowerCase():""}function xv(t){var s;const e=Xe(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Xe((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function ba(t){const e=Xe(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function pi(t){return t.some(e=>Xe(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Sv(t){return t.target_type==="team_session"}function Av(t){return t.target_type==="keeper"}function ss(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function as(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function rn(t){switch(Xe(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function mi(t){return t?"확인 후 실행":"즉시 실행"}function Cv(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}function ft(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function wv(t){if(t.action_type==="team_task_inject")return"task";if(t.action_type==="team_broadcast")return"broadcast";if(t.action_type==="team_note")return"note";if(t.action_type==="team_turn"){const e=ft(t.suggested_payload,"turn_kind");if(e==="broadcast"||e==="task")return e}return"note"}function Tv(t){const e=t.suggested_payload;if(t.target_type==="room"){if(t.action_type==="broadcast"){He.value=ft(e,"message")??t.summary;return}t.action_type==="task_inject"&&(We.value=ft(e,"title")??"운영자 주입 작업",Rn.value=ft(e,"description")??t.summary,Pn.value=ft(e,"priority")??Pn.value);return}if(t.target_type==="team_session"){if(t.target_id&&(Ln.value=t.target_id),t.action_type==="team_stop"){Us.value=ft(e,"reason")??t.summary;return}jt.value=wv(t);const n=ft(e,"message");n&&(Mn.value=n),jt.value==="task"&&(Dn.value=ft(e,"task_title")??ft(e,"title")??"운영자 주입 작업",En.value=ft(e,"task_description")??ft(e,"description")??t.summary,zn.value=ft(e,"task_priority")??ft(e,"priority")??zn.value);return}t.target_type==="keeper"&&(t.target_id&&(Hs.value=t.target_id),Be.value=ft(e,"message")??t.summary)}function Iv(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Te(t){const e=da.value.trim()||"dashboard";try{const n=await nu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?L("확인 대기열에 올렸습니다","warning"):L(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return L(s,"error"),null}}async function vi(){const t=He.value.trim();if(!t)return;await Te({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(He.value="")}async function Nv(){await Te({action_type:"room_pause",target_type:"room",payload:{reason:po.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function _i(){await Te({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function Rv(){const t=We.value.trim();if(!t)return;await Te({action_type:"task_inject",target_type:"room",payload:{title:t,description:Rn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(Pn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(We.value="",Rn.value="")}async function Pv(){var r;const t=Kt.value,e=Ln.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){L("먼저 세션을 고르세요","warning");return}const n={},s=Mn.value.trim();s&&(n.message=s);let a="team_note";jt.value==="broadcast"?a="team_broadcast":jt.value==="task"&&(a="team_task_inject"),jt.value==="task"&&(n.task_title=Dn.value.trim()||"운영자 주입 작업",n.task_description=En.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(zn.value,10)||2),await Te({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Mn.value="",jt.value==="task"&&(Dn.value="",En.value=""))}async function Lv(){var n;const t=Kt.value,e=Ln.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){L("먼저 세션을 고르세요","warning");return}await Te({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Us.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Mv(){var a;const t=Kt.value,e=Hs.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=Be.value.trim();if(!e){L("먼저 keeper를 고르세요","warning");return}if(!n)return;await Te({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Be.value="")}async function Dv(t){const e=da.value.trim()||"dashboard";try{await su(e,t),L("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";L(s,"error")}}function Ev(){var R,Y,G;const t=Kt.value,e=O.value.tab==="intervene"?Kn(O.value):null,n=sr.value,s=Ut.value,a=(t==null?void 0:t.room)??{},i=(t==null?void 0:t.sessions)??[],r=(t==null?void 0:t.keepers)??[],c=(t==null?void 0:t.pending_confirms)??[],d=(t==null?void 0:t.recent_messages)??[],m=(n==null?void 0:n.recommended_actions)??[],u=(t==null?void 0:t.available_actions)??[],p=i.find(_=>_.session_id===Ln.value)??i[0]??null,v=r.find(_=>_.name===Hs.value)??r[0]??null,$=(n==null?void 0:n.attention_items)??[],x=$.filter(Sv),b=$.filter(Av),A=i.filter(_=>xv(_)!=="ok"),I=r.filter(_=>ba(_)!=="ok"),z=d.slice(0,5),E=Iv(e,i,r);rt(()=>{Qt()},[]),rt(()=>{if(O.value.tab!=="intervene"){ns.value=null;return}if(!e){ns.value=null;return}ns.value!==e.id&&(ns.value=e.id,Tv(e))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,e==null?void 0:e.id]),rt(()=>{const _=(p==null?void 0:p.session_id)??null;Ye(_)},[p==null?void 0:p.session_id]);const N=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:c.length,detail:c.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:c.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:x.length>0?x.length:i.length,detail:x.length>0?((R=x[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":i.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:x.length>0?pi(x):i.length===0?"warn":A.some(_=>Xe(_.status)==="paused")?"bad":A.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:b.length>0?b.length:I.length,detail:b.length>0?((Y=b[0])==null?void 0:Y.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":I.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:b.length>0?pi(b):I.some(_=>ba(_)==="bad")?"bad":I.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${St} surfaceId="intervene" />
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
            value=${da.value}
            onInput=${_=>bv(_.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ut(),Qt(),Ye((p==null?void 0:p.session_id)??null)}}
            disabled=${Cn.value||Q.value}
          >
            ${Cn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ue.value?o`<section class="ops-banner error">${ue.value}</section>`:null}
      ${Ve.value?o`<section class="ops-banner error">${Ve.value}</section>`:null}
      ${e?o`
        <section class="ops-banner ${E?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Ro(e.action_type)}</span>
            <span>${No(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${E?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const _=[];if(c.length>0&&_.push({label:`확인 대기 ${c.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const F=document.querySelector(".ops-pending-section");F==null||F.scrollIntoView({behavior:"smooth"})}}),a.paused&&_.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void _i()}),I.length>0){const F=I.filter(tt=>ba(tt)==="bad");_.push({label:F.length>0?`Keeper ${F.length}개 오프라인`:`Keeper ${I.length}개 점검 필요`,desc:F.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:F.length>0?"bad":"warn",onClick:()=>{const tt=document.querySelector(".ops-keeper-section");tt==null||tt.scrollIntoView({behavior:"smooth"})}})}return _.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${_.slice(0,3).map(F=>o`
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
          ${N.map(_=>o`
            <div key=${_.key} class="ops-priority-card ${_.tone}">
              <span class="ops-priority-label">${_.label}</span>
              <strong>${_.value}</strong>
              <div class="ops-priority-detail">${_.detail}</div>
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
                <strong>${a.current_room??a.room_id??"default"}</strong>
              </div>
              <div class="ops-stat">
                <span>프로젝트</span>
                <strong>${a.project??"확인 없음"}</strong>
              </div>
              <div class="ops-stat">
                <span>클러스터</span>
                <strong>${a.cluster??"확인 없음"}</strong>
              </div>
              <div class="ops-stat ${a.paused?"warn":"ok"}">
                <span>상태</span>
                <strong>${a.paused?"일시정지":"진행 중"}</strong>
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
                onInput=${_=>{He.value=_.target.value}}
                onKeyDown=${_=>{_.key==="Enter"&&vi()}}
                disabled=${Q.value}
              />
              <button class="control-btn" onClick=${()=>{vi()}} disabled=${Q.value||He.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${po.value}
                onInput=${_=>{po.value=_.target.value}}
                disabled=${Q.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Nv()}} disabled=${Q.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{_i()}} disabled=${Q.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${We.value}
              onInput=${_=>{We.value=_.target.value}}
              disabled=${Q.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${Rn.value}
              onInput=${_=>{Rn.value=_.target.value}}
              disabled=${Q.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${Pn.value}
                onChange=${_=>{Pn.value=_.target.value}}
                disabled=${Q.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Rv()}} disabled=${Q.value||We.value.trim()===""}>
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
                ${m.map(_=>o`
                  <article key=${`${_.action_type}:${_.target_type}:${_.target_id??"room"}`} class="ops-log-entry ${_.severity}">
                    <div class="ops-log-head">
                      <strong>${ss(_.action_type)}</strong>
                      <span>${as(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                      <span>${mi(_.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${_.reason}</div>
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
            ${c.length>0?o`
              <div class="ops-confirmation-list">
                ${c.map(_=>o`
                  <article key=${_.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${ss(_.action_type)}</strong>
                      <span>${as(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                      <span>${_.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${_.preview?o`<pre class="ops-code-block compact">${ui(_.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{Dv(_.confirm_token)}} disabled=${Q.value}>
                        실행
                      </button>
                      <span class="ops-token">${_.confirm_token}</span>
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
                ${z.map(_=>o`
                  <article key=${_.seq??_.id??_.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${_.from}</strong>
                      <span>${_.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${_.content}</div>
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
              ${i.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:i.map(_=>{var F;return o`
                <button
                  key=${_.session_id}
                  class="ops-entity-card ${(p==null?void 0:p.session_id)===_.session_id?"active":""}"
                  onClick=${()=>{Ln.value=_.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${_.session_id}</strong>
                    <span class="status-badge ${_.status??"idle"}">${rn(_.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(_.progress_pct??0)}%</span>
                    <span>${_.done_delta_total??0}건 완료</span>
                    <span>${(F=_.team_health)!=null&&F.status?rn(String(_.team_health.status)):"상태 확인 필요"}</span>
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
            ${p&&s?o`
              <div class="ops-log-list">
                ${s.attention_items.length>0?s.attention_items.map(_=>o`
                  <article key=${`${_.kind}:${_.target_id??"session"}`} class="ops-log-entry ${_.severity}">
                    <div class="ops-log-head">
                      <strong>${_.kind}</strong>
                      <span>${as(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${_.summary}</div>
                  </article>
                `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${s.worker_cards.length>0?s.worker_cards.map(_=>o`
                  <article key=${`${_.actor??_.spawn_role??"worker"}:${_.spawn_agent??_.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${_.actor??_.spawn_role??"worker"}</strong>
                      <span>${rn(_.status)}</span>
                      <span>${_.spawn_agent??_.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${_.worker_class??"worker"}${_.lane_id?` · ${_.lane_id}`:""}${_.routing_reason?` · ${_.routing_reason}`:""}
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
                  <span>상태: ${rn(p.status)}</span>
                  <span>경과: ${p.elapsed_sec??0}초</span>
                  <span>남은 시간: ${p.remaining_sec??0}초</span>
                </div>
                ${p.recent_events&&p.recent_events.length>0?o`
                  <pre class="ops-code-block compact">${ui(p.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${jt.value}
                onChange=${_=>{jt.value=_.target.value}}
                disabled=${Q.value||!p}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{Pv()}} disabled=${Q.value||!p}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${Cv(jt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${Mn.value}
              onInput=${_=>{Mn.value=_.target.value}}
              disabled=${Q.value||!p}
            ></textarea>

            ${jt.value==="task"?o`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${Dn.value}
                onInput=${_=>{Dn.value=_.target.value}}
                disabled=${Q.value||!p}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${En.value}
                onInput=${_=>{En.value=_.target.value}}
                disabled=${Q.value||!p}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${zn.value}
                onChange=${_=>{zn.value=_.target.value}}
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
                value=${Us.value}
                onInput=${_=>{Us.value=_.target.value}}
                disabled=${Q.value||!p}
              />
              <button class="control-btn ghost" onClick=${()=>{Lv()}} disabled=${Q.value||!p}>
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
              ${r.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:r.map(_=>o`
                <button
                  key=${_.name}
                  class="ops-entity-card ${(v==null?void 0:v.name)===_.name?"active":""}"
                  onClick=${()=>{Hs.value=_.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${_.name}</strong>
                    <span class="status-badge ${_.status??"idle"}">${rn(_.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${_.model??"model 확인 필요"}</span>
                    <span>${typeof _.context_ratio=="number"?`${Math.round(_.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${kv(_.last_turn_ago_s)}</span>
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

            ${v?o`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${v.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${v.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${v.generation??0}</span>
                  <span>활성 목표: ${((G=v.active_goal_ids)==null?void 0:G.length)??0}</span>
                </div>
              </div>
            `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Be.value}
              onInput=${_=>{Be.value=_.target.value}}
              disabled=${Q.value||!v}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{Mv()}} disabled=${Q.value||!v||Be.value.trim()===""}>
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
              ${u.length?u.map(_=>o`
                    <article key=${`${_.action_type}:${_.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${ss(_.action_type)}</strong>
                        <span>${as(_.target_type)}</span>
                        <span>${mi(_.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${_.description??"설명이 아직 없습니다."}</div>
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
              ${Ns.value.length===0?o`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:Ns.value.map(_=>o`
                <article key=${_.id} class="ops-log-entry ${_.outcome}">
                  <div class="ops-log-head">
                    <strong>${ss(_.action_type)}</strong>
                    <span>${_.target_label}</span>
                    <span>${_.at}</span>
                  </div>
                  <div class="ops-log-body">${_.message}</div>
                </article>
              `)}
            </div>
          </section>
        </div>
      </div>
    </section>
  `}function zv({text:t}){if(!t)return null;const e=jv(t);return o`<div class="markdown-content">${e}</div>`}function jv(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(r);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&r.push(m),s++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ka(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${ka(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${ka(i.join(`
`))}</p>`)}return n}function ka(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Br=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],gs=f(null),$s=f([]),Qe=f(!1),xe=f(null),vn=f(""),_n=f(!1),Fe=f(!0);function Ov(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Fv=f(Ov());function qv(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function fi(t){return t.updated_at!==t.created_at}function Kv(t){const e=`${t.title} ${t.tags.join(" ")} ${t.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(e)||e.includes("테스트")||e.includes("실험")}function Uv(t){const e=t.author.toLowerCase(),n=(t.hearth??"").toLowerCase();return!!(e==="mdal"||e.includes("smoke-bot")||e.includes("harness")||n.startsWith("mdal")||n.includes("harness"))}function Gr(t){return Fe.value?t.filter(e=>!Uv(e)&&!Kv(e)):t}async function Oo(t){xe.value=t,gs.value=null,$s.value=[],Qe.value=!0;try{const e=await tc(t);if(xe.value!==t)return;gs.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},$s.value=e.comments??[]}catch{xe.value===t&&(gs.value=null,$s.value=[])}finally{xe.value===t&&(Qe.value=!1)}}async function gi(t){const e=vn.value.trim();if(e){_n.value=!0;try{await ec(t,Fv.value,e),vn.value="",L("Comment posted","success"),await Oo(t),Ft()}catch{L("Failed to post comment","error")}finally{_n.value=!1}}}function Hv(){const t=bn.value,e=Fe.value?"Hiding automation posts":"Show automation posts";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Br.map(n=>o`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{bn.value=n.id,Ft()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Fe.value?"is-active":""}"
          onClick=${()=>{Fe.value=!Fe.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Ee.value?"is-active":""}"
          onClick=${()=>{Ee.value=!Ee.value,Ft()}}
        >
          ${Ee.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ft} disabled=${xn.value}>
          ${xn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function xa(){var s;const t=((s=Br.find(a=>a.id===bn.value))==null?void 0:s.label)??bn.value,e=Gr(yn.value),n=yn.value.length-e.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise filter</span>
        <strong>${Fe.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Ee.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${so.value?o`<${ot} timestamp=${so.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Wv({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Fi(t.id,n),Ft()}catch{L("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>_l(t.id)}>
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
                ${fi(t)?o`<span class="board-meta-chip">Updated</span>`:null}
                ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${ot} timestamp=${t.created_at} /></span>
            ${fi(t)?o`<span>Updated <${ot} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${qv(t.content)}</div>
      </div>
    </div>
  `}function Bv({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${ot} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Gv({postId:t}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${vn.value}
        onInput=${e=>{vn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&gi(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${_n.value}
      />
      <button
        onClick=${()=>gi(t)}
        disabled=${_n.value||vn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${_n.value?"...":"Post"}
      </button>
    </div>
  `}function Jv({post:t}){xe.value!==t.id&&!Qe.value&&Oo(t.id);const e=async n=>{try{await Fi(t.id,n),Ft()}catch{L("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>gt("memory")}>← Back to Memory</button>
      <${T} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${zv} text=${t.content} />
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
        ${Qe.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Bv} comments=${$s.value} />`}
        <${Gv} postId=${t.id} />
      <//>
    </div>
  `}function Vv(){const t=Gr(yn.value),e=O.value.params.post??null,n=e?t.find(s=>s.id===e)??(xe.value===e?gs.value:null):null;return e&&!n&&xe.value!==e&&!Qe.value&&Oo(e),e?n?o`
          <${St} surfaceId="memory" />
          <${xa} />
          <${Jv} post=${n} />
        `:o`
          <div>
            <${St} surfaceId="memory" />
            <${xa} />
            <button class="back-btn" onClick=${()=>gt("memory")}>← Back to Memory</button>
            ${Qe.value?o`<div class="loading-indicator">Loading post...</div>`:o`<div class="empty-state">Post not found</div>`}
          </div>
        `:o`
    <div>
      <${St} surfaceId="memory" />
      <${xa} />
      <${Hv} />
      ${xn.value?o`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?o`<div class="empty-state">No posts in durable memory right now</div>`:o`
              <${T} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(s=>o`<${Wv} key=${s.id} post=${s} />`)}
                </div>
              <//>
            `}
    </div>
  `}function Jr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const Sa=600*1e3,Yv=1200*1e3,$i=.8;function ae(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Pe(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Xv(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Qv(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Zv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function t_(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function e_(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function n_(t){var d,m;const e=na.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,s=n?Math.max(0,Date.now()-ae(n)):Number.POSITIVE_INFINITY,a=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",c=n?"Offline or inactive":"No recent presence"):s>Yv?(i="quiet",r="bad",c=a?"Working without a fresh signal":"No fresh agent signal"):a?(i="working",r=s>Sa?"warn":"ok",c=s>Sa?"Execution looks quiet for too long":"Task and live signal aligned"):s>Sa?(i="quiet",r="warn",c="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((m=t.current_task)==null?void 0:m.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function s_(t){const e=nd.value.get(t.name)??"idle",n=od.value.has(t.name),s=t.context_ratio??0;let a="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(a="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||s>=$i)&&(a="warning",i="warn",r=s>=$i?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:a,tone:i,focus:t_(t),note:r}}function ln({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function a_({item:t}){const e=t.kind==="agent"?()=>ia(t.agent.name):()=>wo(t.keeper);return o`
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
  `}function hi({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>ia(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Jr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${me} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Xv(t.state)}</span>
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
  `}function o_({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>wo(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Jr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${me} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Qv(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${ot} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${e_(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Zv(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function i_(){const t=[...Ct.value].map(n_).sort((u,p)=>{const v=Pe(p.tone)-Pe(u.tone);if(v!==0)return v;const $=p.activeTaskCount-u.activeTaskCount;return $!==0?$:ae(p.lastSignalAt)-ae(u.lastSignalAt)}),e=[...te.value].map(s_).sort((u,p)=>{const v=Pe(p.tone)-Pe(u.tone);if(v!==0)return v;const $=(p.keeper.context_ratio??0)-(u.keeper.context_ratio??0);return $!==0?$:ae(p.keeper.last_heartbeat)-ae(u.keeper.last_heartbeat)}),n=t.filter(u=>u.state!=="offline"),s=t.filter(u=>u.state==="offline"),a=n.length,i=t.filter(u=>u.state==="working").length,r=t.filter(u=>u.lastSignalAt&&Date.now()-ae(u.lastSignalAt)<=12e4).length,c=t.filter(u=>u.tone!=="ok"),d=e.filter(u=>u.tone!=="ok"),m=[...d.map(u=>({kind:"keeper",key:`keeper-${u.keeper.name}`,tone:u.tone,title:u.keeper.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.keeper.last_heartbeat??null,keeper:u.keeper})),...c.map(u=>({kind:"agent",key:`agent-${u.agent.name}`,tone:u.tone,title:u.agent.name,subtitle:`${u.note} · ${u.focus}`,timestamp:u.lastSignalAt,agent:u.agent}))].sort((u,p)=>{const v=Pe(p.tone)-Pe(u.tone);return v!==0?v:ae(p.timestamp)-ae(u.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <${St} surfaceId="execution" />
      <div class="stats-grid">
        <${ln} label="Workers online" value=${a} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${ln} label="Working now" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${ln} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${ln} label="Worker alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${ln} label="Continuity alerts" value=${d.length} color=${d.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${T} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${m.length===0?o`<div class="empty-state">No execution alerts right now</div>`:m.map(u=>o`<${a_} key=${u.key} item=${u} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?o`<div class="empty-state">No active workers visible</div>`:n.map(u=>o`<${hi} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(u=>o`<${o_} key=${u.keeper.name} row=${u} />`)}
          </div>
        <//>

        <${T} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${s.length===0?o`<div class="empty-state">No offline workers right now</div>`:s.map(u=>o`<${hi} key=${u.agent.name} row=${u} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ws=f("all"),Bs=f("all"),mo=Nt(()=>{let t=kn.value;return Ws.value!=="all"&&(t=t.filter(e=>e.horizon===Ws.value)),Bs.value!=="all"&&(t=t.filter(e=>e.status===Bs.value)),t}),r_=Nt(()=>{const t={short:[],mid:[],long:[]};for(const e of mo.value){const n=t[e.horizon];n&&n.push(e)}return t}),l_=Nt(()=>{const t=Array.from(Bi.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function c_(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Fo(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function hs(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function d_(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function yi(t){return t.toFixed(4)}function bi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function u_({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${hs(t.horizon)}">
            ${Fo(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${c_(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${ot} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${me} status=${t.status} />
        <div class="goal-updated">
          <${ot} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function ki({label:t,timestamp:e,source:n,note:s}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${s?o`<div class="planning-freshness-source">${s}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${ot} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Aa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${T} title="${Fo(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${u_} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function p_(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Ws.value===t?"active":""}"
            onClick=${()=>{Ws.value=t}}
          >
            ${t==="all"?"All":Fo(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Bs.value===t?"active":""}"
            onClick=${()=>{Bs.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function m_(){const t=kn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${hs("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${hs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${hs("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function v_({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${me} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${yi(t.baseline_metric)}</span>
          <span>Current ${yi(t.current_metric)}</span>
          <span class=${bi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${bi(t)}
          </span>
          <span>Elapsed ${d_(t.elapsed_seconds)}</span>
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
  `}function Ca({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${ot} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function __(){const{todo:t,inProgress:e,done:n}=td.value;return o`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${Ca} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${Ca} key=${s.id} task=${s} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${Ca} key=${s.id} task=${s} />`)}
          ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function f_(){const t=r_.value,e=l_.value,n=e.filter(c=>c.status==="running").length,s=e.filter(c=>c.recoverable).length,a=kn.value.filter(c=>c.status==="active").length,i=ko.value,r=i==="idle"?"No loop running":i==="error"?Ss.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <${St} surfaceId="planning" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${mo.value.length}</div>
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

      <${T} title="Planning Surface" class="section" semanticId="planning.surface">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Planning refresh reads a dedicated projection so goals, loops, and backlog pressure stay in one surface.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${Je} disabled=${ze.value}>
              ${ze.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${oo} disabled=${je.value}>
              ${je.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Je(),oo()}}
              disabled=${ze.value||je.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${ki} label="Goals" timestamp=${Ji.value} source="/api/v1/dashboard/planning" />
          <${ki}
            label="MDAL loops"
            timestamp=${Vi.value}
            source="/api/v1/dashboard/planning"
            note=${r}
          />
        </div>
      <//>

      <${T} title="Goal Pipeline" class="section" semanticId="planning.goal_pipeline">
        <${m_} />
        <${p_} />
      <//>

      ${ze.value&&kn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:mo.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Aa} horizon="short" items=${t.short??[]} />
              <${Aa} horizon="mid" items=${t.mid??[]} />
              <${Aa} horizon="long" items=${t.long??[]} />
            `}

      <${T} title="MDAL Loops" class="section" semanticId="planning.mdal_loops">
        ${je.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?o`
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
                  ${e.map(c=>o`<${v_} key=${c.loop_id} loop=${c} />`)}
                </div>
              `}
      <//>

      <${__} />
    </div>
  `}const fn=f("debates"),Gs=f([]),Js=f([]),Vs=f(!1),gn=f(!1),jn=f(""),$n=f(""),Ys=f(null),Lt=f(null),vo=f(!1);async function ua(){Vs.value=!0,jn.value="";try{const t=await zl();Gs.value=Array.isArray(t.debates)?t.debates:[],Js.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){jn.value=t instanceof Error?t.message:"Failed to load governance state"}finally{Vs.value=!1}}yd(ua);async function xi(){const t=$n.value.trim();if(t){gn.value=!0;try{const e=await Tc(t);$n.value="",L(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await ua()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";L(n,"error")}finally{gn.value=!1}}}async function g_(t){Ys.value=t,Lt.value=null,vo.value=!0;try{Lt.value=await Ic(t)}catch(e){jn.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{vo.value=!1}}function $_(){return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${Gs.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${Js.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${fn.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function h_({debate:t}){const e=Ys.value===t.id;return o`
    <button class="council-row ${e?"selected":""}" onClick=${()=>g_(t.id)}>
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
  `}function y_({session:t}){return o`
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
  `}function b_(){const t=fn.value;return o`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{fn.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{fn.value="voting"}}>Voting</button>
    </div>
  `}function k_(){return o`
    <div>
      <${T} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${$n.value}
            onInput=${t=>{$n.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&xi()}}
            disabled=${gn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${xi}
            disabled=${gn.value||$n.value.trim()===""}
          >
            ${gn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ua} disabled=${Vs.value}>
            ${Vs.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${jn.value?o`<div class="council-error">${jn.value}</div>`:null}
      <//>

      <${T} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${Gs.value.length===0?o`<div class="empty-state">No debates yet</div>`:Gs.value.map(t=>o`<${h_} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${T} title=${Ys.value?`Debate Detail (${Ys.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${vo.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Lt.value?o`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${Lt.value.status}</span>
                  <span>Total arguments: ${Lt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${Lt.value.support_count}</span>
                  <span>Oppose: ${Lt.value.oppose_count}</span>
                  <span>Neutral: ${Lt.value.neutral_count}</span>
                </div>
                ${Lt.value.summary_text?o`<pre class="council-detail">${Lt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function x_(){return o`
    <${T} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${Js.value.length===0?o`<div class="empty-state">No active sessions</div>`:Js.value.map(t=>o`<${y_} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function S_(){return rt(()=>{ua()},[]),o`
    <div>
      <${St} surfaceId="governance" />
      <${$_} />
      <${b_} />
      ${fn.value==="debates"?o`<${k_} />`:o`<${x_} />`}
    </div>
  `}const Me=f(""),wa=f("ability_check"),Ta=f("10"),Ia=f("12"),os=f(""),is=f("idle"),oe=f(""),rs=f("keeper-late"),Na=f("player"),Ra=f(""),kt=f("idle"),Pa=f(null),ls=f(""),La=f(""),Ma=f("player"),Da=f(""),Ea=f(""),za=f(""),hn=f("20"),ja=f("20"),Oa=f(""),cs=f("idle"),_o=f(null),Vr=f("overview"),Fa=f("all"),qa=f("all"),Ka=f("all"),A_=12e4,pa=f(null),Si=f(Date.now());function C_(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function w_(t,e){return e>0?Math.round(t/e*100):0}const T_={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},I_={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ds(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function N_(t){const e=t.trim().toLowerCase();return T_[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function R_(t){const e=t.trim().toLowerCase();return I_[e]??"상황에 따라 선택되는 전술 액션입니다."}function ce(t){return typeof t=="object"&&t!==null}function ht(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Mt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function On(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const P_=new Set(["str","dex","con","int","wis","cha"]);function L_(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!ce(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function M_(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(hn.value.trim(),10);Number.isFinite(s)&&s>n&&(hn.value=String(n))}function fo(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function D_(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function E_(t){Vr.value=t}function Yr(t){const e=pa.value;return e==null||e<=t}function z_(t){const e=pa.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Xs(){pa.value=null}function Xr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function j_(t,e){Xr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(pa.value=Date.now()+A_,L("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ys(t){return Yr(t)?(L("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function go(t,e,n){return Xr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function O_({hp:t,max:e}){const n=w_(t,e),s=C_(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function F_({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function q_({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Qr({actor:t}){var d,m,u,p;const e=(d=t.archetype)==null?void 0:d.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(p=t.background)==null?void 0:p.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([v,$])=>Number.isFinite($)).filter(([v])=>!P_.has(v.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${v=>{const $=v.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${me} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${q_} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${O_} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${F_} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${ds(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([v,$])=>o`
                <span class="trpg-custom-stat-chip">${ds(v)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(v=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${ds(v)}</span>
                  <span class="trpg-annot-desc">${N_(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(v=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${ds(v)}</span>
                  <span class="trpg-annot-desc">${R_(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function K_({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Zr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${D_(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${fo(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${ot} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function U_({events:t}){const e="__none__",n=Fa.value,s=qa.value,a=Ka.value,i=Array.from(new Set(t.map(fo).map(p=>p.trim()).filter(p=>p!==""))).sort((p,v)=>p.localeCompare(v)),r=Array.from(new Set(t.map(p=>(p.type??"").trim()).filter(p=>p!==""))).sort((p,v)=>p.localeCompare(v)),c=t.some(p=>(p.type??"").trim()===""),d=Array.from(new Set(t.map(p=>(p.phase??"").trim()).filter(p=>p!==""))).sort((p,v)=>p.localeCompare(v)),m=t.some(p=>(p.phase??"").trim()===""),u=t.filter(p=>{if(n!=="all"&&fo(p)!==n)return!1;const v=(p.type??"").trim(),$=(p.phase??"").trim();if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${p=>{Fa.value=p.target.value}}>
          <option value="all">all</option>
          ${i.map(p=>o`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${p=>{qa.value=p.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(p=>o`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${p=>{Ka.value=p.target.value}}>
          <option value="all">all</option>
          ${m?o`<option value=${e}>(none)</option>`:null}
          ${d.map(p=>o`<option value=${p}>${p}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Fa.value="all",qa.value="all",Ka.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Zr} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function H_({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function tl({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function W_({state:t,nowMs:e}){var m;const n=Vt.value||((m=t.session)==null?void 0:m.room)||"",s=is.value,a=t.party??[];if(!a.find(u=>u.id===Me.value)&&a.length>0){const u=a[0];u&&(Me.value=u.id)}const r=async()=>{var p,v;if(!n){L("Room ID가 비어 있습니다.","error");return}if(!ys(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(go("라운드 실행",n,u)){is.value="running";try{const $=await gc(n);_o.value=$,is.value="ok";const x=ce($.summary)?$.summary:null,b=x?On(x,"advanced",!1):!1,A=x?ht(x,"progress_reason",""):"";L(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${A?`: ${A}`:""}`,b?"success":"warning"),qt()}catch($){_o.value=null,is.value="error";const x=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";L(x,"error")}finally{Xs()}}},c=async()=>{var p,v;if(!n||!ys(e))return;const u=((p=t.current_round)==null?void 0:p.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(go("턴 강제 진행",n,u))try{await yc(n),L("턴을 다음 단계로 이동했습니다.","success"),qt()}catch{L("턴 이동에 실패했습니다.","error")}finally{Xs()}},d=async()=>{if(!n||!ys(e))return;const u=Me.value.trim();if(!u){L("먼저 Actor를 선택하세요.","warning");return}const p=Number.parseInt(Ta.value,10),v=Number.parseInt(Ia.value,10);if(Number.isNaN(p)||Number.isNaN(v)){L("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(os.value,10),x=os.value.trim()===""||Number.isNaN($)?void 0:$;try{await hc({roomId:n,actorId:u,action:wa.value.trim()||"ability_check",statValue:p,dc:v,rawD20:x}),L("주사위 판정을 기록했습니다.","success"),qt()}catch{L("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Vt.value=u.target.value}}
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
            ${a.map(u=>o`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${wa.value}
              onInput=${u=>{wa.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ta.value}
              onInput=${u=>{Ta.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ia.value}
              onInput=${u=>{Ia.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${os.value}
              onInput=${u=>{os.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function B_({state:t}){var a;const e=Vt.value||((a=t.session)==null?void 0:a.room)||"",n=cs.value,s=async()=>{if(!e){L("Room ID가 비어 있습니다.","warning");return}const i=ls.value.trim(),r=La.value.trim();if(!r&&!i){L("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(hn.value.trim(),10),d=Number.parseInt(ja.value.trim(),10),m=Number.isFinite(d)?Math.max(1,d):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let p={};try{p=L_(Oa.value)}catch(v){L(v instanceof Error?v.message:"능력치 JSON 오류","error");return}cs.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await bc(e,{actor_id:i||void 0,name:r||void 0,role:Ma.value,idempotencyKey:v,portrait:Ea.value.trim()||void 0,background:za.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(p).length>0?p:void 0}),x=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Da.value.trim();b&&await kc(e,x,b),Me.value=x,oe.value=x,i||(ls.value=""),cs.value="ok",L(`Actor 생성 완료: ${x}`,"success"),await qt()}catch(v){cs.value="error",L(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${La.value}
            onInput=${i=>{La.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ma.value}
            onChange=${i=>{Ma.value=i.target.value}}
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
            value=${Da.value}
            onInput=${i=>{Da.value=i.target.value}}
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
              value=${ls.value}
              onInput=${i=>{ls.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ea.value}
              onInput=${i=>{Ea.value=i.target.value}}
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
              onInput=${i=>{hn.value=i.target.value}}
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
              value=${ja.value}
              onInput=${i=>{const r=i.target.value;ja.value=r,M_(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${za.value}
              onInput=${i=>{za.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Oa.value}
              onInput=${i=>{Oa.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function G_({state:t,nowMs:e}){var v;const n=Vt.value||((v=t.session)==null?void 0:v.room)||"",s=t.join_gate,a=Pa.value,i=ce(a)?a:null,r=(t.party??[]).filter($=>$.role!=="dm"),c=oe.value.trim(),d=r.some($=>$.id===c),m=d?c:c?"__manual__":"",u=async()=>{const $=oe.value.trim(),x=rs.value.trim();if(!n||!$){L("Room/Actor가 필요합니다.","warning");return}kt.value="checking";try{const b=await xc(n,$,x||void 0);Pa.value=b,kt.value="ok",L("참가 가능 여부를 갱신했습니다.","success")}catch(b){kt.value="error";const A=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";L(A,"error")}},p=async()=>{var I,z;const $=oe.value.trim(),x=rs.value.trim(),b=Ra.value.trim();if(!n||!$||!x){L("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ys(e))return;const A=((I=t.current_round)==null?void 0:I.phase)??((z=t.session)==null?void 0:z.status)??"unknown";if(go("Mid-Join 승인 요청",n,A)){kt.value="requesting";try{const E=await Sc({room_id:n,actor_id:$,keeper_name:x,role:Na.value,...b?{name:b}:{}});Pa.value=E;const N=ce(E)?On(E,"granted",!1):!1,R=ce(E)?ht(E,"reason_code",""):"";N?L("Mid-Join이 승인되었습니다.","success"):L(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),kt.value=N?"ok":"error",qt()}catch(E){kt.value="error";const N=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";L(N,"error")}finally{Xs()}}};return o`
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
            value=${m}
            onChange=${$=>{const x=$.target.value;if(x==="__manual__"){(d||!c)&&(oe.value="");return}oe.value=x}}
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
                value=${oe.value}
                onInput=${$=>{oe.value=$.target.value}}
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
            value=${rs.value}
            onInput=${$=>{rs.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Na.value}
            onChange=${$=>{Na.value=$.target.value}}
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
            value=${Ra.value}
            onInput=${$=>{Ra.value=$.target.value}}
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
            Eligible: <strong>${On(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Mt(i,"effective_score",0)}/${Mt(i,"required_points",0)}</span>
            ${ht(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ht(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function el({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function nl({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function sl(){const t=_o.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ce(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(ce).slice(-8),i=t.canon_check,r=ce(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],m=n?On(n,"advanced",!1):!1,u=n?ht(n,"progress_reason",""):"",p=n?ht(n,"progress_detail",""):"",v=n?Mt(n,"player_successes",0):0,$=n?Mt(n,"player_required_successes",0):0,x=n?On(n,"dm_success",!1):!1,b=n?Mt(n,"timeouts",0):0,A=n?Mt(n,"unavailable",0):0,I=n?Mt(n,"reprompts",0):0,z=n?Mt(n,"npc_attacks",0):0,E=n?Mt(n,"keeper_timeout_sec",0):0,N=n?Mt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${x?"DM ok":"DM stalled"} / players ${v}/${$}
          </span>
        </div>
        ${u?o`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${p?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${p}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${z}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${N}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(R=>{const Y=ht(R,"status","unknown"),G=ht(R,"actor_id","-"),_=ht(R,"role","-"),F=ht(R,"reason",""),tt=ht(R,"action_type",""),W=ht(R,"reply","");return o`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${G} (${_})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
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
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(R=>o`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(R=>o`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function J_({state:t,nowMs:e}){var r,c,d;const n=Vt.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=Yr(e),i=z_(e);return o`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>j_(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Xs(),L("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function V_({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>E_(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Y_({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${Zr} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${K_} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${nl} state=${t} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${el} state=${t} />
        <//>

        <${T} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Qr} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${tl} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function X_({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${e.length})`}>
          <${U_} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${sl} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${nl} state=${t} />
        <//>
      </div>
    </div>
  `}function Q_({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${J_} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${W_} state=${t} nowMs=${e} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${B_} state=${t} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${G_} state=${t} nowMs=${e} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${sl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${el} state=${t} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Qr} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${T} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${tl} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Z_(){var c,d,m,u,p;const t=Wi.value,e=no.value;if(rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{Si.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>qt()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=Vr.value,r=Si.value;return o`
    <div>
      <${St} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Vt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>qt()}>새로고침</button>
      </div>

      <${H_} outcome=${a} />

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
          <div class="stat-value">${s.length}</div>
        </div>
      </div>

      <${V_} active=${i} />

      ${i==="overview"?o`<${Y_} state=${t} />`:i==="timeline"?o`<${X_} state=${t} />`:o`<${Q_} state=${t} nowMs=${r} />`}
    </div>
  `}function tf(){return o`
    <div>
      <${St} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${Z_} />
      <//>
    </div>
  `}const Qs=f(new Set(["broadcast","tasks","keepers","system"]));function ef(t){const e=new Set(Qs.value);e.has(t)?e.delete(t):e.add(t),Qs.value=e}const qo=f(null);function al(t){qo.value=t}function nf(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const sf=Nt(()=>{const t=Qs.value;return ks.value.filter(e=>t.has(nf(e)))}),af=12e4,of=Nt(()=>{const t=na.value,e=Date.now();return Ct.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const r=a==null?void 0:a.lastActivityAt;r?i=e-new Date(r).getTime()>af?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),rf=Nt(()=>{const t=na.value;return Ct.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function Ai(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function lf(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function cf(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function df(){const t=of.value,e=qo.value;return t.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${t.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${cf(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>al(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const uf=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function pf(){const t=Qs.value;return o`
    <div class="activity-filter-bar">
      ${uf.map(e=>o`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>ef(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function mf(){const t=sf.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${pf} />
      <div class="activity-stream-list">
        ${t.length===0?o`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>o`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${Ai(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Ai(e)}">${lf(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${tr(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function vf(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function _f(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function ff(){const t=rf.value,e=qo.value;return o`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${t.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${t.length===0?o`<div class="focus-empty">No active agents</div>`:t.map(n=>o`
            <div
              key=${n.name}
              class="focus-agent-card ${e===n.name?"focus-agent-selected":""}"
              onClick=${()=>al(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${vf(n.pressure)}">
                  ${_f(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${ot} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function gf(){const t=de.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"Connected":"Offline"}
          </span>
          <span class="live-stat">${Ct.value.length} agents</span>
          <span class="live-stat">${Zs.value} events</span>
        </div>
      </div>

      <${df} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${mf} />
        </div>
        <div class="live-panel-side">
          <${ff} />
        </div>
      </div>
    </div>
  `}const Ci=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],$o=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function $f(){const t=de.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Zs.value} events</span>
    </div>
  `}function hf({currentTab:t,currentSectionLabel:e}){const n=de.value;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${D} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${Ct.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${te.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Ot.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Zs.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{qn(),Qi(),t==="command"&&(Ae(),ie(),(V.value==="swarm"||V.value==="warroom")&&Jt(),V.value==="warroom"&&ut()),t==="mission"&&_s(),t==="execution"&&Bt(),t==="intervene"&&(ut(),Qt()),t==="memory"&&Ft(),t==="planning"&&Je(),t==="lab"&&qt()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>gt("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function yf(){const t=Kt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
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
          <strong>${s}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ut(),Qt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>gt("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function bf(){const t=O.value.tab,e=$o.find(s=>s.id===t),n=Ci.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${St} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${D} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Ci.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${$o.filter(a=>a.group===s.id).map(a=>o`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>gt(a.id)}
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

      <${hf} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${yf} />
    </aside>
  `}function kf(){switch(O.value.tab){case"mission":return o`<${ii} />`;case"execution":return o`<${i_} />`;case"live":return o`<${gf} />`;case"memory":return o`<${Vv} />`;case"governance":return o`<${S_} />`;case"planning":return o`<${f_} />`;case"intervene":return o`<${Ev} />`;case"command":return o`<${hv} />`;case"lab":return o`<${tf} />`;default:return o`<${ii} />`}}function xf(){rt(()=>{fl(),Mi(),Zi(),Bt(),Qi(),_s();const n=xd();return Sd(),()=>{Sl(),n(),Ad()}},[]),rt(()=>{const n=setInterval(()=>{const s=O.value.tab;s==="command"?(Ae(),ie(),(V.value==="swarm"||V.value==="warroom")&&Jt(),V.value==="warroom"&&ut()):s==="mission"?_s():s==="execution"?Bt():s==="intervene"?(ut(),Qt()):s==="memory"?Ft():s==="planning"?Je():s==="lab"&&qt()},15e3);return()=>{clearInterval(n)}},[]),rt(()=>{const n=O.value.tab;n==="command"&&(Ae(),ie(),(V.value==="swarm"||V.value==="warroom")&&Jt(),V.value==="warroom"&&ut()),n==="mission"&&_s(),n==="execution"&&Bt(),n==="intervene"&&(ut(),Qt()),n==="memory"&&Ft(),n==="planning"&&Je(),n==="lab"&&qt()},[O.value.tab]);const t=O.value.tab,e=$o.find(n=>n.id===t);return o`
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
          <${$f} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${bf} />
        <main class="dashboard-main">
          ${eo.value&&!de.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${kf} />`}
        </main>
      </div>

      <${Au} />
      <${Wd} />
      <${Od} />
    </div>
  `}const wi=document.getElementById("app");wi&&ul(o`<${xf} />`,wi);export{mp as _};
