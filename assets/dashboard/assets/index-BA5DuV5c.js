var lr=Object.defineProperty;var cr=(t,e,n)=>e in t?lr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var de=(t,e,n)=>cr(t,typeof e!="symbol"?e+"":e,n);import{e as dr,_ as ur,c as v,b as Vt,y as ut,A as pr,d as Oo,G as mr}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const o of document.querySelectorAll('link[rel="modulepreload"]'))a(o);new MutationObserver(o=>{for(const i of o)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(o){const i={};return o.integrity&&(i.integrity=o.integrity),o.referrerPolicy&&(i.referrerPolicy=o.referrerPolicy),o.crossOrigin==="use-credentials"?i.credentials="include":o.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(o){if(o.ep)return;o.ep=!0;const i=n(o);fetch(o.href,i)}})();var s=dr.bind(ur);const vr=["mission","execution","memory","governance","planning","intervene","command","lab"],jo={tab:"mission",params:{},postId:null};function no(t){return!!t&&vr.includes(t)}function ss(t){try{return decodeURIComponent(t)}catch{return t}}function os(t){const e={};return t&&new URLSearchParams(t).forEach((a,o)=>{e[o]=a}),e}function _r(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Fo(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=ss(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=ss(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],a=e.tab;return{tab:no(n)?n:no(a)?a:"mission",params:e,postId:null}}function zn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return jo;const n=ss(e);let a=n,o;if(n.startsWith("?"))a="",o=n.slice(1);else{const c=n.indexOf("?");c>=0&&(a=n.slice(0,c),o=n.slice(c+1))}!o&&a.includes("=")&&!a.includes("/")&&(o=a,a="");const i=os(o),r=_r(a);return Fo(r,i)}function fr(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...jo,params:os(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const o=os(e.replace(/^\?/,""));return Fo(a,o)}function qo(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([o])=>!(o==="tab"||t.tab==="lab"&&o==="surface"));if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Q=v(zn(window.location.hash));window.addEventListener("hashchange",()=>{Q.value=zn(window.location.hash)});function et(t,e){const n={tab:t,params:e??{}};window.location.hash=qo(n)}function gr(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function $r(){if(window.location.hash&&window.location.hash!=="#"){Q.value=zn(window.location.hash);return}const t=fr(window.location.pathname,window.location.search);if(t){Q.value=t;const e=qo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",Q.value=zn(window.location.hash)}const ao="masc_dashboard_sse_session_id",hr=1e3,yr=15e3,le=v(!1),Os=v(0),Ko=v(null),is=v([]);function br(){let t=sessionStorage.getItem(ao);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ao,t)),t}const kr=200;function xr(t,e,n="system",a={}){const o={agent:t,text:e,timestamp:Date.now(),kind:n,...a};is.value=[o,...is.value].slice(0,kr)}function rs(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function so(t,e){const n=rs(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function ht(t,e,n,a,o={}){xr(t,e,n,{eventType:a,...o})}let xt=null,he=null,ls=0;function Uo(){he&&(clearTimeout(he),he=null)}function Sr(){if(he)return;ls++;const t=Math.min(ls,5),e=Math.min(yr,hr*Math.pow(2,t));he=setTimeout(()=>{he=null,Ho()},e)}function Ho(){Uo(),xt&&(xt.close(),xt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",br());const o=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(o);xt=i,i.onopen=()=>{xt===i&&(ls=0,le.value=!0)},i.onerror=()=>{xt===i&&(le.value=!1,i.close(),xt=null,Sr())},i.onmessage=r=>{try{const c=JSON.parse(r.data);Os.value++,Ko.value=c,Ar(c)}catch{}}}function Ar(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":ht(n,"Joined","system","agent_joined");break;case"agent_left":ht(n,"Left","system","agent_left");break;case"broadcast":ht(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ht(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ht(n,so("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:rs(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":ht(n,so("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:rs(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":ht(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ht(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ht(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ht(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ht(n,e,"system","unknown")}}function Cr(){Uo(),xt&&(xt.close(),xt=null),le.value=!1}function Wo(){return new URLSearchParams(window.location.search)}function Bo(){const t=Wo(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Go(){return{...Bo(),"Content-Type":"application/json"}}const wr=15e3,js=3e4,Ir=6e4,oo=new Set([408,425,429,500,502,503,504]);class ln extends Error{constructor(n){const a=n.method.toUpperCase(),o=n.timeout===!0,i=o?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);de(this,"method");de(this,"path");de(this,"status");de(this,"statusText");de(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=o}}async function Fs(t,e,n){const a=new AbortController,o=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new ln({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(o)}}function Tr(){var e,n;const t=Wo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function tt(t){const e=await Fs(t,{headers:Bo()},wr);if(!e.ok)throw new ln({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Rr(t){return new Promise(e=>setTimeout(e,t))}function Nr(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Pr(t){if(t instanceof ln)return t.timeout||typeof t.status=="number"&&oo.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Nr(t.message);return e!==null&&oo.has(e)}async function Jo(t,e,n=2){let a=0;for(;;)try{return await e()}catch(o){if(!Pr(o)||a>=n)throw o;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,o),await Rr(i),a+=1}}async function wt(t,e,n,a=js){const o=await Fs(t,{method:"POST",headers:{...Go(),...n??{}},body:JSON.stringify(e)},a);if(!o.ok)throw new ln({method:"POST",path:t,status:o.status,statusText:o.statusText});return o.json()}async function Dr(t,e,n,a=js){const o=await Fs(t,{method:"POST",headers:{...Go(),...n??{}},body:JSON.stringify(e)},a);if(!o.ok)throw new ln({method:"POST",path:t,status:o.status,statusText:o.statusText});return o.text()}function Mr(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Lr(t){var e,n,a,o,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((o=(a=t.result.content)==null?void 0:a[0])==null?void 0:o.text)??"MCP tool call failed";throw new Error(u)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function zt(t,e){const n=await Dr("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ir),a=Mr(n);return Lr(a)}function Er(){return tt("/api/v1/dashboard/shell")}function zr(){return tt("/api/v1/dashboard/execution")}function Or(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),tt(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function jr(){return tt("/api/v1/dashboard/governance")}function Fr(){return tt("/api/v1/dashboard/semantics")}function qr(){return tt("/api/v1/dashboard/mission")}function Kr(){return tt("/api/v1/dashboard/planning")}function Ur(){return tt("/api/v1/operator")}function Vo(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return tt(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Hr(){return tt("/api/v1/command-plane")}function Wr(){return tt("/api/v1/command-plane/summary")}function Br(){return tt("/api/v1/chains/summary")}function Gr(t){return tt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Jr(){return tt("/api/v1/command-plane/help")}function Vr(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const a=n.toString();return tt(`/api/v1/command-plane/swarm${a?`?${a}`:""}`)}function Yr(t,e){return wt(t,e)}function Xr(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"lodge_tick":return 45e3;default:return js}}function fa(t){return wt("/api/v1/operator/action",t,void 0,Xr(t))}function Qr(t,e){return wt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}function On(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function Zr(t){var o;const e=t.trim(),a=((o=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:o.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function tl(t){if(!j(t))return null;const e=h(t.id,"").trim(),n=h(t.author,"").trim(),a=h(t.content,"").trim();if(!e||!n)return null;const o=K(t.score,0),i=K(t.votes_up,0),r=K(t.votes_down,0),c=K(t.votes,o||i-r),u=K(t.comment_count,K(t.reply_count,0)),f=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(j(x)){const I=h(x.name,"").trim();if(I)return I}return h(t.flair_name,"").trim()||void 0})(),d=h(t.created_at_iso,"").trim()||On(t.created_at),_=h(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?On(t.updated_at):d),$=h(t.title,"").trim()||Zr(a);return{id:e,author:n,title:$,content:a,tags:[],votes:c,vote_balance:o,comment_count:u,created_at:d,updated_at:_,flair:f,hearth_count:K(t.hearth_count,0)}}function el(t){if(!j(t))return null;const e=h(t.id,"").trim(),n=h(t.post_id,"").trim(),a=h(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:h(t.content,""),created_at:On(t.created_at)}}async function nl(t){return Jo("fetchBoardPost",async()=>{const e=await tt(`/api/v1/board/${t}?format=flat`),n=j(e.post)?e.post:e,a=tl(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(el).filter(r=>r!==null);return{...a,comments:i}})}function Yo(t,e){return wt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Tr()})}function al(t,e,n){return wt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function sl(t){const e=h(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function it(...t){for(const e of t){const n=h(e,"");if(n.trim())return n.trim()}return""}function io(t){const e=sl(it(t.outcome,t.result,t.result_code));if(!e)return;const n=it(t.reason,t.reason_code,t.description,t.detail),a=it(t.summary,t.summary_ko,t.summary_en,t.note),o=it(t.details,t.details_text,t.text,t.note),i=it(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=it(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=it(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const _=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof _=="string"?[_]:Array.isArray(_)?_.map(g=>{if(typeof g=="string")return g.trim();if(j(g)){const $=h(g.summary,"").trim();if($)return $;const x=h(g.text,"").trim();if(x)return x;const C=h(g.type,"").trim();return C||h(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),f=(()=>{const _=K(t.turn,Number.NaN);if(Number.isFinite(_))return _;const g=K(t.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=K(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const x=K(t.round,Number.NaN);return Number.isFinite(x)?x:void 0})(),d=it(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:o||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:f,phase:d||void 0}}function ol(t,e){const n=j(t.state)?t.state:{};if(h(n.status,"active").toLowerCase()!=="ended")return;const o=[...e].reverse().find(r=>j(r)?h(r.type,"")==="session.outcome":!1),i=j(n.session_outcome)?n.session_outcome:{};if(j(i)&&Object.keys(i).length>0){const r=io(i);if(r)return r}if(j(o))return io(j(o.payload)?o.payload:{})}function j(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function K(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function il(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function cs(t,e=!1){return typeof t=="boolean"?t:e}function Ne(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(j(e)){const n=h(e.name,"").trim(),a=h(e.id,"").trim(),o=h(e.skill,"").trim();return n||a||o}return""}).filter(e=>e.length>0):[]}function rl(t){const e={};if(!j(t)&&!Array.isArray(t))return e;if(j(t))return Object.entries(t).forEach(([n,a])=>{const o=n.trim(),i=h(a,"").trim();!o||!i||(e[o]=i)}),e;for(const n of t){if(!j(n))continue;const a=it(n.to,n.target,n.actor_id,n.name,n.id),o=it(n.relationship,n.relation,n.type,n.kind);!a||!o||(e[a]=o)}return e}function ll(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ft(t,e,n,a=0){const o=t[e];if(typeof o=="number"&&Number.isFinite(o))return o;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const cl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function dl(t){const e=j(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,o])=>{const i=a.trim();i&&(cl.has(i.toLowerCase())||typeof o=="number"&&Number.isFinite(o)&&(n[i]=o))}),n}function ul(t,e){if(t!=="dice.rolled")return;const n=K(e.raw_d20,0),a=K(e.total,0),o=K(e.bonus,0),i=h(e.action,"roll"),r=K(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:o}}function pl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ml(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function vl(t,e,n,a){const o=n||e||h(a.actor_id,"")||h(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=h(a.proposed_action,h(a.reply,""));return i?`${o||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=h(a.reply,h(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return h(a.reply,h(a.content,h(a.text,"Narration")));case"dice.rolled":{const i=h(a.action,"roll"),r=K(a.total,0),c=K(a.dc,0),u=h(a.label,""),f=o||"actor",d=c>0?` vs DC ${c}`:"",_=u?` (${u})`:"";return`${f} ${i}: ${r}${d}${_}`}case"turn.started":return`Turn ${K(a.turn,1)} started`;case"phase.changed":return`Phase: ${h(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(a.name,j(a.actor)?h(a.actor.name,o||"unknown"):o||"unknown")}`;case"actor.claimed":return`${h(a.keeper_name,h(a.keeper,"keeper"))} claimed ${o||"actor"}`;case"actor.released":return`${h(a.keeper_name,h(a.keeper,"keeper"))} released ${o||"actor"}`;case"join.window.opened":return`Join window opened (turn ${K(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${K(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${o||h(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${o||h(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${h(a.reason_code,"unknown")}`;case"memory.signal":{const i=j(a.entity_refs)?a.entity_refs:{},r=h(i.requested_tier,""),c=h(i.effective_tier,""),u=cs(i.guardrail_applied,!1),f=h(a.summary_en,h(a.summary_ko,"Memory signal"));if(!r&&!c)return f;const d=r&&c?`${r}->${c}`:c||r;return`${f} [${d}${u?" (guardrail)":""}]`}case"world.event":{if(h(a.event_type,"")==="canon.check"){const r=h(a.status,"unknown"),c=h(a.contract_id,"n/a");return`Canon ${r}: ${c}`}return h(a.description,h(a.summary,"World event"))}case"combat.attack":return h(a.summary,h(a.result,"Attack resolved"));case"combat.defense":return h(a.summary,h(a.result,"Defense resolved"));case"session.outcome":return h(a.summary,h(a.outcome,"Session ended"));default:{const i=pl(a);return i?`${t}: ${i}`:t}}}function _l(t,e){const n=j(t)?t:{},a=h(n.type,"event"),o=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=h(n.actor_name,"").trim()||e[o]||h(j(n.payload)?n.payload.actor_name:"",""),r=j(n.payload)?n.payload:{},c=h(n.ts,h(n.timestamp,new Date().toISOString())),u=h(n.phase,h(r.phase,"")),f=h(n.category,"");return{type:a,actor:i||o||h(r.actor_name,""),actor_id:o||h(r.actor_id,""),actor_name:i,seq:n.seq,room_id:h(n.room_id,""),phase:u||void 0,category:f||ml(a),visibility:h(n.visibility,h(r.visibility,"public")),event_id:h(n.event_id,""),content:vl(a,o,i,r),dice_roll:ul(a,r),timestamp:c}}function fl(t,e,n){var ct,dt;const a=h(t.room_id,"")||n||"default",o=j(t.state)?t.state:{},i=j(o.party)?o.party:{},r=j(o.actor_control)?o.actor_control:{},c=j(o.join_gate)?o.join_gate:{},u=j(o.contribution_ledger)?o.contribution_ledger:{},f=Object.entries(i).map(([H,X])=>{const b=j(X)?X:{},Qt=ft(b,"max_hp",void 0,10),Re=ft(b,"hp",void 0,Qt),pn=ft(b,"max_mp",void 0,0),mn=ft(b,"mp",void 0,0),E=ft(b,"level",void 0,1),Zt=ft(b,"xp",void 0,0),vn=cs(b.alive,Re>0),to=r[H],eo=typeof to=="string"?to:void 0,er=ll(b.role,H,eo),nr=il(b.generation),ar=it(b.joined_at,b.joinedAt,b.started_at,b.startedAt),sr=it(b.claimed_at,b.claimedAt,b.assigned_at,b.assignedAt,b.assigned_time),or=it(b.last_seen,b.lastSeen,b.last_seen_at,b.lastSeenAt,b.last_active,b.lastActive),ir=it(b.scene,b.current_scene,b.currentScene,b.world_scene,b.scene_name,b.sceneName),rr=it(b.location,b.current_location,b.currentLocation,b.position,b.zone,b.area);return{id:H,name:h(b.name,H),role:er,keeper:eo,archetype:h(b.archetype,""),persona:h(b.persona,""),portrait:h(b.portrait,"")||void 0,background:h(b.background,"")||void 0,traits:Ne(b.traits),skills:Ne(b.skills),stats_raw:dl(b),status:vn?"active":"dead",generation:nr,joined_at:ar||void 0,claimed_at:sr||void 0,last_seen:or||void 0,scene:ir||void 0,location:rr||void 0,inventory:Ne(b.inventory),notes:Ne(b.notes),relationships:rl(b.relationships),stats:{hp:Re,max_hp:Qt,mp:mn,max_mp:pn,level:E,xp:Zt,strength:ft(b,"strength","str",10),dexterity:ft(b,"dexterity","dex",10),constitution:ft(b,"constitution","con",10),intelligence:ft(b,"intelligence","int",10),wisdom:ft(b,"wisdom","wis",10),charisma:ft(b,"charisma","cha",10)}}}),d=f.filter(H=>H.status!=="dead"),_=ol(t,e),g={phase_open:cs(c.phase_open,!0),min_points:K(c.min_points,3),window:h(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(u).map(([H,X])=>{const b=j(X)?X:{};return{actor_id:H,score:K(b.score,0),last_reason:h(b.last_reason,"")||null,reasons:Ne(b.reasons)}}),x=f.reduce((H,X)=>(H[X.id]=X.name,H),{}),C=e.map(H=>_l(H,x)),I=K(o.turn,1),L=h(o.phase,"round"),q=h(o.map,""),D=j(o.world)?o.world:{},T=q||h(D.ascii_map,h(D.map,"")),N=C.filter((H,X)=>{const b=e[X];if(!j(b))return!1;const Qt=j(b.payload)?b.payload:{};return K(Qt.turn,-1)===I}),p=(N.length>0?N:C).slice(-12),M=h(o.status,"active");return{session:{id:a,room:a,status:M==="ended"?"ended":M==="paused"?"paused":"active",round:I,actors:d,created_at:((ct=C[0])==null?void 0:ct.timestamp)??new Date().toISOString()},current_round:{round_number:I,phase:L,events:p,timestamp:((dt=C[C.length-1])==null?void 0:dt.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:g,contribution_ledger:$,outcome:_,party:d,story_log:C,history:[]}}async function gl(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await tt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function $l(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([tt(`/api/v1/trpg/state${e}`),gl(t)]);return fl(n,a,t)}function hl(t){return wt("/api/v1/trpg/rounds/run",{room_id:t})}function yl(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function bl(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),wt("/api/v1/trpg/dice/roll",e)}function kl(t,e){const n=yl();return wt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function xl(t,e){var o;const n=(o=e.idempotencyKey)==null?void 0:o.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),wt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Sl(t,e,n){return wt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Al(t,e,n){const a=await zt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Cl(t){const e=await zt("trpg.mid_join.request",t);return JSON.parse(e)}async function wl(t,e){await zt("masc_broadcast",{agent_name:t,message:e})}async function Il(t,e,n=1){await zt("masc_add_task",{title:t,description:e,priority:n})}async function Tl(t=40){return(await zt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Rl(t,e=20){return zt("masc_task_history",{task_id:t,limit:e})}async function Nl(t){const e=await zt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Pl(t){return Jo("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await tt(`/api/v1/council/debates/${e}/summary`);if(!j(n))return null;const a=h(n.id,"").trim();return a?{id:a,topic:h(n.topic,""),status:h(n.status,"open"),support_count:K(n.support_count,0),oppose_count:K(n.oppose_count,0),neutral_count:K(n.neutral_count,0),total_arguments:K(n.total_arguments,0),created_at:On(n.created_at_iso??n.created_at),summary_text:h(n.summary_text,"")}:null})}function Dl(t,e,n){return zt("masc_keeper_msg",{name:t,message:e})}const Ml=v(""),Dt=v({}),rt=v({}),ds=v({}),us=v({}),ps=v({}),ms=v({}),Mt=v({});function st(t,e,n){t.value={...t.value,[e]:n}}function Ot(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function U(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function yt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function _e(t){return typeof t=="boolean"?t:void 0}function vs(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function _s(t){return Array.isArray(t)?t.map(e=>U(e)).filter(e=>!!e):[]}function Ll(t){var n;const e=(n=U(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function El(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ra(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!Ot(a))continue;const o=U(a.name);if(!o)continue;const i=U(a[e]);e==="summary"?n.push({name:o,summary:i}):n.push({name:o,reason:i})}return n}function zl(t){if(!Ot(t))return null;const e=U(t.name);return e?{name:e,trigger:U(t.trigger),outcome:U(t.outcome),summary:U(t.summary),reason:U(t.reason)}:null}function Ol(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function jl(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Xo(t,e,n){return U(t)??jl(e,n)}function Qo(t,e){return typeof t=="boolean"?t:e==="recover"}function jn(t){if(!Ot(t))return null;const e=U(t.health_state),n=U(t.next_action_path),a=U(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:U(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:vs(t.last_reply_at),last_reply_preview:U(t.last_reply_preview)??null,last_error:U(t.last_error)??null,next_eligible_at_s:yt(t.next_eligible_at_s)??null,recoverable:Qo(t.recoverable,n),summary:Xo(t.summary,e,U(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Zo(t){return Ot(t)?{hour:yt(t.hour),checked:yt(t.checked)??0,acted:yt(t.acted)??0,acted_names:_s(t.acted_names),activity_report:U(t.activity_report),quiet_hours_overridden:_e(t.quiet_hours_overridden),skipped_reason:U(t.skipped_reason),acted_rows:Ra(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Ra(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Ra(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(zl).filter(e=>e!==null):[]}:null}function Fl(t){return Ot(t)?{enabled:_e(t.enabled)??!1,interval_s:yt(t.interval_s)??0,quiet_start:yt(t.quiet_start),quiet_end:yt(t.quiet_end),quiet_active:_e(t.quiet_active),use_planner:_e(t.use_planner),delegate_llm:_e(t.delegate_llm),agent_count:yt(t.agent_count),agents:_s(t.agents),last_tick_ago_s:yt(t.last_tick_ago_s)??null,last_tick_ago:U(t.last_tick_ago),total_ticks:yt(t.total_ticks),total_checkins:yt(t.total_checkins),last_skip_reason:U(t.last_skip_reason)??null,last_tick_result:Zo(t.last_tick_result),active_self_heartbeats:_s(t.active_self_heartbeats)}:null}function ql(t){return Ot(t)?{status:t.status,diagnostic:jn(t.diagnostic)}:null}function Kl(t){return Ot(t)?{recovered:_e(t.recovered)??!1,skipped_reason:U(t.skipped_reason)??null,before:jn(t.before),after:jn(t.after),down:t.down,up:t.up}:null}function Ul(t,e){var q,D;if(!(t!=null&&t.name))return null;const n=U((q=t.agent)==null?void 0:q.status)??U(t.status)??"unknown",a=U((D=t.agent)==null?void 0:D.error)??null,o=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,c=t.last_turn_ago_s??null,u=t.proactive_enabled??!1,f=t.proactive_cooldown_sec??0,d=t.last_proactive_ago_s??null,_=u&&d!=null?Math.max(0,f-d):null,g=r<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,x=a??(o&&!i?"keeper keepalive is not running":null),C=n==="offline"||n==="inactive"?"offline":x?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",I=x?Ol(x):e!=null&&e.quiet_active&&g!=="fresh"?"quiet_hours":o&&!i?"disabled":r<=0?"never_started":_!=null&&_>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",L=C==="offline"||C==="degraded"||C==="stale"?"recover":I==="quiet_hours"?"manual_lodge_poke":I==="unknown"?"probe":"direct_message";return{health_state:C,quiet_reason:I,next_action_path:L,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:x,next_eligible_at_s:_!=null&&_>0?_:null,recoverable:Qo(void 0,L),summary:Xo(void 0,C,I),keepalive_running:i}}function Hl(t,e){if(!Ot(t))return null;const n=Ll(t.role),a=U(t.content)??U(t.preview);if(!a)return null;const o=vs(t.ts_unix)??vs(t.timestamp);return{id:`${n}-${o??"entry"}-${e}`,role:n,label:El(n),text:a,timestamp:o,delivery:"history"}}function Wl(t,e,n){const a=Ot(n)?n:null,o=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>Hl(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:jn(a==null?void 0:a.diagnostic),history:o,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function ro(t,e){const n=rt.value[t]??[];rt.value={...rt.value,[t]:[...n,e].slice(-50)}}function Bl(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Gl(t,e){const a=(rt.value[t]??[]).filter(o=>o.delivery!=="history"&&!e.some(i=>Bl(o,i)));rt.value={...rt.value,[t]:[...e,...a].slice(-50)}}function ga(t,e){Dt.value={...Dt.value,[t]:e},Gl(t,e.history)}function lo(t,e){const n=Dt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};ga(t,{...n,diagnostic:{...a,...e}})}async function qs(){try{await cn()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Jl(t){Ml.value=t.trim()}async function ti(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Dt.value[n])return Dt.value[n];st(ds,n,!0),st(Mt,n,null);try{const a=await zt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let o=null;try{o=JSON.parse(a)}catch{o=null}const i=Wl(n,a,o);return ga(n,i),i}catch(a){const o=a instanceof Error?a.message:`Failed to inspect ${n}`;return st(Mt,n,o),null}finally{st(ds,n,!1)}}async function Vl(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const o=`local-${Date.now()}`;ro(n,{id:o,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),st(us,n,!0),st(Mt,n,null);try{const i=await Dl(n,a);rt.value={...rt.value,[n]:(rt.value[n]??[]).map(r=>r.id===o?{...r,delivery:"delivered"}:r)},ro(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),lo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await qs()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw rt.value={...rt.value,[n]:(rt.value[n]??[]).map(c=>c.id===o?{...c,delivery:"error",error:r}:c)},lo(n,{last_reply_status:"error",last_error:r}),st(Mt,n,r),i}finally{st(us,n,!1)}}async function Yl(t,e){const n=t.trim();if(!n)return null;st(ps,n,!0),st(Mt,n,null);try{const a=await fa({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),o=ql(a.result),i=(o==null?void 0:o.diagnostic)??null;if(i){const r=Dt.value[n];ga(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??rt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await qs(),i}catch(a){const o=a instanceof Error?a.message:`Failed to probe ${n}`;throw st(Mt,n,o),a}finally{st(ps,n,!1)}}async function Xl(t,e){const n=t.trim();if(!n)return null;st(ms,n,!0),st(Mt,n,null);try{const a=await fa({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),o=Kl(a.result),i=(o==null?void 0:o.after)??null;if(i){const r=Dt.value[n];ga(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??rt.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await qs(),i}catch(a){const o=a instanceof Error?a.message:`Failed to recover ${n}`;throw st(Mt,n,o),a}finally{st(ms,n,!1)}}function te(t){return(t??"").trim().toLowerCase()}function pt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function wn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function _n(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Pe(t){return t.last_heartbeat??_n(t.last_turn_ago_s)??_n(t.last_proactive_ago_s)??_n(t.last_handoff_ago_s)??_n(t.last_compaction_ago_s)}function Ql(t){const e=t.title.trim();return e||wn(t.content)}function Zl(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function tc(t,e,n,a,o={}){var D;const i=te(t),r=e.filter(T=>te(T.assignee)===i&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>te(T.from)===i).sort((T,N)=>pt(N.timestamp)-pt(T.timestamp))[0],u=a.filter(T=>te(T.agent)===i||te(T.author)===i).sort((T,N)=>pt(N.timestamp)-pt(T.timestamp))[0],f=(o.boardPosts??[]).filter(T=>te(T.author)===i).sort((T,N)=>pt(N.updated_at||N.created_at)-pt(T.updated_at||T.created_at))[0],d=(o.keepers??[]).filter(T=>te(T.name)===i&&Pe(T)!==null).sort((T,N)=>pt(Pe(N)??0)-pt(Pe(T)??0))[0],_=c?pt(c.timestamp):0,g=u?pt(u.timestamp):0,$=f?pt(f.updated_at||f.created_at):0,x=d?pt(Pe(d)??0):0,C=o.lastSeen?pt(o.lastSeen):0,I=((D=o.currentTask)==null?void 0:D.trim())||(r>0?`${r} claimed tasks`:null);if(_===0&&g===0&&$===0&&x===0&&C===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:I};const q=[c?{timestamp:c.timestamp,ts:_,text:wn(c.content)}:null,f?{timestamp:f.updated_at||f.created_at,ts:$,text:`Post: ${wn(Ql(f))}`}:null,d?{timestamp:Pe(d),ts:x,text:Zl(d)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:g,text:wn(u.text)}:null].filter(T=>T!==null).sort((T,N)=>N.ts-T.ts)[0];return q&&q.ts>=C?{activeAssignedCount:r,lastActivityAt:q.timestamp,lastActivityText:q.text}:{activeAssignedCount:r,lastActivityAt:o.lastSeen??null,lastActivityText:I??"Presence heartbeat"}}const ce=v([]),Kt=v([]),ei=v([]),Ce=v([]),Je=v(null),ec=v(null),fs=v(new Map),$a=v([]),Ve=v("hot"),fe=v(!0),ni=v(null),Pt=v(""),Ye=v([]),ge=v(!1),ai=v(new Map),Ks=v("unknown"),Fn=v(null),gs=v(!1),Xe=v(!1),$s=v(!1),$e=v(!1),Us=v(null),qn=v(!1),Kn=v(null),si=v(null),hs=v(null),oi=v(null),ii=v(null),nc=v(null);Vt(()=>ce.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const ac=Vt(()=>{const t=Kt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),sc=Vt(()=>{const t=new Map,e=Kt.value,n=ei.value,a=is.value,o=$a.value,i=Ce.value;for(const r of ce.value)t.set(r.name.trim().toLowerCase(),tc(r.name,e,n,a,{currentTask:r.current_task,lastSeen:r.last_seen,boardPosts:o,keepers:i}));return t});function oc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const o=a.context_ratio;return o>.85?"handoff-imminent":o>.7?"preparing":o>.5?"compacting":"active"}const ic=Vt(()=>{const t=new Map;for(const e of Ce.value)t.set(e.name,oc(e));return t}),rc=12e4;function lc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const o=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof o=="number"?Date.now()-o*1e3:null}const cc=Vt(()=>{const t=Date.now(),e=new Set,n=fs.value;for(const a of Ce.value){const o=lc(a,n);o!=null&&t-o>rc&&e.add(a.name)}return e});let Na=null;function dc(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function at(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function A(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ie(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ys(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function ri(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function uc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function pc(t){if(!at(t))return null;const e=y(t.name);return e?{name:e,status:ri(t.status),current_task:y(t.current_task)??null,last_seen:y(t.last_seen),emoji:y(t.emoji),koreanName:y(t.koreanName)??y(t.korean_name),model:y(t.model),traits:ie(t.traits),interests:ie(t.interests),activityLevel:A(t.activityLevel)??A(t.activity_level),primaryValue:y(t.primaryValue)??y(t.primary_value)}:null}function mc(t){if(!at(t))return null;const e=y(t.id),n=y(t.title);return!e||!n?null:{id:e,title:n,status:uc(t.status),priority:A(t.priority),assignee:y(t.assignee),description:y(t.description),created_at:y(t.created_at),updated_at:y(t.updated_at)}}function vc(t){if(!at(t))return null;const e=y(t.from)??y(t.from_agent)??"system",n=y(t.content)??"",a=y(t.timestamp)??new Date().toISOString();return{id:y(t.id),seq:A(t.seq),from:e,content:n,timestamp:a,type:y(t.type)}}function _c(t){return Array.isArray(t)?t.map(e=>{if(!at(e))return null;const n=A(e.ts_unix);if(n==null)return null;const a=at(e.handoff)?e.handoff:null;return{ts:n,context_ratio:A(e.context_ratio)??0,context_tokens:A(e.context_tokens)??0,context_max:A(e.context_max)??0,latency_ms:A(e.latency_ms)??0,generation:A(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:A(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:A(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?A(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function co(t){if(!at(t))return null;const e=y(t.health_state),n=y(t.next_action_path),a=y(t.last_reply_status);if(!e||!n||!a)return null;const o=y(t.quiet_reason)??null,i=y(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":o==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":o==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":o==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:o,next_action_path:n,last_reply_status:a,last_reply_at:ys(t.last_reply_at)??y(t.last_reply_at)??null,last_reply_preview:y(t.last_reply_preview)??null,last_error:y(t.last_error)??null,next_eligible_at_s:A(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function fc(t,e){return(Array.isArray(t)?t:at(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!at(a))return null;const o=at(a.agent)?a.agent:null,i=at(a.context)?a.context:null,r=at(a.metrics_window)?a.metrics_window:void 0,c=y(a.name);if(!c)return null;const u=A(a.context_ratio)??A(i==null?void 0:i.context_ratio),f=y(a.status)??y(o==null?void 0:o.status)??"offline",d=ri(f),_=y(a.model)??y(a.active_model)??y(a.primary_model),g=ie(a.skill_secondary),$=i?{source:y(i.source),context_ratio:A(i.context_ratio),context_tokens:A(i.context_tokens),context_max:A(i.context_max),message_count:A(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,x=o?{name:y(o.name),exists:typeof o.exists=="boolean"?o.exists:void 0,error:y(o.error),status:y(o.status),current_task:y(o.current_task)??null,last_seen:y(o.last_seen),last_seen_ago_s:A(o.last_seen_ago_s),is_zombie:typeof o.is_zombie=="boolean"?o.is_zombie:void 0}:void 0,C=_c(a.metrics_series),I={name:c,emoji:y(a.emoji),koreanName:y(a.koreanName)??y(a.korean_name),agent_name:y(a.agent_name),trace_id:y(a.trace_id),model:_,primary_model:y(a.primary_model),active_model:y(a.active_model),next_model_hint:y(a.next_model_hint)??null,status:d,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:A(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:A(a.proactive_idle_sec),proactive_cooldown_sec:A(a.proactive_cooldown_sec),last_heartbeat:y(a.last_heartbeat)??y(o==null?void 0:o.last_seen),generation:A(a.generation),turn_count:A(a.turn_count)??A(a.total_turns),keeper_age_s:A(a.keeper_age_s),last_turn_ago_s:A(a.last_turn_ago_s),last_handoff_ago_s:A(a.last_handoff_ago_s),last_compaction_ago_s:A(a.last_compaction_ago_s),last_proactive_ago_s:A(a.last_proactive_ago_s),context_ratio:u,context_tokens:A(a.context_tokens)??A(i==null?void 0:i.context_tokens),context_max:A(a.context_max)??A(i==null?void 0:i.context_max),context_source:y(a.context_source)??y(i==null?void 0:i.source),context:$,traits:ie(a.traits),interests:ie(a.interests),primaryValue:y(a.primaryValue)??y(a.primary_value),activityLevel:A(a.activityLevel)??A(a.activity_level),memory_recent_note:y(a.memory_recent_note)??null,conversation_tail_count:A(a.conversation_tail_count),k2k_count:A(a.k2k_count),handoff_count_total:A(a.handoff_count_total)??A(a.trace_history_count),compaction_count:A(a.compaction_count),last_compaction_saved_tokens:A(a.last_compaction_saved_tokens),diagnostic:co(a.diagnostic),skill_primary:y(a.skill_primary)??null,skill_secondary:g,skill_reason:y(a.skill_reason)??null,metrics_series:C.length>0?C:void 0,metrics_window:r,agent:x};return I.diagnostic=co(a.diagnostic)??Ul(I,(e==null?void 0:e.lodge)??null),I}).filter(a=>a!==null)}function li(t){return at(t)?{...t,lodge:Fl(t.lodge)??void 0}:null}function gc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function $c(t){if(!at(t))return null;const e=A(t.iteration);if(e==null)return null;const n=A(t.metric_before)??0,a=A(t.metric_after)??n,o=at(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:a,delta:A(t.delta)??a-n,changes:y(t.changes)??"",failed_attempts:y(t.failed_attempts)??"",next_suggestion:y(t.next_suggestion)??"",elapsed_ms:A(t.elapsed_ms)??0,cost_usd:A(t.cost_usd)??null,evidence:o?{worker_engine:(o.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:y(o.worker_model)??"",tool_call_count:A(o.tool_call_count)??0,tool_names:ie(o.tool_names)??[],session_id:y(o.session_id)??"",evidence_status:o.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function hc(t){var i,r;if(!at(t))return null;const e=y(t.loop_id);if(!e)return null;const n=A(t.baseline_metric)??0,a=Array.isArray(t.history)?t.history.map($c).filter(c=>c!==null):[],o=A(t.current_metric)??((i=a[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:y(t.profile)??"unknown",status:gc(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:y(t.error_message)??y(t.error_reason)??null,stop_reason:y(t.stop_reason)??y(t.reason)??null,current_iteration:A(t.current_iteration)??((r=a[0])==null?void 0:r.iteration)??0,max_iterations:A(t.max_iterations)??0,baseline_metric:n,current_metric:o,target:y(t.target)??"",stagnation_streak:A(t.stagnation_streak)??0,stagnation_limit:A(t.stagnation_limit)??0,elapsed_seconds:A(t.elapsed_seconds)??0,updated_at:ys(t.updated_at)??null,stopped_at:ys(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:y(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:A(t.latest_tool_call_count)??0,latest_tool_names:ie(t.latest_tool_names)??[],session_id:y(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:a}}async function cn(){gs.value=!0;try{await Promise.all([di(),Tt()]),si.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{gs.value=!1}}async function ci(){qn.value=!0,Kn.value=null;try{const t=await Fr();Us.value=t,nc.value=new Date().toISOString()}catch(t){Kn.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{qn.value=!1}}function yc(t){var e;return((e=Us.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function bc(t){var n;const e=((n=Us.value)==null?void 0:n.surfaces)??[];for(const a of e){const o=a.panels.find(i=>i.id===t);if(o)return o}return null}function kc(t){var a,o;Ye.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!at(i))return null;const r=y(i.id),c=y(i.title),u=y(i.horizon),f=y(i.status),d=y(i.created_at),_=y(i.updated_at);return!r||!c||!u||!f||!d||!_?null:{id:r,horizon:u,title:c,metric:y(i.metric)??null,target_value:y(i.target_value)??null,due_date:y(i.due_date)??null,priority:A(i.priority)??3,status:f,parent_goal_id:y(i.parent_goal_id)??null,last_review_note:y(i.last_review_note)??null,last_review_at:y(i.last_review_at)??null,created_at:d,updated_at:_}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((a=t.mdal)==null?void 0:a.loops)?t.mdal.loops:[];for(const i of n){const r=hc(i);r&&e.set(r.loop_id,r)}ai.value=e,Fn.value=typeof((o=t.mdal)==null?void 0:o.error)=="string"?t.mdal.error:null,Ks.value=Fn.value?"error":e.size===0?"idle":"ready"}async function di(){try{const t=await Er(),e=li(t.status);e&&(Je.value=e)}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Tt(){try{const t=await zr(),e=li(t.status);e&&(Je.value=e),ce.value=(Array.isArray(t.agents)?t.agents:[]).map(pc).filter(n=>n!==null),Kt.value=(Array.isArray(t.tasks)?t.tasks:[]).map(mc).filter(n=>n!==null),ei.value=(Array.isArray(t.messages)?t.messages:[]).map(vc).filter(n=>n!==null),Ce.value=fc(t.keepers,e??Je.value),ec.value=null,si.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function At(){Xe.value=!0;try{const t=await Or(Ve.value,{excludeSystem:fe.value});$a.value=t.posts??[],hs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Xe.value=!1}}async function Ct(){var t;$s.value=!0;try{const e=Pt.value||((t=Je.value)==null?void 0:t.room)||"default";Pt.value||(Pt.value=e);const n=await $l(e);ni.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{$s.value=!1}}async function ke(){ge.value=!0,$e.value=!0;try{const t=await Kr();kc(t),oi.value=new Date().toISOString(),ii.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Ks.value="error",Fn.value=t instanceof Error?t.message:String(t)}finally{ge.value=!1,$e.value=!1}}async function bs(){return ke()}let In=null;function xc(t){In=t}let Tn=null;function Sc(t){Tn=t}let Rn=null;function Ac(t){Rn=t}const ae={};function ee(t,e,n=500){ae[t]&&clearTimeout(ae[t]),ae[t]=setTimeout(()=>{e(),delete ae[t]},n)}function Cc(){const t=Ko.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(fs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),fs.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ee("execution",Tt),dc(e.type)&&(Na||(Na=setTimeout(()=>{cn(),Tn==null||Tn(),Rn==null||Rn(),Na=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ee("execution",Tt),e.type==="broadcast"&&ee("execution",Tt),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ee("execution",Tt),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ee("board",At),e.type.startsWith("decision_")&&ee("council",()=>In==null?void 0:In()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ee("mdal",bs,350)}});return()=>{t();for(const e of Object.keys(ae))clearTimeout(ae[e]),delete ae[e]}}let ze=null;function wc(){ze||(ze=setInterval(()=>{le.value,cn()},1e4))}function Ic(){ze&&(clearInterval(ze),ze=null)}function Tc({metric:t}){return s`
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
  `}function Rc({panel:t}){return s`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${t.purpose}</span>
        <span>Solves</span><span>${t.problem_solved}</span>
        <span>When</span><span>${t.when_active}</span>
        <span>Agent Role</span><span>${t.agent_role}</span>
        <span>Ecosystem</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?s`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>s`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?s`<div class="semantic-metric-list">
            ${t.metrics.map(e=>s`<${Tc} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function z({panelId:t,compact:e=!1,label:n="Why"}){const a=bc(t);return a?s`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Rc} panel=${a} />
    </details>
  `:qn.value?s`<span class="semantic-inline-state">Loading semantics…</span>`:null}function $t({surfaceId:t,compact:e=!1}){const n=yc(t);return n?s`
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
      ${n.panels.length>0?s`<div class="semantic-tag-row">
            ${n.panels.map(a=>s`<span class="semantic-tag">${a.title}</span>`)}
          </div>`:null}
    </section>
  `:qn.value?s`<div class="semantic-surface-card ${e?"compact":""}">Loading semantics…</div>`:Kn.value?s`<div class="semantic-surface-card ${e?"compact":""}">${Kn.value}</div>`:null}function w({title:t,class:e,semanticId:n,children:a}){return s`
    <div class="card ${e??""}">
      ${t?s`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?s`<${z} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const ui=v(null),ks=v(!1),Un=v(null);function J(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function P(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function B(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Hs(t){return typeof t=="boolean"?t:void 0}function Rt(t,e=[]){if(Array.isArray(t))return t;if(!J(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function ha(t){if(!J(t))return null;const e=P(t.kind),n=P(t.summary),a=P(t.target_type);return!e||!n||!a?null:{kind:e,severity:P(t.severity)??"warn",summary:n,target_type:a,target_id:P(t.target_id)??null,actor:P(t.actor)??null,evidence:t.evidence}}function ya(t){if(!J(t))return null;const e=P(t.action_type),n=P(t.target_type),a=P(t.reason);return!e||!n||!a?null:{action_type:e,target_type:n,target_id:P(t.target_id)??null,severity:P(t.severity)??"warn",reason:a,confirm_required:Hs(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Nc(t){if(!J(t))return null;const e=P(t.session_id);return e?{session_id:e,goal:P(t.goal),status:P(t.status),health:P(t.health),scale_profile:P(t.scale_profile),control_profile:P(t.control_profile),planned_worker_count:B(t.planned_worker_count),active_agent_count:B(t.active_agent_count),last_turn_age_sec:B(t.last_turn_age_sec)??null,attention_count:B(t.attention_count),recommended_action_count:B(t.recommended_action_count),top_attention:ha(t.top_attention),top_recommendation:ya(t.top_recommendation)}:null}function Pc(t){if(!J(t))return null;const e=P(t.session_id);return e?{session_id:e,status:P(t.status),progress_pct:B(t.progress_pct),elapsed_sec:B(t.elapsed_sec),remaining_sec:B(t.remaining_sec),done_delta_total:B(t.done_delta_total),summary:J(t.summary)?t.summary:void 0,team_health:J(t.team_health)?t.team_health:void 0,communication_metrics:J(t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:J(t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:J(t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:J(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([n,a])=>{const o=P(a);return o?[n,o]:null}).filter(n=>n!==null)):void 0,session:J(t.session)?t.session:void 0,recent_events:Rt(t.recent_events,["events"]).filter(J)}:null}function Dc(t){if(!J(t))return null;const e=P(t.name);return e?{name:e,agent_name:P(t.agent_name),status:P(t.status),autonomy_level:P(t.autonomy_level),context_ratio:B(t.context_ratio),generation:B(t.generation),active_goal_ids:Rt(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:P(t.last_autonomous_action_at)??null,last_turn_ago_s:B(t.last_turn_ago_s),model:P(t.model)}:null}function Mc(t){if(!J(t))return null;const e=P(t.confirm_token)??P(t.token);return e?{confirm_token:e,actor:P(t.actor),action_type:P(t.action_type),target_type:P(t.target_type),target_id:P(t.target_id)??null,delegated_tool:P(t.delegated_tool),created_at:P(t.created_at),preview:t.preview}:null}function Lc(t){if(!J(t))return null;const e=P(t.action_type),n=P(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:P(t.description),confirm_required:Hs(t.confirm_required)}}function Ec(t){const e=J(t)?t:{};return{room_health:P(e.room_health),cluster:P(e.cluster),project:P(e.project),current_room:P(e.current_room)??null,paused:Hs(e.paused),tempo_interval_s:B(e.tempo_interval_s),active_agents:B(e.active_agents),keeper_pressure:B(e.keeper_pressure),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),incident_count:B(e.incident_count),recommended_action_count:B(e.recommended_action_count),top_attention:ha(e.top_attention),top_action:ya(e.top_action)}}function zc(t){const e=J(t)?t:{},n=J(e.swarm_overview)?e.swarm_overview:{};return{health:P(e.health),active_operations:B(e.active_operations),pending_approvals:B(e.pending_approvals),swarm_overview:{active_lanes:B(n.active_lanes),moving_lanes:B(n.moving_lanes),stalled_lanes:B(n.stalled_lanes),projected_lanes:B(n.projected_lanes),last_movement_at:P(n.last_movement_at)??null},top_attention:ha(e.top_attention),top_action:ya(e.top_action),session_cards:Rt(e.session_cards).map(Nc).filter(a=>a!==null)}}function Oc(t){const e=J(t)?t:{};return{sessions:Rt(e.sessions,["items"]).map(Pc).filter(n=>n!==null),keepers:Rt(e.keepers,["items"]).map(Dc).filter(n=>n!==null),pending_confirms:Rt(e.pending_confirms).map(Mc).filter(n=>n!==null),available_actions:Rt(e.available_actions).map(Lc).filter(n=>n!==null)}}function jc(t){const e=J(t)?t:{};return{generated_at:P(e.generated_at),summary:Ec(e.summary),incidents:Rt(e.incidents).map(ha).filter(n=>n!==null),recommended_actions:Rt(e.recommended_actions).map(ya).filter(n=>n!==null),command_focus:zc(e.command_focus),operator_targets:Oc(e.operator_targets)}}async function Nn(){ks.value=!0,Un.value=null;try{const t=await qr();ui.value=jc(t)}catch(t){Un.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{ks.value=!1}}function vt(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}function uo(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:`${Math.round(n/3600)}h 전`}function pi(t){return t?t.target_type==="room"||t.target_type==="team_session"||t.target_type==="keeper"?()=>et("intervene"):()=>et("command"):()=>et("intervene")}function ue({label:t,value:e,detail:n,tone:a}){return s`
    <article class="mission-stat-card ${vt(a)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Fc({item:t}){return s`
    <article class="mission-incident-card ${vt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${vt(t.severity)}">${t.severity}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <strong>${t.summary}</strong>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>et("intervene")}>개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>et("command")}>지휘면 보기</button>
      </div>
    </article>
  `}function qc({action:t}){return s`
    <article class="mission-action-card ${vt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${vt(t.severity)}">${t.action_type}</span>
        <span class="mission-card-target">${t.target_type}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.reason}</p>
      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${pi(t)}>개입 워크스페이스</button>
      </div>
    </article>
  `}function Kc({session:t}){return s`
    <article class="mission-session-card ${vt(t.health)}">
      <div class="mission-card-head">
        <strong>${t.goal??t.session_id}</strong>
        <span class="command-chip ${vt(t.health)}">${t.health??"ok"}</span>
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
  `}function po(){var r,c,u;const t=ui.value;if(ks.value&&!t)return s`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Un.value&&!t)return s`<div class="empty-state error">${Un.value}</div>`;if(!t)return s`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;const e=t.summary,n=t.incidents[0]??e.top_attention??null,a=t.recommended_actions[0]??e.top_action??null,o=t.command_focus.session_cards.slice(0,3),i=t.operator_targets.keepers.slice(0,4);return s`
    <section class="dashboard-panel mission-view">
      <${$t} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 문제, 다음 액션, 운영 포커스를 한 번에 보는 운영 랜딩입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${vt(e.room_health)}">${e.room_health??"ok"}</span>
          <span class="command-chip">${e.project??"room"}${e.current_room?` · ${e.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?uo(t.generated_at):"fresh"}</span>
        </div>
      </div>

      <div class="mission-stat-grid">
        <${ue} label="활성 에이전트" value=${e.active_agents??0} detail="실시간 응답 가능한 agent 수" tone=${e.active_agents&&e.active_agents>0?"ok":"warn"} />
        <${ue} label="Keeper 압력" value=${e.keeper_pressure??0} detail="stale / hot keeper 수" tone=${(e.keeper_pressure??0)>0?"warn":"ok"} />
        <${ue} label="활성 작전" value=${e.active_operations??0} detail="command plane active operation" tone=${(e.active_operations??0)>0?"ok":"warn"} />
        <${ue} label="승인 대기" value=${e.pending_approvals??0} detail="사람 확인이 필요한 decision" tone=${(e.pending_approvals??0)>0?"warn":"ok"} />
        <${ue} label="우선 Incident" value=${e.incident_count??t.incidents.length} detail="지금 우선순위로 볼 attention item" tone=${(n==null?void 0:n.severity)??"ok"} />
        <${ue} label="다음 액션" value=${e.recommended_action_count??t.recommended_actions.length} detail="digest 기준 추천 액션 수" tone=${(a==null?void 0:a.severity)??"ok"} />
      </div>

      <div class="mission-primary-grid">
        <${w} title="지금 가장 먼저 볼 것" class="mission-hero-card" semanticId="mission.hero">
          ${n?s`
                <div class="mission-priority-block ${vt(n.severity)}">
                  <div class="mission-card-head">
                    <span class="command-chip ${vt(n.severity)}">${n.kind}</span>
                    <span class="mission-card-target">${n.target_type}${n.target_id?` · ${n.target_id}`:""}</span>
                  </div>
                  <strong>${n.summary}</strong>
                </div>
              `:s`<div class="empty-state">우선 incident가 없습니다.</div>`}
          ${a?s`
                <div class="mission-action-highlight">
                  <div class="mission-card-head">
                    <span class="command-chip ${vt(a.severity)}">${a.action_type}</span>
                    <span class="mission-card-target">${a.target_type}${a.target_id?` · ${a.target_id}`:""}</span>
                  </div>
                  <p>${a.reason}</p>
                  <div class="mission-card-actions">
                    <button class="control-btn ghost" onClick=${pi(a)}>개입하러 가기</button>
                    <button class="control-btn ghost" onClick=${()=>et("command",{surface:"swarm"})}>지휘면 상세</button>
                  </div>
                </div>
              `:null}
        <//>

        <${w} title="운영 포커스" class="mission-focus-card" semanticId="mission.focus">
          <div class="mission-focus-grid">
            <div class="mission-focus-item">
              <span>지휘 건강도</span>
              <strong class=${vt(t.command_focus.health)}>${t.command_focus.health??"ok"}</strong>
            </div>
            <div class="mission-focus-item">
              <span>활성 레인</span>
              <strong>${((r=t.command_focus.swarm_overview)==null?void 0:r.active_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>이동 레인</span>
              <strong>${((c=t.command_focus.swarm_overview)==null?void 0:c.moving_lanes)??0}</strong>
            </div>
            <div class="mission-focus-item">
              <span>마지막 이동</span>
              <strong>${uo((u=t.command_focus.swarm_overview)==null?void 0:u.last_movement_at)}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>et("command")}>지휘면 열기</button>
            <button class="control-btn ghost" onClick=${()=>et("command",{surface:"swarm"})}>스웜 상세</button>
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${w} title="우선 Incident" class="mission-list-card" semanticId="mission.incidents">
          <div class="mission-list-stack">
            ${t.incidents.length>0?t.incidents.slice(0,5).map(f=>s`<${Fc} item=${f} />`):s`<div class="empty-state">attention item이 없습니다.</div>`}
          </div>
        <//>

        <${w} title="추천 액션" class="mission-list-card" semanticId="mission.actions">
          <div class="mission-list-stack">
            ${t.recommended_actions.length>0?t.recommended_actions.slice(0,4).map(f=>s`<${qc} action=${f} />`):s`<div class="empty-state">추천 액션이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-content-grid">
        <${w} title="집중 세션" class="mission-list-card" semanticId="mission.sessions">
          <div class="mission-list-stack">
            ${o.length>0?o.map(f=>s`<${Kc} session=${f} />`):s`<div class="empty-state">지금 강조할 session이 없습니다.</div>`}
          </div>
        <//>

        <${w} title="바로 개입할 대상" class="mission-list-card" semanticId="mission.targets">
          <div class="mission-target-grid">
            <div class="mission-target-block">
              <span class="mission-target-title">Keepers</span>
              ${i.length>0?i.map(f=>s`<div class="mission-target-row"><strong>${f.name}</strong><span class="command-chip ${vt(f.status)}">${f.status??"unknown"}</span></div>`):s`<div class="mission-target-empty">keeper 대상이 없습니다.</div>`}
            </div>
            <div class="mission-target-block">
              <span class="mission-target-title">대기 중 confirm</span>
              <strong>${t.operator_targets.pending_confirms.length}</strong>
              <span class="mission-target-title">가능 액션</span>
              <strong>${t.operator_targets.available_actions.length}</strong>
            </div>
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>et("intervene")}>개입 워크스페이스</button>
          </div>
        <//>
      </div>
    </section>
  `}const Uc="modulepreload",Hc=function(t){return"/dashboard/"+t},mo={},Wc=function(e,n,a){let o=Promise.resolve();if(n&&n.length>0){let r=function(f){return Promise.all(f.map(d=>Promise.resolve(d).then(_=>({status:"fulfilled",value:_}),_=>({status:"rejected",reason:_}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),u=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));o=r(n.map(f=>{if(f=Hc(f),f in mo)return;mo[f]=!0;const d=f.endsWith(".css"),_=d?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${f}"]${_}`))return;const g=document.createElement("link");if(g.rel=d?"stylesheet":Uc,d||(g.as="script"),g.crossOrigin="",g.href=f,u&&g.setAttribute("nonce",u),document.head.appendChild(g),d)return new Promise(($,x)=>{g.addEventListener("load",$),g.addEventListener("error",()=>x(new Error(`Unable to preload CSS for ${f}`)))})}))}function i(r){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=r,window.dispatchEvent(c),!c.defaultPrevented)throw r}return o.then(r=>{for(const c of r||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})},Ws=v(null),It=v(null),Hn=v(!1),Wn=v(!1),Bn=v(null),Gn=v(null),xs=v(null),Jn=v(null),_t=v("operations"),dn=v(null),Ss=v(!1),Vn=v(null),ba=v(null),As=v(!1),Yn=v(null),ka=v(null),Cs=v(!1),Xn=v(null),Qe=v(null),Qn=v(!1),Ze=v(null),ye=v(null);let Ee=null;function Bs(t){return t!=="summary"&&t!=="swarm"}function S(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function l(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function m(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function G(t){return typeof t=="boolean"?t:void 0}function lt(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function mi(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((o,i)=>{t.has(i)||t.set(i,o)}),t}function Bc(){const e=mi().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Gc(){const e=mi().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Jc(t){if(S(t))return{policy_class:l(t.policy_class),approval_class:l(t.approval_class),tool_allowlist:lt(t.tool_allowlist),model_allowlist:lt(t.model_allowlist),requires_human_for:lt(t.requires_human_for),autonomy_level:l(t.autonomy_level),escalation_timeout_sec:m(t.escalation_timeout_sec),kill_switch:G(t.kill_switch),frozen:G(t.frozen)}}function Vc(t){if(S(t))return{headcount_cap:m(t.headcount_cap),active_operation_cap:m(t.active_operation_cap),max_cost_usd:m(t.max_cost_usd),max_tokens:m(t.max_tokens)}}function Gs(t){if(!S(t))return null;const e=l(t.unit_id),n=l(t.label),a=l(t.kind);return!e||!n||!a?null:{unit_id:e,label:n,kind:a,parent_unit_id:l(t.parent_unit_id)??null,leader_id:l(t.leader_id)??null,roster:lt(t.roster),capability_profile:lt(t.capability_profile),source:l(t.source),created_at:l(t.created_at),updated_at:l(t.updated_at),policy:Jc(t.policy),budget:Vc(t.budget)}}function vi(t){if(!S(t))return null;const e=Gs(t.unit);return e?{unit:e,leader_status:l(t.leader_status),roster_total:m(t.roster_total),roster_live:m(t.roster_live),active_operation_count:m(t.active_operation_count),health:l(t.health),reasons:lt(t.reasons),children:Array.isArray(t.children)?t.children.map(vi).filter(n=>n!==null):[]}:null}function Yc(t){if(S(t))return{total_units:m(t.total_units),company_count:m(t.company_count),platoon_count:m(t.platoon_count),squad_count:m(t.squad_count),leaf_agent_unit_count:m(t.leaf_agent_unit_count),live_agent_count:m(t.live_agent_count),managed_unit_count:m(t.managed_unit_count),active_operation_count:m(t.active_operation_count)}}function _i(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),source:l(e.source),summary:Yc(e.summary),units:Array.isArray(e.units)?e.units.map(vi).filter(n=>n!==null):[]}}function Xc(t){if(!S(t))return null;const e=l(t.kind),n=l(t.status);return!e||!n?null:{kind:e,chain_id:l(t.chain_id)??null,goal:l(t.goal)??null,run_id:l(t.run_id)??null,status:n,viewer_path:l(t.viewer_path)??null,last_sync_at:l(t.last_sync_at)??null}}function xa(t){if(!S(t))return null;const e=l(t.operation_id),n=l(t.objective),a=l(t.assigned_unit_id),o=l(t.trace_id),i=l(t.status);return!e||!n||!a||!o||!i?null:{operation_id:e,objective:n,assigned_unit_id:a,autonomy_level:l(t.autonomy_level),policy_class:l(t.policy_class),budget_class:l(t.budget_class),detachment_session_id:l(t.detachment_session_id)??null,trace_id:o,checkpoint_ref:l(t.checkpoint_ref)??null,active_goal_ids:lt(t.active_goal_ids),note:l(t.note)??null,created_by:l(t.created_by),source:l(t.source),status:i,chain:Xc(t.chain),created_at:l(t.created_at),updated_at:l(t.updated_at)}}function Qc(t){if(!S(t))return null;const e=xa(t.operation);return e?{operation:e,assigned_unit_label:l(t.assigned_unit_label)}:null}function De(t){if(S(t))return{tone:l(t.tone),pending_ops:m(t.pending_ops),blocked_ops:m(t.blocked_ops),in_flight_ops:m(t.in_flight_ops),pipeline_stalls:m(t.pipeline_stalls),bus_traffic:m(t.bus_traffic),l1_hit_rate:m(t.l1_hit_rate),invalidation_count:m(t.invalidation_count),current_pending:m(t.current_pending),current_in_flight:m(t.current_in_flight),cdb_wakeups:m(t.cdb_wakeups),total_stolen:m(t.total_stolen),avg_best_score:m(t.avg_best_score),avg_candidate_count:m(t.avg_candidate_count),best_first_operations:m(t.best_first_operations),active_sessions:m(t.active_sessions),commit_rate:m(t.commit_rate),total_speculations:m(t.total_speculations)}}function Zc(t){if(!S(t))return;const e=S(t.pipeline)?t.pipeline:void 0,n=S(t.cache)?t.cache:void 0,a=S(t.ooo)?t.ooo:void 0,o=S(t.speculative)?t.speculative:void 0,i=S(t.search_fabric)?t.search_fabric:void 0,r=S(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:m(e.total_ops),completed_ops:m(e.completed_ops),stalled_cycles:m(e.stalled_cycles),hazards_detected:m(e.hazards_detected),forwarding_used:m(e.forwarding_used),pipeline_flushes:m(e.pipeline_flushes),ipc:m(e.ipc)}:void 0,cache:n?{total_reads:m(n.total_reads),total_writes:m(n.total_writes),l1_hit_rate:m(n.l1_hit_rate),invalidation_count:m(n.invalidation_count),writeback_count:m(n.writeback_count),bus_traffic:m(n.bus_traffic)}:void 0,ooo:a?{agent_count:m(a.agent_count),total_added:m(a.total_added),total_issued:m(a.total_issued),total_completed:m(a.total_completed),total_stolen:m(a.total_stolen),cdb_wakeups:m(a.cdb_wakeups),stall_cycles:m(a.stall_cycles),global_cdb_events:m(a.global_cdb_events),current_pending:m(a.current_pending),current_in_flight:m(a.current_in_flight)}:void 0,speculative:o?{total_speculations:m(o.total_speculations),total_commits:m(o.total_commits),total_aborts:m(o.total_aborts),commit_rate:m(o.commit_rate),total_fast_calls:m(o.total_fast_calls),total_cost_usd:m(o.total_cost_usd),active_sessions:m(o.active_sessions)}:void 0,search_fabric:i?{total_operations:m(i.total_operations),best_first_operations:m(i.best_first_operations),legacy_operations:m(i.legacy_operations),blocked_operations:m(i.blocked_operations),ready_operations:m(i.ready_operations),research_pipeline_operations:m(i.research_pipeline_operations),avg_candidate_count:m(i.avg_candidate_count),avg_best_score:m(i.avg_best_score),top_stage:l(i.top_stage)??null}:void 0,signals:r?{issue_pressure:De(r.issue_pressure),cache_contention:De(r.cache_contention),scheduler_efficiency:De(r.scheduler_efficiency),routing_confidence:De(r.routing_confidence),speculative_posture:De(r.speculative_posture)}:void 0}}function fi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:m(n.total),active:m(n.active),paused:m(n.paused),managed:m(n.managed),projected:m(n.projected)}:void 0,microarch:Zc(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Qc).filter(a=>a!==null):[]}}function gi(t){if(!S(t))return null;const e=l(t.detachment_id),n=l(t.operation_id),a=l(t.assigned_unit_id);return!e||!n||!a?null:{detachment_id:e,operation_id:n,assigned_unit_id:a,leader_id:l(t.leader_id)??null,roster:lt(t.roster),session_id:l(t.session_id)??null,checkpoint_ref:l(t.checkpoint_ref)??null,runtime_kind:l(t.runtime_kind)??null,runtime_ref:l(t.runtime_ref)??null,source:l(t.source),status:l(t.status),last_event_at:l(t.last_event_at)??null,last_progress_at:l(t.last_progress_at)??null,heartbeat_deadline:l(t.heartbeat_deadline)??null,created_at:l(t.created_at),updated_at:l(t.updated_at)}}function td(t){if(!S(t))return null;const e=gi(t.detachment);return e?{detachment:e,assigned_unit_label:l(t.assigned_unit_label),operation:xa(t.operation)}:null}function $i(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:m(n.total),active:m(n.active),projected:m(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(td).filter(a=>a!==null):[]}}function ed(t){if(!S(t))return null;const e=l(t.decision_id),n=l(t.trace_id),a=l(t.requested_action),o=l(t.scope_type),i=l(t.scope_id);return!e||!n||!a||!o||!i?null:{decision_id:e,trace_id:n,requested_action:a,scope_type:o,scope_id:i,operation_id:l(t.operation_id)??null,target_unit_id:l(t.target_unit_id)??null,requested_by:l(t.requested_by),status:l(t.status),reason:l(t.reason)??null,source:l(t.source),detail:t.detail,created_at:l(t.created_at),decided_at:l(t.decided_at)??null,expires_at:l(t.expires_at)??null}}function hi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:m(n.total),pending:m(n.pending),approved:m(n.approved),denied:m(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(ed).filter(a=>a!==null):[]}}function nd(t){if(!S(t))return null;const e=Gs(t.unit);return e?{unit:e,roster_total:m(t.roster_total),roster_live:m(t.roster_live),headcount_cap:m(t.headcount_cap),active_operations:m(t.active_operations),active_operation_cap:m(t.active_operation_cap),utilization:m(t.utilization)}:null}function ad(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(nd).filter(n=>n!==null):[]}}function sd(t){if(!S(t))return null;const e=l(t.alert_id);return e?{alert_id:e,severity:l(t.severity),kind:l(t.kind),scope_type:l(t.scope_type),scope_id:l(t.scope_id),title:l(t.title),detail:l(t.detail),timestamp:l(t.timestamp)}:null}function yi(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),summary:n?{total:m(n.total),bad:m(n.bad),warn:m(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(sd).filter(a=>a!==null):[]}}function bi(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.trace_id),a=l(t.event_type);return!e||!n||!a?null:{event_id:e,trace_id:n,event_type:a,operation_id:l(t.operation_id)??null,unit_id:l(t.unit_id)??null,actor:l(t.actor)??null,source:l(t.source),timestamp:l(t.timestamp),detail:t.detail}}function od(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),events:Array.isArray(e.events)?e.events.map(bi).filter(n=>n!==null):[]}}function id(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),a=l(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a}}function rd(t){if(!S(t))return null;const e=l(t.lane_id),n=l(t.label),a=l(t.kind),o=l(t.phase),i=l(t.motion_state),r=l(t.source_of_truth),c=l(t.movement_reason),u=l(t.current_step);if(!e||!n||!a||!o||!i||!r||!c||!u)return null;const f=S(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:a,present:G(t.present)??!1,phase:o,motion_state:i,source_of_truth:r,last_movement_at:l(t.last_movement_at)??null,movement_reason:c,current_step:u,blockers:lt(t.blockers),counts:{operations:m(f.operations),detachments:m(f.detachments),workers:m(f.workers),approvals:m(f.approvals),alerts:m(f.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(id).filter(d=>d!==null):[]}}function ld(t){if(!S(t))return null;const e=l(t.event_id),n=l(t.lane_id),a=l(t.kind),o=l(t.timestamp),i=l(t.title),r=l(t.detail),c=l(t.tone),u=l(t.source);return!e||!n||!a||!o||!i||!r||!c||!u?null:{event_id:e,lane_id:n,kind:a,timestamp:o,title:i,detail:r,tone:c,source:u}}function cd(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),a=l(t.summary);return!e||!n||!a?null:{code:e,severity:n,summary:a,lane_ids:lt(t.lane_ids),count:m(t.count)??0}}function ki(t){if(!S(t))return;const e=S(t.overview)?t.overview:{},n=S(t.gaps)?t.gaps:{},a=S(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:l(t.generated_at),overview:{active_lanes:m(e.active_lanes),moving_lanes:m(e.moving_lanes),stalled_lanes:m(e.stalled_lanes),projected_lanes:m(e.projected_lanes),last_movement_at:l(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(rd).filter(o=>o!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(ld).filter(o=>o!==null):[],gaps:{count:m(n.count),items:Array.isArray(n.items)?n.items.map(cd).filter(o=>o!==null):[]},recommended_next_action:a?{tool:l(a.tool)??"masc_operator_snapshot",label:l(a.label)??"Observe operator state",reason:l(a.reason)??"",lane_id:l(a.lane_id)??null}:void 0}}function dd(t){if(!S(t))return;const e=S(t.workers)?t.workers:{},n=G(t.pass);return{status:l(t.status)??"missing",source:l(t.source)??"none",run_id:l(t.run_id)??null,captured_at:l(t.captured_at)??null,...n!==void 0?{pass:n}:{},...m(t.peak_hot_slots)!=null?{peak_hot_slots:m(t.peak_hot_slots)}:{},...m(t.ctx_per_slot)!=null?{ctx_per_slot:m(t.ctx_per_slot)}:{},workers:{expected:m(e.expected),joined:m(e.joined),current_task_bound:m(e.current_task_bound),fresh_heartbeats:m(e.fresh_heartbeats),done:m(e.done),final:m(e.final)},artifact_ref:l(t.artifact_ref)??null,missing_reason:l(t.missing_reason)??null}}function ud(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),topology:_i(e.topology),operations:fi(e.operations),detachments:$i(e.detachments),alerts:yi(e.alerts),decisions:hi(e.decisions),capacity:ad(e.capacity),traces:od(e.traces),swarm_status:ki(e.swarm_status)}}function pd(t){const e=S(t)?t:{},n=_i(e.topology),a=fi(e.operations),o=$i(e.detachments),i=yi(e.alerts),r=hi(e.decisions);return{version:l(e.version),generated_at:l(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:a.version,generated_at:a.generated_at,summary:a.summary,microarch:a.microarch},detachments:{version:o.version,generated_at:o.generated_at,summary:o.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:r.version,generated_at:r.generated_at,summary:r.summary},swarm_status:ki(e.swarm_status),swarm_proof:dd(e.swarm_proof)}}function md(t){return S(t)?{chain_id:l(t.chain_id)??null,started_at:m(t.started_at)??null,progress:m(t.progress)??null,elapsed_sec:m(t.elapsed_sec)??null}:null}function xi(t){if(!S(t))return null;const e=l(t.event);return e?{event:e,chain_id:l(t.chain_id)??null,timestamp:l(t.timestamp)??null,duration_ms:m(t.duration_ms)??null,message:l(t.message)??null,tokens:m(t.tokens)??null}:null}function vd(t){if(!S(t))return null;const e=xa(t.operation);return e?{operation:e,runtime:md(t.runtime),history:xi(t.history),mermaid:l(t.mermaid)??null,preview_run:Si(t.preview_run)}:null}function _d(t){const e=S(t)?t:{};return{status:l(e.status)??"disconnected",base_url:l(e.base_url)??null,message:l(e.message)??null}}function fd(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),connection:_d(e.connection),summary:n?{linked_operations:m(n.linked_operations),active_chains:m(n.active_chains),running_operations:m(n.running_operations),recent_failures:m(n.recent_failures),last_history_event_at:l(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(vd).filter(a=>a!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(xi).filter(a=>a!==null):[]}}function gd(t){if(!S(t))return null;const e=l(t.id);return e?{id:e,type:l(t.type),status:l(t.status),duration_ms:m(t.duration_ms)??null,error:l(t.error)??null}:null}function Si(t){if(!S(t))return null;const e=l(t.run_id),n=l(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:m(t.duration_ms),success:G(t.success),mermaid:l(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(gd).filter(a=>a!==null):[]}:null}function $d(t){const e=S(t)?t:{};return{run:Si(e.run)}}function hd(t){if(!S(t))return null;const e=l(t.title),n=l(t.path);return!e||!n?null:{title:e,path:n}}function yd(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.summary);return!e||!n||!a?null:{id:e,title:n,summary:a}}function bd(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.tool),o=l(t.summary);return!e||!n||!a||!o?null:{id:e,title:n,tool:a,summary:o,success_signals:lt(t.success_signals),pitfalls:lt(t.pitfalls)}}function kd(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.summary),o=l(t.when_to_use);return!e||!n||!a||!o?null:{id:e,title:n,summary:a,when_to_use:o,steps:Array.isArray(t.steps)?t.steps.map(bd).filter(i=>i!==null):[]}}function xd(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.description);return!e||!n||!a?null:{id:e,title:n,description:a,tools:lt(t.tools)}}function Sd(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.symptom),o=l(t.why),i=l(t.fix_tool),r=l(t.fix_summary);return!e||!n||!a||!o||!i||!r?null:{id:e,title:n,symptom:a,why:o,fix_tool:i,fix_summary:r}}function Ad(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.path_id),o=l(t.transport);return!e||!n||!a||!o?null:{id:e,title:n,path_id:a,transport:o,request:t.request,response:t.response,notes:lt(t.notes)}}function Cd(t){const e=S(t)?t:{};return{version:l(e.version),generated_at:l(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(hd).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(yd).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(kd).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(xd).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Sd).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Ad).filter(n=>n!==null):[]}}function wd(t){if(!S(t))return null;const e=l(t.id),n=l(t.title),a=l(t.status),o=l(t.detail),i=l(t.next_tool);return!e||!n||!a||!o||!i?null:{id:e,title:n,status:a,detail:o,next_tool:i}}function Id(t){if(!S(t))return null;const e=l(t.code),n=l(t.severity),a=l(t.title),o=l(t.detail),i=l(t.next_tool);return!e||!n||!a||!o||!i?null:{code:e,severity:n,title:a,detail:o,next_tool:i}}function Td(t){if(!S(t))return null;const e=l(t.from),n=l(t.content),a=l(t.timestamp),o=m(t.seq);return!e||!n||!a||o==null?null:{seq:o,from:e,content:n,timestamp:a}}function Rd(t){if(!S(t))return null;const e=l(t.name),n=l(t.role),a=l(t.lane),o=l(t.status),i=l(t.claim_marker),r=l(t.done_marker),c=l(t.final_marker);if(!e||!n||!a||!o||!i||!r||!c)return null;const u=(()=>{if(!S(t.last_message))return null;const f=m(t.last_message.seq),d=l(t.last_message.content),_=l(t.last_message.timestamp);return f==null||!d||!_?null:{seq:f,content:d,timestamp:_}})();return{name:e,role:n,lane:a,joined:G(t.joined)??!1,live_presence:G(t.live_presence)??!1,completed:G(t.completed)??!1,status:o,current_task:l(t.current_task)??null,bound_task_id:l(t.bound_task_id)??null,bound_task_title:l(t.bound_task_title)??null,bound_task_status:l(t.bound_task_status)??null,current_task_matches_run:G(t.current_task_matches_run)??!1,squad_member:G(t.squad_member)??!1,detachment_member:G(t.detachment_member)??!1,last_seen:l(t.last_seen)??null,heartbeat_age_sec:m(t.heartbeat_age_sec)??null,heartbeat_fresh:G(t.heartbeat_fresh)??!1,claim_marker_seen:G(t.claim_marker_seen)??!1,done_marker_seen:G(t.done_marker_seen)??!1,final_marker_seen:G(t.final_marker_seen)??!1,claim_marker:i,done_marker:r,final_marker:c,last_message:u}}function Nd(t){if(!S(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!S(n))return null;const a=l(n.timestamp),o=m(n.active_slots);if(!a||o==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(r=>typeof r=="number"&&Number.isFinite(r)?r:null).filter(r=>r!=null):[];return{timestamp:a,active_slots:o,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:l(t.slot_url)??null,provider_base_url:l(t.provider_base_url)??null,provider_reachable:G(t.provider_reachable)??null,provider_status_code:m(t.provider_status_code)??null,provider_model_id:l(t.provider_model_id)??null,actual_model_id:l(t.actual_model_id)??null,expected_slots:m(t.expected_slots),actual_slots:m(t.actual_slots),expected_ctx:m(t.expected_ctx),actual_ctx:m(t.actual_ctx),slot_reachable:G(t.slot_reachable)??null,slot_status_code:m(t.slot_status_code)??null,runtime_blocker:l(t.runtime_blocker)??null,detail:l(t.detail)??null,checked_at:l(t.checked_at)??null,total_slots:m(t.total_slots),ctx_per_slot:m(t.ctx_per_slot),active_slots_now:m(t.active_slots_now),peak_active_slots:m(t.peak_active_slots),sample_count:m(t.sample_count),last_sample_at:l(t.last_sample_at)??null,timeline:e}}function Pd(t){const e=S(t)?t:{},n=S(e.summary)?e.summary:void 0;return{version:l(e.version),generated_at:l(e.generated_at),run_id:l(e.run_id),room_id:l(e.room_id),operation_id:l(e.operation_id)??null,recommended_next_tool:l(e.recommended_next_tool),summary:n?{expected_workers:m(n.expected_workers),joined_workers:m(n.joined_workers),live_workers:m(n.live_workers),squad_roster_size:m(n.squad_roster_size),detachment_roster_size:m(n.detachment_roster_size),current_task_bound:m(n.current_task_bound),fresh_heartbeats:m(n.fresh_heartbeats),claim_markers_seen:m(n.claim_markers_seen),done_markers_seen:m(n.done_markers_seen),final_markers_seen:m(n.final_markers_seen),completed_workers:m(n.completed_workers),peak_hot_slots:m(n.peak_hot_slots),hot_window_ok:G(n.hot_window_ok),pass_hot_concurrency:G(n.pass_hot_concurrency),pass_end_to_end:G(n.pass_end_to_end),pending_decisions:m(n.pending_decisions),pass:G(n.pass)}:void 0,provider:Nd(e.provider),operation:xa(e.operation),squad:Gs(e.squad),detachment:gi(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Rd).filter(a=>a!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(wd).filter(a=>a!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Id).filter(a=>a!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Td).filter(a=>a!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(bi).filter(a=>a!==null):[],truth_notes:lt(e.truth_notes)}}function tn(t){_t.value=t,Bs(t)&&Dd()}async function Ai(){Hn.value=!0,Bn.value=null;try{const t=await Wr();Ws.value=pd(t)}catch(t){Bn.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Hn.value=!1}}function Js(t){ye.value=t}async function Vs(){Wn.value=!0,Gn.value=null;try{const t=await Hr();It.value=ud(t)}catch(t){Gn.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Wn.value=!1}}async function Dd(){It.value||Wn.value||await Vs()}async function re(){await Ai(),Bs(_t.value)&&await Vs()}async function Ut(){var t;Cs.value=!0,Xn.value=null;try{const e=await Br(),n=fd(e);ka.value=n;const a=ye.value;n.operations.length===0?ye.value=null:(!a||!n.operations.some(o=>o.operation.operation_id===a))&&(ye.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Xn.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Cs.value=!1}}function Md(){Ee=null,Qe.value=null,Qn.value=!1,Ze.value=null}async function Ld(t){Ee=t,Qn.value=!0,Ze.value=null;try{const e=await Gr(t);if(Ee!==t)return;Qe.value=$d(e)}catch(e){if(Ee!==t)return;Qe.value=null,Ze.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Ee===t&&(Qn.value=!1)}}async function Ed(){Ss.value=!0,Vn.value=null;try{const t=await Jr();dn.value=Cd(t)}catch(t){Vn.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ss.value=!1}}async function Nt(t=Bc(),e=Gc()){As.value=!0,Yn.value=null;try{const n=await Vr(t,e);ba.value=Pd(n)}catch(n){Yn.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{As.value=!1}}async function Yt(t,e,n){xs.value=t,Jn.value=null;try{await Yr(e,n),await Ai(),(It.value||Bs(_t.value))&&await Vs(),await Nt(),await Ut()}catch(a){throw Jn.value=a instanceof Error?a.message:"Failed to execute command-plane action",a}finally{xs.value=null}}function zd(t){return Yt(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Od(t){return Yt(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function jd(t){return Yt(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Fd(t={}){return Yt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function qd(t){return Yt(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Kd(t){return Yt(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Ud(t,e){return Yt(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Hd(t,e){return Yt(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Sc(()=>{re(),Ut(),(_t.value==="swarm"||ba.value!==null)&&Nt()});function Wd(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Y(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Bd(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Gd(t){if(!t)return"n/a";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function O(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let vo=!1,Jd=0,Pa=null;async function Vd(){Pa||(Pa=Wc(()=>import("./mermaid.core-Cm68CFXn.js").then(e=>e.bE),[]).then(e=>e.default));const t=await Pa;return vo||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),vo=!0),t}function Ht(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Sa(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":`${Math.round(t*100)}%`}function Yd(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s`:t<3600?`${Math.round(t/60)}m`:`${Math.round(t/3600)}h`}function un(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function ne(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:un(t/e*100)}function Xd(t,e){const n=un(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Ci(t){if(!t)return"No recent chain history";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`${t.tokens} tokens`),t.message&&e.push(t.message),e.join(" · ")}const Qd=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],wi=[{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Zd=wi.map(t=>t.id),tu=["chain_start","node_start","node_complete","chain_complete","chain_error"],eu={operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function nu(t){return!!t&&Zd.includes(t)}function au(t){if(t==="operations")return{};if(t==="chains"){const e=ye.value;return e?{surface:t,operation:e}:{surface:t}}return{surface:t}}function su(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");return n&&e.set("agent",n),a&&e.set("token",a),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function ou(t){switch(t){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return t}}function nt(t){return xs.value===t}function Aa(){return Ws.value}function iu(t){var o,i,r,c,u,f,d;const e=Ws.value,n=ba.value,a=ka.value;switch(t){case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((o=e==null?void 0:e.operations.summary)==null?void 0:o.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((r=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:r.tool)??"masc_observe_traces",reason:((u=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:u.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(d=(f=a==null?void 0:a.operations[0])==null?void 0:f.preview_run)!=null&&d.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function ru(){const t=_t.value,e=eu[t],n=iu(t);return s`
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
  `}function fn({label:t,value:e,subtext:n,percent:a,color:o}){return s`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Xd(a,o)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(un(a))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function gn({label:t,value:e,detail:n,percent:a,tone:o}){return s`
    <article class="command-signal-rail ${O(o)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${O(o)}" style=${`width: ${Math.max(8,Math.round(un(a)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function lu(){var ct,dt,H,X;const t=Aa(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,a=t==null?void 0:t.detachments.summary,o=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,r=(ct=t==null?void 0:t.swarm_status)==null?void 0:ct.overview,c=t==null?void 0:t.swarm_proof,u=t==null?void 0:t.operations.microarch,f=(e==null?void 0:e.managed_unit_count)??0,d=(e==null?void 0:e.total_units)??0,_=(n==null?void 0:n.active)??0,g=(a==null?void 0:a.active)??0,$=(r==null?void 0:r.moving_lanes)??0,x=(r==null?void 0:r.active_lanes)??0,C=(c==null?void 0:c.workers.done)??0,I=(c==null?void 0:c.workers.expected)??0,L=(i==null?void 0:i.bad)??0,q=(i==null?void 0:i.warn)??0,D=(o==null?void 0:o.pending)??0,T=(o==null?void 0:o.total)??0,N=_+g,p=((dt=u==null?void 0:u.cache)==null?void 0:dt.l1_hit_rate)??((X=(H=u==null?void 0:u.signals)==null?void 0:H.cache_contention)==null?void 0:X.l1_hit_rate)??0,M=_>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",ot=_>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return s`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${M}</h3>
        <p>${ot}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${O(_>0?"ok":"warn")}">활성 작전 ${_}</span>
          <span class="command-chip ${O($>0?"ok":(x>0,"warn"))}">이동 레인 ${$}/${Math.max(x,$)}</span>
          <span class="command-chip ${O(L>0?"bad":q>0?"warn":"ok")}">치명 알림 ${L}</span>
          <span class="command-chip ${O(D>0?"warn":"ok")}">승인 대기 ${D}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${fn}
          label="관리 단위 범위"
          value=${`${f}/${Math.max(d,f)}`}
          subtext=${d>0?`${d-f}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ne(f,Math.max(d,f))}
          color="#67e8f9"
        />
        <${fn}
          label="실행 열도"
          value=${String(N)}
          subtext=${`${_}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ne(N,Math.max(f,N||1))}
          color="#4ade80"
        />
        <${fn}
          label="스웜 이동감"
          value=${`${$}/${Math.max(x,$)}`}
          subtext=${r!=null&&r.last_movement_at?`마지막 이동 ${Y(r.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ne($,Math.max(x,$||1))}
          color="#fbbf24"
        />
        <${fn}
          label="증거 수집률"
          value=${`${C}/${Math.max(I,C)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ne(C,Math.max(I,C||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${gn}
        label="승인 대기열"
        value=${`${D}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${ne(D,Math.max(T,D||1))}
        tone=${D>0?"warn":"ok"}
      />
      <${gn}
        label="알림 압력"
        value=${`${L} bad / ${q} warn`}
        detail=${L>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ne(L*2+q,Math.max((L+q)*2,1))}
        tone=${L>0?"bad":q>0?"warn":"ok"}
      />
      <${gn}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${f>0?`${f}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ne(g,Math.max(f,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${gn}
        label="캐시 신뢰도"
        value=${p?Sa(p):"n/a"}
        detail=${p?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${un((p??0)*100)}
        tone=${p>=.75?"ok":p>=.4?"warn":"bad"}
      />
    </div>
  `}function cu(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Ii(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((o,i)=>{t.has(i)||t.set(i,o)}),t}function du(){const e=Ii().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function uu(){const e=Ii().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function pu(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function mu(t){return t.status==="claimed"||t.status==="in_progress"}function vu(t){const e=dn.value;if(!e)return null;for(const n of e.golden_paths){const a=n.steps.find(o=>o.tool===t);if(a)return a}return null}function Da(t){var e;return((e=dn.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function _u(t){const e=dn.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(a=>n.has(a.id))}async function Wt(t){try{await t()}catch{}}function fu(){var d,_,g,$,x;const t=Aa(),e=ka.value,n=t==null?void 0:t.topology.summary,a=t==null?void 0:t.operations.summary,o=(d=t==null?void 0:t.swarm_status)==null?void 0:d.overview,i=t==null?void 0:t.operations.microarch,r=t==null?void 0:t.decisions.summary,c=t==null?void 0:t.alerts.summary,u=(_=i==null?void 0:i.signals)==null?void 0:_.issue_pressure,f=i==null?void 0:i.cache;return s`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(n==null?void 0:n.total_units)??0}</strong><small>${(n==null?void 0:n.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(a==null?void 0:a.active)??0}</strong><small>${((g=t==null?void 0:t.detachments.summary)==null?void 0:g.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(r==null?void 0:r.pending)??0}</strong><small>${(r==null?void 0:r.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card"><span>알림</span><strong>${(c==null?void 0:c.bad)??0}</strong><small>${(c==null?void 0:c.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=e==null?void 0:e.summary)==null?void 0:$.active_chains)??0}</strong><small>${((x=e==null?void 0:e.summary)==null?void 0:x.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card"><span>스웜</span><strong>${(o==null?void 0:o.active_lanes)??0}</strong><small>${o?`${o.stalled_lanes??0}개 정체 · ${Y(o.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${Sa(f.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function Ti(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function gu({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const o of t){const i=o.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const a=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return s`
    <div>
      <div class="swarm-health-bar">
        ${a.filter(o=>o.count>0).map(o=>s`
          <div class="swarm-health-seg ${o.key}" style="flex: ${o.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${a.filter(o=>o.count>0).map(o=>s`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${o.color}"></span>
            ${o.count} ${o.key}
          </span>
        `)}
      </div>
    </div>
  `}function $u({total:t}){const n=Math.min(t,20),a=t>20?t-20:0,o=Array.from({length:n});return s`
    <div class="swarm-worker-grid">
      ${o.map(()=>s`<span class="swarm-worker-dot present"></span>`)}
      ${a>0?s`<span class="swarm-worker-count">+${a}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function hu({lane:t}){const e=t.counts??{},n=Ti(t),a=e.workers??0,o=e.operations??0,i=e.detachments??0,r=o+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return s`
    <article class="swarm-lane-strip ${O(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${O(n)}">${t.phase}</span>
          <span class="command-chip ${O(n)}">${t.motion_state}</span>
          <span class="command-chip">${Y(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${O(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${a>0?s`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${$u} total=${a} />
              </div>
            `:null}
        ${r>0?s`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${r>0?Math.round(o/r*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${o} · 실행체 ${i}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?s`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?s`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(u=>s`<span class="command-chip ${O(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function yu({lanes:t}){const e=t.slice(0,4);return e.length===0?null:s`
    <div class="swarm-storyboard">
      ${e.map(n=>{const a=Ti(n),o=n.counts.workers??0,i=n.counts.operations??0,r=n.counts.detachments??0;return s`
          <article class="swarm-story-card ${O(a)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${O(a)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${o}</span>
              <span>작전 ${i}</span>
              <span>실행체 ${r}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function bu({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,a=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return s`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${O(t.tone)}"></span>
      <span class="swarm-event-time">${a}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?s`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function ku({gap:t}){return s`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${O(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function xu({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return s`
    <div class="command-guide-card ${O(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${O(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?s`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Y(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?s`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?s`<p>${t.missing_reason}</p>`:null}
          `:s`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Su(){const t=Aa(),e=t==null?void 0:t.swarm_status,n=t==null?void 0:t.swarm_proof,a=(e==null?void 0:e.lanes.filter(f=>f.present))??[],o=(e==null?void 0:e.gaps.items)??[],i=(e==null?void 0:e.timeline.slice(0,8))??[],r=e==null?void 0:e.overview,c=e==null?void 0:e.recommended_next_action,u=a.length<=1;return s`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${z} panelId="command.swarm" compact=${!0} />
      </div>
      ${e?s`
            <${yu} lanes=${a} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(r==null?void 0:r.active_lanes)??0}</strong><small>${(r==null?void 0:r.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(r==null?void 0:r.stalled_lanes)??0}</strong><small>${(r==null?void 0:r.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Y(r==null?void 0:r.last_movement_at)}</strong><small>${e.generated_at?`스냅샷 ${Y(e.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(c==null?void 0:c.label)??"운영자 상태 확인"}</strong><small>${(c==null?void 0:c.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${a.length>0?s`<${gu} lanes=${a} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${a.length>0?a.map(f=>s`<${hu} lane=${f} />`):s`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${(c==null?void 0:c.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(c==null?void 0:c.lane_id)??"전체"}</span>
                  </div>
                  <p>${(c==null?void 0:c.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(c==null?void 0:c.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${xu} proof=${n} />

                <div class="command-guide-card ${o.length>0?"warn":"ok"}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${O(o.some(f=>f.severity==="bad")?"bad":o.length>0?"warn":"ok")}">${o.length}</span>
                  </div>
                  ${o.length>0?s`<div class="swarm-event-rail">${o.slice(0,4).map(f=>s`<${ku} gap=${f} />`)}</div>`:s`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${i.length}</span>
                  </div>
                  ${i.length>0?s`<div class="swarm-event-rail">${i.map(f=>s`<${bu} event=${f} />`)}</div>`:s`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:s`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Au(){return s`
    <div class="command-surface-tabs grouped">
      ${Qd.map(t=>s`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${wi.filter(e=>e.group===t.id).map(e=>s`
                <button
                  class="command-surface-tab ${_t.value===e.id?"active":""}"
                  onClick=${()=>{tn(e.id),et("command",au(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Cu(){var ct,dt,H,X,b,Qt,Re,pn,mn;const t=Aa(),e=It.value,n=Je.value,a=cu(),o=a?ce.value.find(E=>E.name===a)??null:null,i=a?Kt.value.filter(E=>E.assignee===a&&mu(E)):[],r=((ct=t==null?void 0:t.operations.summary)==null?void 0:ct.active)??0,c=((dt=t==null?void 0:t.detachments.summary)==null?void 0:dt.total)??0,u=((H=t==null?void 0:t.decisions.summary)==null?void 0:H.pending)??0,f=e==null?void 0:e.detachments.detachments.find(E=>{const Zt=E.detachment.heartbeat_deadline,vn=Zt?Date.parse(Zt):Number.NaN;return E.detachment.status==="stalled"||!Number.isNaN(vn)&&vn<=Date.now()}),d=e==null?void 0:e.alerts.alerts.find(E=>E.severity==="bad"),_=!!(n!=null&&n.room||n!=null&&n.project),g=(o==null?void 0:o.current_task)??null,$=pu(o==null?void 0:o.last_seen),x=$!=null?$<=120:null,C=[_?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},a?o?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${a} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Kt.value.length>0?"masc_claim":"masc_add_task"}:g?x===!1?{title:"Task 준비도",tone:"warn",detail:`${a} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${a} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${a} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((X=t.topology.summary)==null?void 0:X.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:r===0?{title:"작전 준비도",tone:"warn",detail:`${((b=t.topology.summary)==null?void 0:b.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Qt=t.topology.summary)==null?void 0:Qt.managed_unit_count)??0}개 관리 단위 위에서 ${r}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:r>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:f||d?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${f?` · detachment ${f.detachment.detachment_id} 가 stalled 상태입니다`:""}${d?` · alert ${d.title??d.alert_id}`:""}${!e&&!f&&!d?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],I=_?!a||!o?"masc_join":i.length===0?Kt.value.length>0?"masc_claim":"masc_add_task":g?x===!1?"masc_heartbeat":!t||(((Re=t.topology.summary)==null?void 0:Re.managed_unit_count)??0)===0?"masc_unit_define":r===0?"masc_operation_start":u>0?"masc_policy_approve":r>0&&c===0||f||d?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",L=vu(I),D=_u(I==="masc_set_room"?["repo-root-room"]:I==="masc_plan_set_task"?["claimed-not-current"]:I==="masc_heartbeat"?["heartbeat-stale"]:I==="masc_dispatch_tick"?["no-detachments"]:I==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=Da("room_task_hygiene"),N=Da("cpv2_benchmark"),p=Da("supervisor_session"),M=((pn=dn.value)==null?void 0:pn.docs)??[],ot=[T,N,p].filter(E=>E!==null);return s`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(L==null?void 0:L.title)??I}</strong>
            <span class="command-chip ok">${I}</span>
          </div>
          <p>${(L==null?void 0:L.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(mn=L==null?void 0:L.success_signals)!=null&&mn.length?s`<div class="command-tag-row">
                ${L.success_signals.map(E=>s`<span class="command-tag ok">${E}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${C.map(E=>s`
            <article class="command-readiness-row ${O(E.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${E.title}</strong>
                  <span class="command-chip ${O(E.tone)}">${E.tone}</span>
                </div>
                <p>${E.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${E.tool}</div>
            </article>
          `)}
        </div>

        ${D.length>0?s`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${D.length}</span>
                </div>
                <div class="command-guide-list">
                  ${D.map(E=>s`
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
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        ${Ss.value?s`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Vn.value?s`<div class="empty-state error">${Vn.value}</div>`:s`
                <div class="command-path-grid">
                  ${ot.map(E=>s`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${E.title}</strong>
                        <span class="command-chip">${E.id}</span>
                      </div>
                      <p>${E.summary}</p>
                      <div class="command-card-sub">${E.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${E.steps.slice(0,4).map(Zt=>s`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Zt.tool}</span>
                            <span>${Zt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${M.length>0?s`<div class="command-doc-links">
                      ${M.map(E=>s`<span class="command-tag">${E.title}: ${E.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function wu(){return s`
    <${lu} />
    <${fu} />
    <${Cu} />
  `}function Iu(){return Wn.value?s`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Gn.value?s`<div class="empty-state error">${Gn.value}</div>`:s`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function Ri({node:t,depth:e=0}){const n=t.roster_live??0,a=t.roster_total??t.unit.roster.length,o=t.active_operation_count??0,i=t.unit.policy;return s`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${ou(t.unit.kind)}</span>
            <span class="command-chip ${O(t.health)}">${t.health??"ok"}</span>
            ${i!=null&&i.frozen?s`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?s`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>Leader ${t.unit.leader_id??"unassigned"} / ${t.leader_status??"unknown"}</span>
            <span>Roster ${n}/${a}</span>
            <span>Ops ${o}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          ${t.reasons&&t.reasons.length>0?s`<div class="command-tag-row">
                ${t.reasons.map(r=>s`<span class="command-tag warn">${r}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?s`<div class="command-tree-children">
            ${t.children.map(r=>s`<${Ri} node=${r} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Tu({source:t}){const e=pr(null),[n,a]=Oo(null);return ut(()=>{let o=!1;const i=e.current;return i?(i.innerHTML="",a(null),(async()=>{try{const c=await Vd(),{svg:u}=await c.render(`command-chain-${++Jd}`,t);if(o||!e.current)return;e.current.innerHTML=u}catch(c){if(o)return;a(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{o=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),s`
    <div class="command-chain-graph-shell">
      ${n?s`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Ru({overlay:t,selected:e,onSelect:n}){const a=t.operation.chain,o=t.runtime;return s`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Ht(a==null?void 0:a.status)}">${(a==null?void 0:a.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(a==null?void 0:a.kind)??"chain_dsl"}</span>
        ${a!=null&&a.chain_id?s`<span class="command-tag">${a.chain_id}</span>`:null}
        ${o?s`<span class="command-tag ${Ht(a==null?void 0:a.status)}">${Sa(o.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Ci(t.history)}</div>
    </button>
  `}function Nu({item:t}){return s`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Ht(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Y(t.timestamp)}</div>
      <div class="command-card-sub">${Ci(t)}</div>
    </article>
  `}function Pu({node:t}){return s`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${Ht(t.status)}">${t.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"node"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?s`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Du({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,a=`resume:${e.operation_id}`,o=`recall:${e.operation_id}`,i=e.chain,r=(i==null?void 0:i.run_id)??null;return s`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${O(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Autonomy</span><span>${e.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${e.budget_class??"standard"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Updated</span><span>${Y(e.updated_at)}</span>
      </div>
      ${i?s`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${Ht(i.status)}">${i.status}</span>
              ${i.chain_id?s`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?s`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?s`<div class="command-card-foot">Checkpoint ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{tn("swarm"),et("command",{surface:"swarm",operation_id:e.operation_id,...r?{run_id:r}:{}})}}
        >
          Swarm Live
        </button>
        ${i?s`
              <button
                class="control-btn ghost"
                onClick=${()=>{Js(e.operation_id),tn("chains"),et("command",{surface:"chains",operation:e.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?s`
              <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Wt(()=>zd(e.operation_id))}>
                ${nt(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${nt(o)} onClick=${()=>Wt(()=>jd(e.operation_id))}>
                ${nt(o)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?s`
              <button class="control-btn ghost" disabled=${nt(a)} onClick=${()=>Wt(()=>Od(e.operation_id))}>
                ${nt(a)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Mu({card:t}){var n;const e=t.detachment;return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${O(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>Leader</span><span>${e.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${e.roster.length}</span>
        <span>Session</span><span>${e.session_id??"none"}</span>
        <span>Runtime</span><span>${e.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${e.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Y(e.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Gd(e.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Y(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?s`<span class="command-tag ${Bd(e.heartbeat_deadline)}">
              deadline ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Lu({alert:t}){return s`
    <article class="command-alert ${O(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${O(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"scope"}:${t.scope_id??"n/a"}</span>
        <span>${Y(t.timestamp)}</span>
      </div>
      ${t.detail?s`<p>${t.detail}</p>`:null}
    </article>
  `}function Ni({event:t}){return s`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Y(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Wd(t.detail)}</pre>
    </article>
  `}function Eu({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,a=t.source==="projected_operator";return s`
    <article class="command-card ${O(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${O(t.status)}">${t.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${t.decision_id}</span>
        <span>By</span><span>${t.requested_by??"unknown"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Created</span><span>${Y(t.created_at)}</span>
        <span>Reason</span><span>${t.reason??"n/a"}</span>
      </div>
      ${t.status==="pending"&&!a?s`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${nt(e)} onClick=${()=>Wt(()=>qd(t.decision_id))}>
                ${nt(e)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Wt(()=>Kd(t.decision_id))}>
                ${nt(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${a?s`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function zu({row:t}){var c,u,f;const e=t.unit,n=`freeze:${e.unit_id}`,a=`kill:${e.unit_id}`,o=!!((c=e.policy)!=null&&c.frozen),i=!!((u=e.policy)!=null&&u.kill_switch),r=Math.round((t.utilization??0)*100);return s`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${O(r>100?"bad":r>70?"warn":"ok")}">${r}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>Headcount Cap</span><span>${t.headcount_cap??0}</span>
        <span>Ops</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((f=e.policy)==null?void 0:f.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${o?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${nt(n)} onClick=${()=>Wt(()=>Ud(e.unit_id,!o))}>
          ${nt(n)?"Applying…":o?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${nt(a)} onClick=${()=>Wt(()=>Hd(e.unit_id,!i))}>
          ${nt(a)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Ou({item:t}){return s`
    <article class="command-guide-card ${O(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${O(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function ju({blocker:t}){return s`
    <article class="command-alert ${O(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${O(t.severity)}">${t.severity}</span>
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
        <span class="command-chip ${O(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?s`<div class="command-card-foot">${Y(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function qu(){var u,f,d,_,g,$,x,C,I,L,q,D,T,N,p,M,ot,ct,dt,H,X;const t=ba.value,e=du(),n=uu(),a=(u=t==null?void 0:t.provider)!=null&&u.runtime_blocker?"blocked":(f=t==null?void 0:t.provider)!=null&&f.provider_reachable?"ready":"check",o=((d=t==null?void 0:t.provider)==null?void 0:d.actual_slots)??((_=t==null?void 0:t.provider)==null?void 0:_.total_slots)??0,i=((g=t==null?void 0:t.provider)==null?void 0:g.expected_slots)??"n/a",r=(($=t==null?void 0:t.provider)==null?void 0:$.actual_ctx)??((x=t==null?void 0:t.provider)==null?void 0:x.ctx_per_slot)??0,c=((C=t==null?void 0:t.provider)==null?void 0:C.expected_ctx)??"n/a";return s`
    <div class="command-section-stack">
      <${Su} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${As.value?s`<div class="empty-state">Loading swarm live state…</div>`:Yn.value?s`<div class="empty-state error">${Yn.value}</div>`:t?s`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((I=t.summary)==null?void 0:I.joined_workers)??0}/${((L=t.summary)==null?void 0:L.expected_workers)??0}</strong><small>${((q=t.summary)==null?void 0:q.live_workers)??0}개 가동 · ${((D=t.summary)==null?void 0:D.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${a}</strong><small>slots ${o}/${i} · ctx ${r}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=t.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((N=t.provider)==null?void 0:N.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(p=t.summary)!=null&&p.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((M=t.operation)==null?void 0:M.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((ot=t.squad)==null?void 0:ot.label)??"없음"}</span>
                      <span>실행체</span><span>${((ct=t.detachment)==null?void 0:ct.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((dt=t.summary)==null?void 0:dt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((H=t.summary)==null?void 0:H.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((X=t.provider)==null?void 0:X.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?s`<div class="command-tag-row">
                          ${t.truth_notes.map(b=>s`<span class="command-tag">${b}</span>`)}
                        </div>`:null}
                  `:s`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?s`<div class="command-card-stack">
                ${t.checklist.map(b=>s`<${Ou} item=${b} />`)}
              </div>`:s`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?s`<div class="command-card-stack">
                ${t.workers.map(b=>s`<${Fu} worker=${b} />`)}
              </div>`:s`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?Y(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?Y(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?s`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?s`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(b=>s`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${b.active_slots} active</strong>
                              <span class="command-chip">${Y(b.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${b.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:s`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:s`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?s`<div class="command-card-stack">
                ${t.blockers.map(b=>s`<${ju} blocker=${b} />`)}
              </div>`:s`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?s`<div class="command-trace-stack">
                ${t.recent_messages.map(b=>s`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${b.from}</strong>
                        <span class="command-chip">${Y(b.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${b.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${b.content}</pre>
                  </article>
                `)}
              </div>`:s`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${z} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?s`<div class="command-trace-stack">
                ${t.recent_trace_events.map(b=>s`<${Ni} event=${b} />`)}
              </div>`:s`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Ku(){const t=It.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?s`<div class="command-card-stack">
              ${t.operations.operations.map(e=>s`<${Du} card=${e} />`)}
            </div>`:s`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?s`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>s`<${Mu} card=${e} />`)}
            </div>`:s`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Uu(){var c,u,f,d,_,g,$,x,C,I,L,q,D,T,N,p;const t=ka.value,e=(t==null?void 0:t.operations)??[],n=ye.value,a=e.find(M=>M.operation.operation_id===n)??e[0]??null,o=((c=a==null?void 0:a.operation.chain)==null?void 0:c.run_id)??null,i=((u=Qe.value)==null?void 0:u.run)??(a==null?void 0:a.preview_run)??null,r=!((f=Qe.value)!=null&&f.run)&&!!(a!=null&&a.preview_run);return ut(()=>{o?Ld(o):Md()},[o]),s`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Ht(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Ht(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(t==null?void 0:t.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((d=t==null?void 0:t.summary)==null?void 0:d.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((_=t==null?void 0:t.summary)==null?void 0:_.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=t==null?void 0:t.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${Y(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Xn.value?s`<div class="empty-state error">${Xn.value}</div>`:null}

        ${Cs.value&&!t?s`<div class="empty-state">Loading chain overlays…</div>`:e.length>0?s`
                <div class="command-chain-list">
                  ${e.map(M=>s`
                    <${Ru}
                      overlay=${M}
                      selected=${(a==null?void 0:a.operation.operation_id)===M.operation.operation_id}
                      onSelect=${()=>Js(M.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(M=>s`<${Nu} item=${M} />`)}
                </div>
              `:s`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        ${a?s`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${a.operation.objective}</strong>
                    <div class="command-card-sub">${a.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Ht((x=a.operation.chain)==null?void 0:x.status)}">
                    ${((C=a.operation.chain)==null?void 0:C.status)??a.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((I=a.operation.chain)==null?void 0:I.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((L=a.operation.chain)==null?void 0:L.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${o??"not materialized"}</span>
                  <span>Progress</span><span>${Sa((q=a.runtime)==null?void 0:q.progress)}</span>
                  <span>Elapsed</span><span>${Yd((D=a.runtime)==null?void 0:D.elapsed_sec)}</span>
                  <span>Updated</span><span>${Y(((T=a.operation.chain)==null?void 0:T.last_sync_at)??a.operation.updated_at)}</span>
                </div>
                ${(N=a.operation.chain)!=null&&N.goal?s`<div class="command-card-foot">${a.operation.chain.goal}</div>`:null}
              </article>

              ${a.mermaid?s`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((p=a.operation.chain)==null?void 0:p.chain_id)??"graph"}</span>
                      </div>
                      <${Tu} source=${a.mermaid} />
                    </div>
                  `:s`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":r?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Qn.value?s`<div class="empty-state">Loading run detail…</div>`:Ze.value?s`<div class="empty-state error">${Ze.value}</div>`:i&&i.nodes.length>0?s`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${r?s`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(M=>s`<${Pu} node=${M} />`)}
                          </div>
                        `:s`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:s`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Hu(){const t=It.value;return s`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${z} panelId="command.topology" compact=${!0} />
      </div>
      ${t&&t.topology.units.length>0?s`${t.topology.units.map(e=>s`<${Ri} node=${e} />`)}`:s`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Wu(){const t=It.value;return s`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${z} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?s`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>s`<${Lu} alert=${e} />`)}
          </div>`:s`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Bu(){const t=It.value;return s`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${z} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?s`<div class="command-trace-stack">
            ${t.traces.events.map(e=>s`<${Ni} event=${e} />`)}
          </div>`:s`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Gu(){const t=It.value;return s`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?s`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>s`<${Eu} decision=${e} />`)}
            </div>`:s`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?s`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>s`<${zu} row=${e} />`)}
            </div>`:s`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Ju(){if(_t.value==="summary")return s`<${wu} />`;if(_t.value==="swarm")return s`<${qu} />`;if(!It.value)return s`<${Iu} />`;switch(_t.value){case"chains":return s`<${Uu} />`;case"topology":return s`<${Hu} />`;case"alerts":return s`<${Wu} />`;case"trace":return s`<${Bu} />`;case"control":return s`<${Gu} />`;case"operations":default:return s`<${Ku} />`}}function Vu(){return ut(()=>{re(),Ut(),Ed(),Nt()},[]),ut(()=>{if(Q.value.tab!=="command")return;const t=Q.value.params.surface,e=Q.value.params.operation;nu(t)?tn(t):t||tn("operations"),e&&Js(e),t==="swarm"&&Nt()},[Q.value.tab,Q.value.params.surface,Q.value.params.operation,Q.value.params.operation_id,Q.value.params.run_id]),ut(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,re(),Ut(),_t.value==="swarm"&&Nt()},250))},n=new EventSource(su()),a=tu.map(o=>{const i=()=>e();return n.addEventListener(o,i),{type:o,handler:i}});return n.onerror=()=>{e()},()=>{a.forEach(({type:o,handler:i})=>{n.removeEventListener(o,i)}),n.close(),t&&window.clearTimeout(t)}},[]),s`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 현재 작전입니다. 여기서는 지금 무엇이 움직이고 막히는지 확인한 뒤, 필요한 surface로만 더 깊게 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Wt(()=>Fd())}}
            disabled=${nt("dispatch:tick")}
          >
            ${nt("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{re(),Ut(),Nt()}}
            disabled=${Hn.value}
          >
            ${Hn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Bn.value?s`<div class="empty-state error">${Bn.value}</div>`:null}
      ${Jn.value?s`<div class="empty-state error">${Jn.value}</div>`:null}
      <${$t} surfaceId="command" />
      <${ru} />
      <${Au} />
      <${Ju} />
    </section>
  `}let Yu=0;const se=v([]);function R(t,e="success",n=4e3){const a=++Yu;se.value=[...se.value,{id:a,message:t,type:e}],setTimeout(()=>{se.value=se.value.filter(o=>o.id!==a)},n)}function Xu(t){se.value=se.value.filter(e=>e.id!==t)}function Qu(){const t=se.value;return t.length===0?null:s`
    <div class="toast-container">
      ${t.map(e=>s`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Xu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const we=v(null),Pi=v(null),Lt=v(null),Zn=v(!1),Gt=v(null),en=v(!1),xe=v(null),W=v(!1),ta=v([]);let Zu=1;function F(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function V(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ca(t){return typeof t=="boolean"?t:void 0}function tp(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function St(t,e=[]){if(Array.isArray(t))return t;if(!F(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function ep(t){return F(t)?{id:k(t.id),seq:V(t.seq),from:k(t.from)??k(t.from_agent)??"system",content:k(t.content)??"",timestamp:k(t.timestamp)??new Date().toISOString(),type:k(t.type)}:null}function np(t){return F(t)?{room_id:k(t.room_id),current_room:k(t.current_room)??k(t.room),project:k(t.project),cluster:k(t.cluster),paused:Ca(t.paused),pause_reason:k(t.pause_reason)??null,paused_by:k(t.paused_by)??null,paused_at:k(t.paused_at)??null}:{}}function _o(t){if(!F(t))return;const e=Object.entries(t).map(([n,a])=>{const o=k(a);return o?[n,o]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Di(t){if(!F(t))return null;const e=k(t.kind),n=k(t.summary),a=k(t.target_type);return!e||!n||!a?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:a,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function Mi(t){if(!F(t))return null;const e=k(t.action_type),n=k(t.target_type),a=k(t.reason);return!e||!n||!a?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:a,confirm_required:Ca(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function ap(t){return F(t)?{actor:k(t.actor)??null,spawn_agent:k(t.spawn_agent)??null,spawn_role:k(t.spawn_role)??null,spawn_model:k(t.spawn_model)??null,worker_class:k(t.worker_class)??null,parent_actor:k(t.parent_actor)??null,capsule_mode:k(t.capsule_mode)??null,runtime_pool:k(t.runtime_pool)??null,lane_id:k(t.lane_id)??null,controller_level:k(t.controller_level)??null,control_domain:k(t.control_domain)??null,supervisor_actor:k(t.supervisor_actor)??null,model_tier:k(t.model_tier)??null,task_profile:k(t.task_profile)??null,risk_level:k(t.risk_level)??null,routing_confidence:V(t.routing_confidence)??null,routing_reason:k(t.routing_reason)??null,status:k(t.status)??"unknown",turn_count:V(t.turn_count)??0,empty_note_turn_count:V(t.empty_note_turn_count)??0,has_turn:Ca(t.has_turn)??!1,last_turn_ts_iso:k(t.last_turn_ts_iso)??null}:null}function sp(t){if(!F(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:V(t.planned_worker_count),active_agent_count:V(t.active_agent_count),last_turn_age_sec:V(t.last_turn_age_sec)??null,attention_count:V(t.attention_count),recommended_action_count:V(t.recommended_action_count),top_attention:Di(t.top_attention),top_recommendation:Mi(t.top_recommendation)}:null}function Li(t){const e=F(t)?t:{};return{trace_id:k(e.trace_id),target_type:k(e.target_type)??"room",target_id:k(e.target_id)??null,health:k(e.health),swarm_status:F(e.swarm_status)?e.swarm_status:void 0,attention_items:St(e.attention_items).map(Di).filter(n=>n!==null),recommended_actions:St(e.recommended_actions).map(Mi).filter(n=>n!==null),session_cards:St(e.session_cards).map(sp).filter(n=>n!==null),worker_cards:St(e.worker_cards).map(ap).filter(n=>n!==null)}}function op(t){if(!F(t))return null;const e=F(t.status)?t.status:void 0,n=F(t.summary)?t.summary:F(e==null?void 0:e.summary)?e.summary:void 0,a=F(t.session)?t.session:F(e==null?void 0:e.session)?e.session:void 0,o=k(t.session_id)??k(n==null?void 0:n.session_id)??k(a==null?void 0:a.session_id);if(!o)return null;const i=_o(t.report_paths)??_o(e==null?void 0:e.report_paths),r=St(t.recent_events,["events"]).filter(F);return{session_id:o,status:k(t.status)??k(n==null?void 0:n.status)??k(a==null?void 0:a.status),progress_pct:V(t.progress_pct)??V(n==null?void 0:n.progress_pct),elapsed_sec:V(t.elapsed_sec)??V(n==null?void 0:n.elapsed_sec),remaining_sec:V(t.remaining_sec)??V(n==null?void 0:n.remaining_sec),done_delta_total:V(t.done_delta_total)??V(n==null?void 0:n.done_delta_total),summary:n,team_health:F(t.team_health)?t.team_health:F(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:F(t.communication_metrics)?t.communication_metrics:F(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:F(t.orchestration_state)?t.orchestration_state:F(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:F(t.cascade_metrics)?t.cascade_metrics:F(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function ip(t){if(!F(t))return null;const e=k(t.name);if(!e)return null;const n=F(t.context)?t.context:void 0;return{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:V(t.context_ratio)??V(n==null?void 0:n.context_ratio),generation:V(t.generation),active_goal_ids:tp(t.active_goal_ids),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:V(t.last_turn_ago_s),model:k(t.model)??k(t.active_model)??k(t.primary_model)}}function rp(t){if(!F(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function lp(t){const e=F(t)?t:{};return{room:np(e.room),sessions:St(e.sessions,["items","sessions"]).map(op).filter(n=>n!==null),keepers:St(e.keepers,["items","keepers"]).map(ip).filter(n=>n!==null),recent_messages:St(e.recent_messages,["messages"]).map(ep).filter(n=>n!==null),pending_confirms:St(e.pending_confirms,["items","confirms"]).map(rp).filter(n=>n!==null),available_actions:St(e.available_actions,["actions"]).filter(F).map(n=>({action_type:k(n.action_type)??"unknown",target_type:k(n.target_type)??"unknown",description:k(n.description),confirm_required:Ca(n.confirm_required)}))}}function $n(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function fo(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ea(t){ta.value=[{...t,id:Zu++,at:new Date().toISOString()},...ta.value].slice(0,20)}function Ei(t){return t.confirm_required?$n(t.preview)||"Confirmation required":$n(t.result)||$n(t.executed_action)||$n(t.delegated_tool_result)||t.status}async function Jt(){Zn.value=!0,Gt.value=null;try{const t=await Ur();we.value=lp(t)}catch(t){Gt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Zn.value=!1}}async function Et(){en.value=!0,xe.value=null;try{const t=await Vo({targetType:"room"});Pi.value=Li(t)}catch(t){xe.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{en.value=!1}}async function nn(t){if(!t){Lt.value=null;return}en.value=!0,xe.value=null;try{const e=await Vo({targetType:"team_session",targetId:t,includeWorkers:!0});Lt.value=Li(e)}catch(e){xe.value=e instanceof Error?e.message:"Failed to load session digest"}finally{en.value=!1}}async function cp(t){var e;W.value=!0,Gt.value=null;try{const n=await fa(t);return ea({actor:t.actor,action_type:t.action_type,target_label:fo(t),outcome:n.confirm_required?"preview":"executed",message:Ei(n),delegated_tool:n.delegated_tool}),await Jt(),await Et(),(e=Lt.value)!=null&&e.target_id&&await nn(Lt.value.target_id),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";throw Gt.value=a,ea({actor:t.actor,action_type:t.action_type,target_label:fo(t),outcome:"error",message:a}),n}finally{W.value=!1}}async function dp(t,e){var n;W.value=!0,Gt.value=null;try{const a=await Qr(t,e);return ea({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Ei(a),delegated_tool:a.delegated_tool}),await Jt(),await Et(),(n=Lt.value)!=null&&n.target_id&&await nn(Lt.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw Gt.value=o,ea({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:o}),a}finally{W.value=!1}}Ac(()=>{var t;Jt(),Et(),(t=Lt.value)!=null&&t.target_id&&nn(Lt.value.target_id)});const zi="masc_dashboard_agent_name";function up(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(zi))==null?void 0:a.trim())||"dashboard"}const wa=v(up()),Oe=v(""),ws=v("운영 점검"),je=v(""),na=v(""),Is=v("2"),aa=v(""),qt=v("note"),sa=v(""),oa=v(""),ia=v(""),Ts=v("2"),Rs=v("운영자 중지 요청"),Ns=v(""),Fe=v("");function pp(t){const e=t.trim()||"dashboard";wa.value=e,localStorage.setItem(zi,e)}function go(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function mp(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Se(t){return typeof t=="string"?t.trim().toLowerCase():""}function vp(t){var a;const e=Se(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=Se((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Ma(t){const e=Se(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function $o(t){return t.some(e=>Se(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function _p(t){return t.target_type==="team_session"}function fp(t){return t.target_type==="keeper"}function hn(t){switch(t){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";default:return(t==null?void 0:t.trim())||"액션"}}function yn(t){switch(t){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";default:return(t==null?void 0:t.trim())||"target"}}function Me(t){switch(Se(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function ho(t){return t?"확인 후 실행":"즉시 실행"}function gp(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return t}}async function Ie(t){const e=wa.value.trim()||"dashboard";try{const n=await cp({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?R("확인 대기열에 올렸습니다","warning"):R(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"개입 실행에 실패했습니다";return R(a,"error"),null}}async function yo(){const t=Oe.value.trim();if(!t)return;await Ie({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(Oe.value="")}async function $p(){await Ie({action_type:"room_pause",target_type:"room",payload:{reason:ws.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function bo(){await Ie({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function hp(){const t=je.value.trim();if(t)try{await Il(t,na.value.trim()||"Intervene 화면에서 주입",Number.parseInt(Is.value,10)||2),R("작업을 backlog에 추가했습니다","success"),je.value="",na.value=""}catch(e){const n=e instanceof Error?e.message:"작업 추가에 실패했습니다";R(n,"error")}}async function yp(){var r;const t=we.value,e=aa.value||((r=t==null?void 0:t.sessions[0])==null?void 0:r.session_id)||"";if(!e){R("먼저 세션을 고르세요","warning");return}const n={},a=sa.value.trim();a&&(n.message=a);let o="team_note";qt.value==="broadcast"?o="team_broadcast":qt.value==="task"&&(o="team_task_inject"),qt.value==="task"&&(n.task_title=oa.value.trim()||"운영자 주입 작업",n.task_description=ia.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Ts.value,10)||2),await Ie({action_type:o,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(sa.value="",qt.value==="task"&&(oa.value="",ia.value=""))}async function bp(){var n;const t=we.value,e=aa.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){R("먼저 세션을 고르세요","warning");return}await Ie({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Rs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function kp(){var o;const t=we.value,e=Ns.value||((o=t==null?void 0:t.keepers[0])==null?void 0:o.name)||"",n=Fe.value.trim();if(!e){R("먼저 keeper를 고르세요","warning");return}if(!n)return;await Ie({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(Fe.value="")}async function xp(t){const e=wa.value.trim()||"dashboard";try{await dp(e,t),R("확인 실행을 완료했습니다","success")}catch(n){const a=n instanceof Error?n.message:"확인 실행에 실패했습니다";R(a,"error")}}function Sp(){var D,T,N;const t=we.value,e=Pi.value,n=Lt.value,a=(t==null?void 0:t.room)??{},o=(t==null?void 0:t.sessions)??[],i=(t==null?void 0:t.keepers)??[],r=(t==null?void 0:t.pending_confirms)??[],c=(t==null?void 0:t.recent_messages)??[],u=(e==null?void 0:e.recommended_actions)??[],f=(t==null?void 0:t.available_actions)??[],d=o.find(p=>p.session_id===aa.value)??o[0]??null,_=i.find(p=>p.name===Ns.value)??i[0]??null,g=(e==null?void 0:e.attention_items)??[],$=g.filter(_p),x=g.filter(fp),C=o.filter(p=>vp(p)!=="ok"),I=i.filter(p=>Ma(p)!=="ok"),L=c.slice(0,5);ut(()=>{Et()},[]),ut(()=>{const p=(d==null?void 0:d.session_id)??null;nn(p)},[d==null?void 0:d.session_id]);const q=[{key:"room",label:"Room 게이트",value:a.paused?"일시정지":"열림",detail:a.paused?`재개 전환 대기 중${a.pause_reason?` · ${a.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:a.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:r.length,detail:r.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:r.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:$.length>0?$.length:o.length,detail:$.length>0?((D=$[0])==null?void 0:D.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":o.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:$.length>0?$o($):o.length===0?"warn":C.some(p=>Se(p.status)==="paused")?"bad":C.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:x.length>0?x.length:I.length,detail:x.length>0?((T=x[0])==null?void 0:T.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":I.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:x.length>0?$o(x):I.some(p=>Ma(p)==="bad")?"bad":I.length>0?"warn":"ok"}];return s`
    <section class="ops-view">
      <${$t} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${z} panelId="intervene.action_studio" compact=${!0} />
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
            value=${wa.value}
            onInput=${p=>pp(p.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{Jt(),Et(),nn((d==null?void 0:d.session_id)??null)}}
            disabled=${Zn.value||W.value}
          >
            ${Zn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Gt.value?s`<section class="ops-banner error">${Gt.value}</section>`:null}
      ${xe.value?s`<section class="ops-banner error">${xe.value}</section>`:null}

      ${(()=>{const p=[];if(r.length>0&&p.push({label:`확인 대기 ${r.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const M=document.querySelector(".ops-pending-section");M==null||M.scrollIntoView({behavior:"smooth"})}}),a.paused&&p.push({label:"Room 재개",desc:`현재 일시정지 상태${a.pause_reason?` (${a.pause_reason})`:""}`,tone:"warn",onClick:()=>void bo()}),I.length>0){const M=I.filter(ot=>Ma(ot)==="bad");p.push({label:M.length>0?`Keeper ${M.length}개 오프라인`:`Keeper ${I.length}개 점검 필요`,desc:M.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:M.length>0?"bad":"warn",onClick:()=>{const ot=document.querySelector(".ops-keeper-section");ot==null||ot.scrollIntoView({behavior:"smooth"})}})}return p.length===0?null:s`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${p.slice(0,3).map(M=>s`
                <button class="ops-action-guide-item ${M.tone}" onClick=${M.onClick}>
                  <strong>${M.label}</strong>
                  <span>${M.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${z} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${q.map(p=>s`
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
            <div class="card-title-row">
              <div class="card-title">Room 개입</div>
              <${z} panelId="intervene.action_studio" compact=${!0} />
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
                value=${Oe.value}
                onInput=${p=>{Oe.value=p.target.value}}
                onKeyDown=${p=>{p.key==="Enter"&&yo()}}
                disabled=${W.value}
              />
              <button class="control-btn" onClick=${()=>{yo()}} disabled=${W.value||Oe.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row ops-split-row">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${ws.value}
                onInput=${p=>{ws.value=p.target.value}}
                disabled=${W.value}
              />
              <button class="control-btn ghost" onClick=${()=>{$p()}} disabled=${W.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{bo()}} disabled=${W.value}>
                재개
              </button>
            </div>

            <div class="ops-section-head">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${je.value}
              onInput=${p=>{je.value=p.target.value}}
              disabled=${W.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${na.value}
              onInput=${p=>{na.value=p.target.value}}
              disabled=${W.value}
            ></textarea>
            <div class="control-row ops-split-row">
              <select
                class="control-input ops-select"
                value=${Is.value}
                onChange=${p=>{Is.value=p.target.value}}
                disabled=${W.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{hp()}} disabled=${W.value||je.value.trim()===""}>
                주입
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">추천 개입</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
            ${en.value&&!e?s`
              <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
            `:u.length>0?s`
              <div class="ops-log-list">
                ${u.map(p=>s`
                  <article key=${`${p.action_type}:${p.target_type}:${p.target_id??"room"}`} class="ops-log-entry ${p.severity}">
                    <div class="ops-log-head">
                      <strong>${hn(p.action_type)}</strong>
                      <span>${yn(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                      <span>${ho(p.confirm_required)}</span>
                    </div>
                    <div class="ops-log-body">${p.reason}</div>
                  </article>
                `)}
              </div>
            `:s`
              <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
            `}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">승인 대기</div>
              <${z} panelId="intervene.pending_confirmations" compact=${!0} />
            </div>
            <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
            ${r.length>0?s`
              <div class="ops-confirmation-list">
                ${r.map(p=>s`
                  <article key=${p.confirm_token} class="ops-confirmation-card">
                    <div class="ops-confirmation-meta">
                      <strong>${hn(p.action_type)}</strong>
                      <span>${yn(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                      <span>${p.delegated_tool??"위임 도구 확인 필요"}</span>
                    </div>
                    ${p.preview?s`<pre class="ops-code-block compact">${go(p.preview)}</pre>`:null}
                    <div class="ops-confirmation-actions">
                      <button class="control-btn" onClick=${()=>{xp(p.confirm_token)}} disabled=${W.value}>
                        실행
                      </button>
                      <span class="ops-token">${p.confirm_token}</span>
                    </div>
                  </article>
                `)}
              </div>
            `:s`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 Room 메시지</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
            ${L.length>0?s`
              <div class="ops-feed-list">
                ${L.map(p=>s`
                  <article key=${p.seq??p.id??p.timestamp} class="ops-feed-item">
                    <div class="ops-feed-meta">
                      <strong>${p.from}</strong>
                      <span>${p.timestamp}</span>
                    </div>
                    <div class="ops-feed-content">${p.content}</div>
                  </article>
                `)}
              </div>
            `:s`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Session 개입</div>
              <${z} panelId="intervene.session_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

            <div class="ops-entity-list">
              ${o.length===0?s`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:o.map(p=>{var M;return s`
                <button
                  key=${p.session_id}
                  class="ops-entity-card ${(d==null?void 0:d.session_id)===p.session_id?"active":""}"
                  onClick=${()=>{aa.value=p.session_id}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${p.session_id}</strong>
                    <span class="status-badge ${p.status??"idle"}">${Me(p.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${Math.round(p.progress_pct??0)}%</span>
                    <span>${p.done_delta_total??0}건 완료</span>
                    <span>${(M=p.team_health)!=null&&M.status?Me(String(p.team_health.status)):"상태 확인 필요"}</span>
                  </div>
                </button>
              `})}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 요약</div>
              <${z} panelId="intervene.session_digest" compact=${!0} />
            </div>
            <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
            ${d&&n?s`
              <div class="ops-log-list">
                ${n.attention_items.length>0?n.attention_items.map(p=>s`
                  <article key=${`${p.kind}:${p.target_id??"session"}`} class="ops-log-entry ${p.severity}">
                    <div class="ops-log-head">
                      <strong>${p.kind}</strong>
                      <span>${yn(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                    </div>
                    <div class="ops-log-body">${p.summary}</div>
                  </article>
                `):s`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
                ${n.worker_cards.length>0?n.worker_cards.map(p=>s`
                  <article key=${`${p.actor??p.spawn_role??"worker"}:${p.spawn_agent??p.runtime_pool??"runtime"}`} class="ops-log-entry">
                    <div class="ops-log-head">
                      <strong>${p.actor??p.spawn_role??"worker"}</strong>
                      <span>${Me(p.status)}</span>
                      <span>${p.spawn_agent??p.runtime_pool??"runtime 확인 필요"}</span>
                    </div>
                    <div class="ops-log-body">
                      ${p.worker_class??"worker"}${p.lane_id?` · ${p.lane_id}`:""}${p.routing_reason?` · ${p.routing_reason}`:""}
                    </div>
                  </article>
                `):null}
              </div>
            `:s`
              <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
            `}
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Session 액션</div>
              <${z} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

            ${d?s`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${d.session_id}</div>
                <div class="ops-detail-meta">
                  <span>상태: ${Me(d.status)}</span>
                  <span>경과: ${d.elapsed_sec??0}초</span>
                  <span>남은 시간: ${d.remaining_sec??0}초</span>
                </div>
                ${d.recent_events&&d.recent_events.length>0?s`
                  <pre class="ops-code-block compact">${go(d.recent_events.slice(-3))}</pre>
                `:null}
              </div>
            `:s`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

            <label class="control-label" for="ops-turn-kind">세션 액션</label>
            <div class="control-row ops-split-row">
              <select
                id="ops-turn-kind"
                class="control-input ops-select"
                value=${qt.value}
                onChange=${p=>{qt.value=p.target.value}}
                disabled=${W.value||!d}
              >
                <option value="note">노트</option>
                <option value="broadcast">방송</option>
                <option value="task">작업</option>
              </select>
              <button class="control-btn" onClick=${()=>{yp()}} disabled=${W.value||!d}>
                적용
              </button>
            </div>
            <div class="ops-context-note">현재 선택: ${gp(qt.value)}</div>

            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="세션에 남길 메시지"
              value=${sa.value}
              onInput=${p=>{sa.value=p.target.value}}
              disabled=${W.value||!d}
            ></textarea>

            ${qt.value==="task"?s`
              <input
                class="control-input"
                type="text"
                placeholder="주입할 작업 제목"
                value=${oa.value}
                onInput=${p=>{oa.value=p.target.value}}
                disabled=${W.value||!d}
              />
              <textarea
                class="control-textarea"
                rows=${2}
                placeholder="주입할 작업 설명"
                value=${ia.value}
                onInput=${p=>{ia.value=p.target.value}}
                disabled=${W.value||!d}
              ></textarea>
              <select
                class="control-input ops-select"
                value=${Ts.value}
                onChange=${p=>{Ts.value=p.target.value}}
                disabled=${W.value||!d}
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
                value=${Rs.value}
                onInput=${p=>{Rs.value=p.target.value}}
                disabled=${W.value||!d}
              />
              <button class="control-btn ghost" onClick=${()=>{bp()}} disabled=${W.value||!d}>
                세션 중지
              </button>
            </div>
          </section>
        </div>

        <div class="ops-column">
          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">Keeper 개입</div>
              <${z} panelId="intervene.keeper_queue" compact=${!0} />
            </div>
            <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

            <div class="ops-entity-list">
              ${i.length===0?s`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:i.map(p=>s`
                <button
                  key=${p.name}
                  class="ops-entity-card ${(_==null?void 0:_.name)===p.name?"active":""}"
                  onClick=${()=>{Ns.value=p.name}}
                >
                  <div class="ops-entity-title-row">
                    <strong>${p.name}</strong>
                    <span class="status-badge ${p.status??"idle"}">${Me(p.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>${p.model??"model 확인 필요"}</span>
                    <span>${typeof p.context_ratio=="number"?`${Math.round(p.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                    <span>${mp(p.last_turn_ago_s)}</span>
                  </div>
                </button>
              `)}
            </div>
          </section>

          <section class="card ops-panel ops-lane-panel">
            <div class="card-title-row">
              <div class="card-title">선택한 Keeper 액션</div>
              <${z} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

            ${_?s`
              <div class="ops-detail-card">
                <div class="ops-detail-title">${_.name}</div>
                <div class="ops-detail-meta">
                  <span>자율성: ${_.autonomy_level??"확인 없음"}</span>
                  <span>세대: ${_.generation??0}</span>
                  <span>활성 목표: ${((N=_.active_goal_ids)==null?void 0:N.length)??0}</span>
                </div>
              </div>
            `:s`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

            <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
            <textarea
              id="ops-keeper-message"
              class="control-textarea"
              rows=${6}
              placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
              value=${Fe.value}
              onInput=${p=>{Fe.value=p.target.value}}
              disabled=${W.value||!_}
            ></textarea>
            <div class="control-row">
              <button class="control-btn" onClick=${()=>{kp()}} disabled=${W.value||!_||Fe.value.trim()===""}>
                keeper에 보내기
              </button>
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">가능한 액션 목록</div>
              <${z} panelId="intervene.action_studio" compact=${!0} />
            </div>
            <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
            <div class="ops-log-list">
              ${f.length?f.map(p=>s`
                    <article key=${`${p.action_type}:${p.target_type}`} class="ops-log-entry">
                      <div class="ops-log-head">
                        <strong>${hn(p.action_type)}</strong>
                        <span>${yn(p.target_type)}</span>
                        <span>${ho(p.confirm_required)}</span>
                      </div>
                      <div class="ops-log-body">${p.description??"설명이 아직 없습니다."}</div>
                    </article>
                  `):s`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
            </div>
          </section>

          <section class="card ops-panel">
            <div class="card-title-row">
              <div class="card-title">최근 개입 로그</div>
              <${z} panelId="intervene.recommended_actions" compact=${!0} />
            </div>
            <div class="ops-log-list">
              ${ta.value.length===0?s`
                <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
              `:ta.value.map(p=>s`
                <article key=${p.id} class="ops-log-entry ${p.outcome}">
                  <div class="ops-log-head">
                    <strong>${hn(p.action_type)}</strong>
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
  `}function Ap(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const o=Math.floor(a/60);if(o<60)return`${o}m ago`;const i=Math.floor(o/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function Z({timestamp:t}){const e=Ap(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return s`<span class="time-ago" title=${n}>${e}</span>`}function Cp({text:t}){if(!t)return null;const e=wp(t);return s`<div class="markdown-content">${e}</div>`}function wp(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const o=e[a];if(/^(`{3,}|~{3,})/.test(o)){const r=o.match(/^(`{3,}|~{3,})/)[0],c=o.slice(r.length).trim(),u=[];for(a++;a<e.length&&!e[a].startsWith(r);)u.push(e[a]),a++;a++,n.push(s`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(o.trim()==="<think>"||o.trim().startsWith("<think>")){const r=[],c=o.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const f=e[a].replace("</think>","").trim();f&&r.push(f),a++}const u=r.join(`
`).trim();n.push(s`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${La(u)}</div>
        </details>
      `);continue}if(o.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(s`<blockquote>${La(r.join(`
`))}</blockquote>`);continue}if(o.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(s`<p>${La(i.join(`
`))}</p>`)}return n}function La(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,o;for(;(o=n.exec(t))!==null;){if(o.index>a&&e.push(t.slice(a,o.index)),o[1]){const i=o[1].slice(1,-1);e.push(s`<code>${i}</code>`)}else if(o[2]){const i=o[2].slice(2,-2);e.push(s`<strong>${i}</strong>`)}else if(o[3]){const i=o[3].slice(1,-1);e.push(s`<em>${i}</em>`)}else o[4]&&o[5]&&e.push(s`<a href=${o[5]} target="_blank" rel="noopener">${o[4]}</a>`);a=o.index+o[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Oi=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Pn=v(null),Dn=v([]),Ae=v(!1),oe=v(null),qe=v(""),Ke=v(!1);function Ip(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Tp=v(Ip());function Rp(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function ko(t){return t.updated_at!==t.created_at}async function Ys(t){oe.value=t,Pn.value=null,Dn.value=[],Ae.value=!0;try{const e=await nl(t);if(oe.value!==t)return;Pn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},Dn.value=e.comments??[]}catch{oe.value===t&&(Pn.value=null,Dn.value=[])}finally{oe.value===t&&(Ae.value=!1)}}async function xo(t){const e=qe.value.trim();if(e){Ke.value=!0;try{await al(t,Tp.value,e),qe.value="",R("Comment posted","success"),await Ys(t),At()}catch{R("Failed to post comment","error")}finally{Ke.value=!1}}}function Np(){const t=Ve.value;return s`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Oi.map(e=>s`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{Ve.value=e.id,At()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${fe.value?"is-active":""}"
          onClick=${()=>{fe.value=!fe.value,At()}}
        >
          ${fe.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${At} disabled=${Xe.value}>
          ${Xe.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ea(){var e;const t=((e=Oi.find(n=>n.id===Ve.value))==null?void 0:e.label)??Ve.value;return s`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${$a.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${fe.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${hs.value?s`<${Z} timestamp=${hs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Pp({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Yo(t.id,n),At()}catch{R("Failed to vote","error")}};return s`
    <div class="board-post" onClick=${()=>gr(t.id)}>
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
              ${ko(t)?s`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${Z} timestamp=${t.created_at} /></span>
            ${ko(t)?s`<span>Updated <${Z} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Rp(t.content)}</div>
      </div>
    </div>
  `}function Dp({comments:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No comments yet</div>`:s`
    <div class="comment-thread">
      ${t.map(e=>s`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Z} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Mp({postId:t}){return s`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${qe.value}
        onInput=${e=>{qe.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&xo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Ke.value}
      />
      <button
        onClick=${()=>xo(t)}
        disabled=${Ke.value||qe.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Ke.value?"...":"Post"}
      </button>
    </div>
  `}function Lp({post:t}){oe.value!==t.id&&!Ae.value&&Ys(t.id);const e=async n=>{try{await Yo(t.id,n),At()}catch{R("Failed to vote","error")}};return s`
    <div>
      <button class="back-btn" onClick=${()=>et("memory")}>← Back to Memory</button>
      <${w} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Cp} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${Z} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments" semanticId="memory.feed">
        ${Ae.value?s`<div class="loading-indicator">Loading comments...</div>`:s`<${Dp} comments=${Dn.value} />`}
        <${Mp} postId=${t.id} />
      <//>
    </div>
  `}function Ep(){const t=$a.value,e=Q.value.params.post??null,n=e?t.find(a=>a.id===e)??(oe.value===e?Pn.value:null):null;return e&&!n&&oe.value!==e&&!Ae.value&&Ys(e),e?n?s`
          <${$t} surfaceId="memory" />
          <${Ea} />
          <${Lp} post=${n} />
        `:s`
          <div>
            <${$t} surfaceId="memory" />
            <${Ea} />
            <button class="back-btn" onClick=${()=>et("memory")}>← Back to Memory</button>
            ${Ae.value?s`<div class="loading-indicator">Loading post...</div>`:s`<div class="empty-state">Post not found</div>`}
          </div>
        `:s`
    <div>
      <${$t} surfaceId="memory" />
      <${Ea} />
      <${Np} />
      ${Xe.value?s`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?s`<div class="empty-state">No posts in durable memory right now</div>`:s`
              <${w} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.map(a=>s`<${Pp} key=${a.id} post=${a} />`)}
                </div>
              <//>
            `}
    </div>
  `}function Xt({status:t,label:e}){return s`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ji({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,o=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),s`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${o}" cy="${o}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${o}" cy="${o}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}function zp(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Op(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function jp(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function So(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Fi(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Fp(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function qi(t){if(!t)return null;const e=Dt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function qp({keeper:t,showRawStatus:e=!1}){if(ut(()=>{t!=null&&t.name&&ti(t.name)},[t==null?void 0:t.name]),!t)return s`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Dt.value[t.name],a=qi(t),o=ds.value[t.name];return s`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${zp(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${Op((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${o?s`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?s` · ${Fi(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?s` · next eligible ${Fp(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?s`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?s`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Kp({keeperName:t,placeholder:e}){const[n,a]=Oo("");ut(()=>{t&&ti(t)},[t]);const o=rt.value[t]??[],i=us.value[t]??!1,r=Mt.value[t],c=async()=>{const u=n.trim();if(!(!t||!u)){a("");try{await Vl(t,u)}catch(f){const d=f instanceof Error?f.message:`Failed to message ${t}`;R(d,"error")}}};return s`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${o.length===0?s`<div class="control-status-copy">No direct keeper conversation yet.</div>`:o.map(u=>s`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${So(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${So(u)}`}>${jp(u)}</span>
                  ${u.timestamp?s`<span class="keeper-conversation-time">${Fi(u.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${u.text}</div>
                ${u.error?s`<div class="keeper-conversation-error">${u.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${u=>{a(u.target.value)}}
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
        ${r?s`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function Up({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=qi(e),o=ps.value[e.name]??!1,i=ms.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message",c=(a==null?void 0:a.recoverable)??r==="recover";return s`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Yl(e.name,t).catch(u=>{const f=u instanceof Error?u.message:`Failed to probe ${e.name}`;R(f,"error")})}}
        disabled=${o||!t.trim()}
      >
        ${o?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Xl(e.name,t).catch(u=>{const f=u instanceof Error?u.message:`Failed to recover ${e.name}`;R(f,"error")})}}
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
  `}const Xs=v(null);function Ki(t){Xs.value=t,Jl(t.name)}function Ao(){Xs.value=null}const me=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Hp(t){if(!t)return 0;const e=me.findIndex(n=>n.level===t);return e>=0?e:0}function Wp({keeper:t}){const e=Hp(t.autonomy_level),n=me[e]??me[0];if(!n)return null;const a=(e+1)/me.length*100;return s`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${me.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${me.map((o,i)=>s`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?o.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?s`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${Z} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?s`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Mn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Bp({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",o=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return s`
    <div class="keeper-kpis">
      ${o.map(i=>s`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?s`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Mn(t.context_tokens)}</div>
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
  `}function Gp({keeper:t}){var d,_;const e=t.metrics_series??[];if(e.length<2){const g=(((d=t.context)==null?void 0:d.context_ratio)??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return s`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,a=60,o=2,i=e.length,r=e.map((g,$)=>{const x=o+$/(i-1)*(n-2*o),C=a-o-(g.context_ratio??0)*(a-2*o);return{x,y:C,p:g}}),c=r.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),u=(((_=e[e.length-1])==null?void 0:_.context_ratio)??0)*100,f=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return s`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${o}" y1="${(a-o-.5*(a-2*o)).toFixed(1)}" x2="${n-o}" y2="${(a-o-.5*(a-2*o)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${o}" y1="${(a-o-.7*(a-2*o)).toFixed(1)}" x2="${n-o}" y2="${(a-o-.7*(a-2*o)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${o}" y1="${(a-o-.85*(a-2*o)).toFixed(1)}" x2="${n-o}" y2="${(a-o-.85*(a-2*o)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:g})=>g.is_handoff).map(({x:g})=>s`
          <line x1="${g.toFixed(1)}" y1="${o}" x2="${g.toFixed(1)}" y2="${a-o}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${f}" stroke-width="1.5"/>
        ${r.filter(({p:g})=>g.is_compaction).map(({x:g,y:$})=>s`
          <circle cx="${g.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const za=v("");function Jp({keeper:t}){var o,i,r,c;const e=za.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((o=t.traits)==null?void 0:o.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return s`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${za.value}
        onInput=${u=>{za.value=u.target.value}}
      />
      ${a.map(u=>s`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${t.context_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Mn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Mn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?s`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Mn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?s`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Vp({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return s`
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
  `}function Yp({items:t}){return t.length===0?s`<div class="empty-state" style="font-size:13px">No equipment</div>`:s`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>s`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Xp({rels:t}){const e=Object.entries(t);return e.length===0?s`<div class="empty-state" style="font-size:13px">No relationships</div>`:s`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>s`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Co({traits:t,label:e}){return t.length===0?null:s`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>s`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Oa(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Qp({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Oa(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Oa(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Oa(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return s`
    <div class="keeper-signal-list">
      ${n.map(a=>s`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Ui(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Zp(){try{const t=await fa({actor:Ui(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Zo(t.result);await cn(),e!=null&&e.skipped_reason?R(e.skipped_reason,"warning"):R(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";R(e,"error")}}function tm({keeper:t}){return s`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${qp} keeper=${t} />
          <${Up}
            actor=${Ui()}
            keeper=${t}
            onPokeLodge=${()=>{Zp()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Kp}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function em(){var e,n,a;const t=Xs.value;return t?s`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${o=>{o.target.classList.contains("keeper-detail-overlay")&&Ao()}}
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
            <${Xt} status=${t.status} />
            ${t.model?s`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ao()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Bp} keeper=${t} />

        ${""}
        <${Gp} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${Jp} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${Co} traits=${t.traits??[]} label="Traits" />
            <${Co} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?s`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?s`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?s`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?s`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Z} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?s`
              <${w} title="Autonomy">
                <${Wp} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?s`
              <${w} title="TRPG Stats">
                <${Vp} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?s`
              <${w} title="Equipment (${t.inventory.length})">
                <${Yp} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?s`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${Xp} rels=${t.relationships} />
              <//>
            `:null}

          <${w} title="Runtime Signals">
            <${Qp} keeper=${t} />
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
        <${tm} keeper=${t} />
      </div>
    </div>
  `:null}const nm="masc_dashboard_agent_name",Te=v(null),ra=v(!1),an=v(""),la=v([]),sn=v([]),be=v(""),Ue=v(!1);function Hi(t){Te.value=t,Qs()}function wo(){Te.value=null,an.value="",la.value=[],sn.value=[],be.value=""}function am(){const t=Te.value;return t?ce.value.find(e=>e.name===t)??null:null}function Wi(t){return t?Kt.value.filter(e=>e.assignee===t):[]}async function Qs(){const t=Te.value;if(t){ra.value=!0,an.value="",la.value=[],sn.value=[];try{const e=await Tl(80);la.value=e.filter(o=>o.includes(t)).slice(0,20);const n=Wi(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async o=>{try{const i=await Rl(o.id,25);return{taskId:o.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:o.id,text:`Failed to load history: ${r}`}}}));sn.value=a}catch(e){an.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{ra.value=!1}}}async function Io(){var a;const t=Te.value,e=be.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(nm))==null?void 0:a.trim())||"dashboard";Ue.value=!0;try{await wl(n,`@${t} ${e}`),be.value="",R(`Mention sent to ${t}`,"success"),Qs()}catch(o){const i=o instanceof Error?o.message:"Failed to send mention";R(i,"error")}finally{Ue.value=!1}}function sm({task:t}){return s`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Xt} status=${t.status} />
    </div>
  `}function om({row:t}){return s`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function im(){var o,i,r,c;const t=Te.value;if(!t)return null;const e=am(),n=Wi(t),a=la.value;return s`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&wo()}}
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
                        <${Xt} status=${e.status} />
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
            ${(((o=e==null?void 0:e.traits)==null?void 0:o.length)??0)>0?s`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(u=>s`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?s`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(u=>s`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?s`
                    ${e.current_task?s`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?s`<span>Last seen: <${Z} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Qs()}} disabled=${ra.value}>
              ${ra.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${wo}>Close</button>
          </div>
        </div>

        ${an.value?s`<div class="council-error">${an.value}</div>`:null}

        <div class="agent-detail-grid">
          <${w} title="Assigned Tasks">
            ${n.length===0?s`<div class="empty-state">No assigned tasks</div>`:s`<div class="agent-detail-task-list">${n.map(u=>s`<${sm} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${w} title="Recent Activity">
            ${a.length===0?s`<div class="empty-state">No recent room activity match</div>`:s`<div class="agent-activity-list">${a.map((u,f)=>s`<div key=${f} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${w} title="Task History">
          ${sn.value.length===0?s`<div class="empty-state">No task history loaded</div>`:s`<div class="agent-history-list">${sn.value.map(u=>s`<${om} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${w} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${be.value}
              onInput=${u=>{be.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&Io()}}
              disabled=${Ue.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Io()}}
              disabled=${Ue.value||be.value.trim()===""}
            >
              ${Ue.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ja=600*1e3,rm=1200*1e3,To=.8;function jt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function pe(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function lm(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function cm(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function dm(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function um(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function pm(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function mm(t){var u,f;const e=sc.value.get(t.name.trim().toLowerCase())??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-jt(n)):Number.POSITIVE_INFINITY,o=!!((u=t.current_task)!=null&&u.trim())||e.activeAssignedCount>0;let i="watching",r="ok",c="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",c=n?"Offline or inactive":"No recent presence"):a>rm?(i="quiet",r="bad",c=o?"Working without a fresh signal":"No fresh agent signal"):o?(i="working",r=a>ja?"warn":"ok",c=a>ja?"Execution looks quiet for too long":"Task and live signal aligned"):a>ja?(i="quiet",r="warn",c="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",c="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((f=t.current_task)==null?void 0:f.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:c}}function vm(t){const e=ic.value.get(t.name)??"idle",n=cc.value.has(t.name),a=t.context_ratio??0;let o="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(o="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=To)&&(o="warning",i="warn",r=a>=To?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:o,tone:i,focus:um(t),note:r}}function Le({label:t,value:e,color:n,caption:a}){return s`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?s`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function _m({item:t}){const e=t.kind==="agent"?()=>Hi(t.agent.name):()=>Ki(t.keeper);return s`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?s`<span><${Z} timestamp=${t.timestamp} /></span>`:s`<span>No signal</span>`}
      </div>
    </button>
  `}function Ro({row:t}){const{agent:e,motion:n}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Hi(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ji} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${lm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?s`<span>Signal <${Z} timestamp=${t.lastSignalAt} /></span>`:s`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
        ${e.last_seen?s`<span>Seen <${Z} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?s`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function fm({row:t}){const{keeper:e}=t;return s`
    <button class="monitor-row ${t.tone} state-${t.state}" onClick=${()=>Ki(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?s`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ji} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${Xt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${cm(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?s`<span>Heartbeat <${Z} timestamp=${e.last_heartbeat} /></span>`:s`<span>No heartbeat</span>`}
        <span>${pm(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${dm(e.context_ratio)}</span>
        ${e.model?s`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?s`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function gm(){const t=[...ce.value].map(mm).sort((d,_)=>{const g=pe(_.tone)-pe(d.tone);if(g!==0)return g;const $=_.activeTaskCount-d.activeTaskCount;return $!==0?$:jt(_.lastSignalAt)-jt(d.lastSignalAt)}),e=[...Ce.value].map(vm).sort((d,_)=>{const g=pe(_.tone)-pe(d.tone);if(g!==0)return g;const $=(_.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return $!==0?$:jt(_.keeper.last_heartbeat)-jt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline"),a=t.filter(d=>d.state==="offline"),o=n.length,i=t.filter(d=>d.state==="working").length,r=t.filter(d=>d.lastSignalAt&&Date.now()-jt(d.lastSignalAt)<=12e4).length,c=t.filter(d=>d.tone!=="ok"),u=e.filter(d=>d.tone!=="ok"),f=[...u.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...c.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,_)=>{const g=pe(_.tone)-pe(d.tone);return g!==0?g:jt(_.timestamp)-jt(d.timestamp)}).slice(0,8);return s`
    <div class="agents-monitor">
      <${$t} surfaceId="execution" />
      <div class="stats-grid">
        <${Le} label="Workers online" value=${o} color="#4ade80" caption="활성 + 대기 실행 actor" />
        <${Le} label="Working now" value=${i} color="#fbbf24" caption="작업 또는 할당된 부하" />
        <${Le} label="Fresh signals" value=${r} color="#22d3ee" caption="최근 2분 이내 신호" />
        <${Le} label="Worker alerts" value=${c.length} color=${c.length>0?"#fb7185":"#4ade80"} caption="실행 actor 경고" />
        <${Le} label="Continuity alerts" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="keeper 연속성 경고" />
      </div>

      <${w} title="Execution Priorities" class="section" semanticId="execution.priority_queue">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs execution attention right now</h2>
          <p class="monitor-subheadline">Worker drift and keeper continuity risk are ranked together here, but diagnosed in separate sections below.</p>
        </div>
        <div class="monitor-alert-list">
          ${f.length===0?s`<div class="empty-state">No execution alerts right now</div>`:f.map(d=>s`<${_m} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${w} title="Workers" class="section" semanticId="execution.workers">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Live workers stay grouped here so owner drift is visible before you scan offline history.</p>
          </div>
          <div class="monitor-list">
            ${n.length===0?s`<div class="empty-state">No active workers visible</div>`:n.map(d=>s`<${Ro} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>

        <${w} title="Continuity" class="section" semanticId="execution.continuity">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper continuity</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and handoff state are isolated from worker execution drift.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?s`<div class="empty-state">No keepers active</div>`:e.map(d=>s`<${fm} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${w} title="Offline Workers" class="section" semanticId="execution.offline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who dropped out of the live loop</h2>
            <p class="monitor-subheadline">Offline rows stay separate so they do not drown the active execution monitor.</p>
          </div>
          <div class="monitor-list">
            ${a.length===0?s`<div class="empty-state">No offline workers right now</div>`:a.map(d=>s`<${Ro} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ca=v("all"),da=v("all"),Ps=Vt(()=>{let t=Ye.value;return ca.value!=="all"&&(t=t.filter(e=>e.horizon===ca.value)),da.value!=="all"&&(t=t.filter(e=>e.status===da.value)),t}),$m=Vt(()=>{const t={short:[],mid:[],long:[]};for(const e of Ps.value){const n=t[e.horizon];n&&n.push(e)}return t}),hm=Vt(()=>{const t=Array.from(ai.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function ym(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Zs(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Ln(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function bm(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function No(t){return t.toFixed(4)}function Po(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function km({goal:t}){return s`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Ln(t.horizon)}">
            ${Zs(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${ym(t.priority)}</span>
          ${t.metric?s`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?s`<span class="goal-due">Due: <${Z} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?s`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Xt} status=${t.status} />
        <div class="goal-updated">
          <${Z} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Do({label:t,timestamp:e,source:n,note:a}){return s`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?s`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?s`<${Z} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Fa({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,o)=>o.priority-a.priority);return s`
    <${w} title="${Zs(t)} Goals (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(a=>s`<${km} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function xm(){return s`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>s`
          <button
            class="goal-filter-btn ${ca.value===t?"active":""}"
            onClick=${()=>{ca.value=t}}
          >
            ${t==="all"?"All":Zs(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>s`
          <button
            class="goal-filter-btn ${da.value===t?"active":""}"
            onClick=${()=>{da.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Sm(){const t=Ye.value,e=t.filter(o=>o.status==="active").length,n=t.filter(o=>o.status==="completed").length,a={short:0,mid:0,long:0};for(const o of t)o.horizon in a&&a[o.horizon]++;return s`
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
        <div class="goal-summary-value" style="color:${Ln("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ln("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ln("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Am({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length} tool${(t.latest_tool_call_count??t.latest_tool_names.length)===1?"":"s"}: ${t.latest_tool_names.join(", ")}`:"No evidence yet";return s`
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
          <span>Baseline ${No(t.baseline_metric)}</span>
          <span>Current ${No(t.current_metric)}</span>
          <span class=${Po(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Po(t)}
          </span>
          <span>Elapsed ${bm(t.elapsed_seconds)}</span>
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
  `}function qa({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return s`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?s`<${Z} timestamp=${t.created_at} />`:s`<span>-</span>`}
        ${t.assignee?s`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Cm(){const{todo:t,inProgress:e,done:n}=ac.value;return s`
    <${w} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${t.length===0?s`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>s`<${qa} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${e.length===0?s`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>s`<${qa} key=${a.id} task=${a} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${n.length===0?s`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>s`<${qa} key=${a.id} task=${a} />`)}
          ${n.length>20?s`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function wm(){const t=$m.value,e=hm.value,n=e.filter(c=>c.status==="running").length,a=e.filter(c=>c.recoverable).length,o=Ye.value.filter(c=>c.status==="active").length,i=Ks.value,r=i==="idle"?"No loop running":i==="error"?Fn.value??"MDAL snapshot unavailable":"Current loop snapshot";return s`
    <div>
      <${$t} surfaceId="planning" />
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${o}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${Ps.value.length}</div>
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

      <${w} title="Planning Surface" class="section" semanticId="planning.surface">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Planning refresh reads a dedicated projection so goals, loops, and backlog pressure stay in one surface.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${ke} disabled=${ge.value}>
              ${ge.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${bs} disabled=${$e.value}>
              ${$e.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{ke(),bs()}}
              disabled=${ge.value||$e.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Do} label="Goals" timestamp=${oi.value} source="/api/v1/dashboard/planning" />
          <${Do}
            label="MDAL loops"
            timestamp=${ii.value}
            source="/api/v1/dashboard/planning"
            note=${r}
          />
        </div>
      <//>

      <${w} title="Goal Pipeline" class="section" semanticId="planning.goal_pipeline">
        <${Sm} />
        <${xm} />
      <//>

      ${ge.value&&Ye.value.length===0?s`<div class="loading-indicator">Loading goals...</div>`:Ps.value.length===0?s`<div class="empty-state">No goals match the current filters</div>`:s`
              <${Fa} horizon="short" items=${t.short??[]} />
              <${Fa} horizon="mid" items=${t.mid??[]} />
              <${Fa} horizon="long" items=${t.long??[]} />
            `}

      <${w} title="MDAL Loops" class="section" semanticId="planning.mdal_loops">
        ${$e.value&&e.length===0?s`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&i==="error"?s`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&i==="idle"?s`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?s`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:s`
                <div class="planning-loop-list">
                  ${e.map(c=>s`<${Am} key=${c.loop_id} loop=${c} />`)}
                </div>
              `}
      <//>

      <${Cm} />
    </div>
  `}const He=v("debates"),ua=v([]),pa=v([]),ma=v(!1),We=v(!1),on=v(""),Be=v(""),va=v(null),bt=v(null),Ds=v(!1);async function Ia(){ma.value=!0,on.value="";try{const t=await jr();ua.value=Array.isArray(t.debates)?t.debates:[],pa.value=Array.isArray(t.sessions)?t.sessions:[]}catch(t){on.value=t instanceof Error?t.message:"Failed to load governance state"}finally{ma.value=!1}}xc(Ia);async function Mo(){const t=Be.value.trim();if(t){We.value=!0;try{const e=await Nl(t);Be.value="",R(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ia()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";R(n,"error")}finally{We.value=!1}}}async function Im(t){va.value=t,bt.value=null,Ds.value=!0;try{bt.value=await Pl(t)}catch(e){on.value=e instanceof Error?e.message:"Failed to load debate detail"}finally{Ds.value=!1}}function Tm(){return s`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${ua.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Voting sessions</span>
        <strong>${pa.value.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Active view</span>
        <strong>${He.value==="debates"?"Debates":"Voting"}</strong>
      </div>
    </div>
  `}function Rm({debate:t}){const e=va.value===t.id;return s`
    <button class="council-row ${e?"selected":""}" onClick=${()=>Im(t.id)}>
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Arguments: ${t.argument_count}</span>
          ${t.created_at?s`<span><${Z} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function Nm({session:t}){return s`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.created_at?s`<span><${Z} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function Pm(){const t=He.value;return s`
    <div class="overview-sub-tabs" style="margin-bottom:12px;">
      <button class="sub-tab-btn ${t==="debates"?"active":""}" onClick=${()=>{He.value="debates"}}>Debates</button>
      <button class="sub-tab-btn ${t==="voting"?"active":""}" onClick=${()=>{He.value="voting"}}>Voting</button>
    </div>
  `}function Dm(){return s`
    <div>
      <${w} title="Start Debate" class="section" semanticId="governance.debates">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Be.value}
            onInput=${t=>{Be.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Mo()}}
            disabled=${We.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Mo}
            disabled=${We.value||Be.value.trim()===""}
          >
            ${We.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ia} disabled=${ma.value}>
            ${ma.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${on.value?s`<div class="council-error">${on.value}</div>`:null}
      <//>

      <${w} title="Debates" class="section" semanticId="governance.debates">
        <div class="council-list">
          ${ua.value.length===0?s`<div class="empty-state">No debates yet</div>`:ua.value.map(t=>s`<${Rm} key=${t.id} debate=${t} />`)}
        </div>
      <//>

      <${w} title=${va.value?`Debate Detail (${va.value})`:"Debate Detail"} class="section" semanticId="governance.debates">
        ${Ds.value?s`<div class="loading-indicator">Loading debate detail...</div>`:bt.value?s`
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Status: ${bt.value.status}</span>
                  <span>Total arguments: ${bt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom:8px;">
                  <span>Support: ${bt.value.support_count}</span>
                  <span>Oppose: ${bt.value.oppose_count}</span>
                  <span>Neutral: ${bt.value.neutral_count}</span>
                </div>
                ${bt.value.summary_text?s`<pre class="council-detail">${bt.value.summary_text}</pre>`:null}
              `:s`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Mm(){return s`
    <${w} title="Voting Sessions" class="section" semanticId="governance.voting">
      <div class="council-list">
        ${pa.value.length===0?s`<div class="empty-state">No active sessions</div>`:pa.value.map(t=>s`<${Nm} key=${t.id} session=${t} />`)}
      </div>
    <//>
  `}function Lm(){return ut(()=>{Ia()},[]),s`
    <div>
      <${$t} surfaceId="governance" />
      <${Tm} />
      <${Pm} />
      ${He.value==="debates"?s`<${Dm} />`:s`<${Mm} />`}
    </div>
  `}const ve=v(""),Ka=v("ability_check"),Ua=v("10"),Ha=v("12"),bn=v(""),kn=v("idle"),Ft=v(""),xn=v("keeper-late"),Wa=v("player"),Ba=v(""),gt=v("idle"),Ga=v(null),Sn=v(""),Ja=v(""),Va=v("player"),Ya=v(""),Xa=v(""),Qa=v(""),Ge=v("20"),Za=v("20"),ts=v(""),An=v("idle"),Ms=v(null),Bi=v("overview"),es=v("all"),ns=v("all"),as=v("all"),Em=12e4,Ta=v(null),Lo=v(Date.now());function zm(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Om(t,e){return e>0?Math.round(t/e*100):0}const jm={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Fm={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Cn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function qm(t){const e=t.trim().toLowerCase();return jm[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Km(t){const e=t.trim().toLowerCase();return Fm[e]??"상황에 따라 선택되는 전술 액션입니다."}function Bt(t){return typeof t=="object"&&t!==null}function mt(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function kt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function rn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Um=new Set(["str","dex","con","int","wis","cha"]);function Hm(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(o){throw new Error(`능력치 JSON 파싱 실패: ${o instanceof Error?o.message:"invalid json"}`)}if(!Bt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([o,i])=>{const r=o.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){a[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Wm(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(Ge.value.trim(),10);Number.isFinite(a)&&a>n&&(Ge.value=String(n))}function Ls(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Bm(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Gm(t){Bi.value=t}function Gi(t){const e=Ta.value;return e==null||e<=t}function Jm(t){const e=Ta.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function _a(){Ta.value=null}function Ji(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Vm(t,e){Ji(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ta.value=Date.now()+Em,R("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function En(t){return Gi(t)?(R("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Es(t,e,n){return Ji([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Ym({hp:t,max:e}){const n=Om(t,e),a=zm(t,e);return s`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Xm({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return s`
    <div class="trpg-actor-stats">
      ${e.map(n=>s`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Qm({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return s`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Vi({actor:t}){var u,f,d,_;const e=(u=t.archetype)==null?void 0:u.trim(),n=(f=t.persona)==null?void 0:f.trim(),a=(d=t.portrait)==null?void 0:d.trim(),o=(_=t.background)==null?void 0:_.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!Um.has(g.toLowerCase()));return s`
    <div class="trpg-actor">
      ${a?s`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
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
        <${Qm} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?s`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?s`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ym} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Xm} stats=${t.stats} />
          </div>
        `:null}
      ${e?s`<div class="trpg-actor-meta">Archetype: ${Cn(e)}</div>`:null}
      ${o?s`<div class="trpg-actor-meta">Background: ${o}</div>`:null}
      ${n?s`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,$])=>s`
                <span class="trpg-custom-stat-chip">${Cn(g)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(g=>s`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Cn(g)}</span>
                  <span class="trpg-annot-desc">${qm(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?s`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(g=>s`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Cn(g)}</span>
                  <span class="trpg-annot-desc">${Km(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Zm({mapStr:t}){return s`<pre class="trpg-map">${t}</pre>`}function Yi({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?s`<div class="empty-state" style="font-size:13px">${e}</div>`:s`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var o;return s`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Bm(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ls(n)}</strong>
            ${" "}
          ${n.dice_roll?s`<span class="trpg-dice">[${n.dice_roll.notation}: ${(o=n.dice_roll.rolls)==null?void 0:o.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${Z} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function tv({events:t}){const e="__none__",n=es.value,a=ns.value,o=as.value,i=Array.from(new Set(t.map(Ls).map(_=>_.trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),r=Array.from(new Set(t.map(_=>(_.type??"").trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),c=t.some(_=>(_.type??"").trim()===""),u=Array.from(new Set(t.map(_=>(_.phase??"").trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),f=t.some(_=>(_.phase??"").trim()===""),d=t.filter(_=>{if(n!=="all"&&Ls(_)!==n)return!1;const g=(_.type??"").trim(),$=(_.phase??"").trim();if(a===e){if(g!=="")return!1}else if(a!=="all"&&g!==a)return!1;if(o===e){if($!=="")return!1}else if(o!=="all"&&$!==o)return!1;return!0});return s`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${_=>{es.value=_.target.value}}>
          <option value="all">all</option>
          ${i.map(_=>s`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${_=>{ns.value=_.target.value}}>
          <option value="all">all</option>
          ${c?s`<option value=${e}>(none)</option>`:null}
          ${r.map(_=>s`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${o} onChange=${_=>{as.value=_.target.value}}>
          <option value="all">all</option>
          ${f?s`<option value=${e}>(none)</option>`:null}
          ${u.map(_=>s`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{es.value="all",ns.value="all",as.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${d.length} / 전체 ${t.length}
      </span>
    </div>
    <${Yi} events=${d.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function ev({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",o=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return s`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?s`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${o?s`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${o}</div>`:null}
    </div>
  `}function Xi({state:t}){const e=t.history??[];return e.length===0?null:s`
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
  `}function nv({state:t,nowMs:e}){var f;const n=Pt.value||((f=t.session)==null?void 0:f.room)||"",a=kn.value,o=t.party??[];if(!o.find(d=>d.id===ve.value)&&o.length>0){const d=o[0];d&&(ve.value=d.id)}const r=async()=>{var _,g;if(!n){R("Room ID가 비어 있습니다.","error");return}if(!En(e))return;const d=((_=t.current_round)==null?void 0:_.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(Es("라운드 실행",n,d)){kn.value="running";try{const $=await hl(n);Ms.value=$,kn.value="ok";const x=Bt($.summary)?$.summary:null,C=x?rn(x,"advanced",!1):!1,I=x?mt(x,"progress_reason",""):"";R(C?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${I?`: ${I}`:""}`,C?"success":"warning"),Ct()}catch($){Ms.value=null,kn.value="error";const x=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";R(x,"error")}finally{_a()}}},c=async()=>{var _,g;if(!n||!En(e))return;const d=((_=t.current_round)==null?void 0:_.phase)??((g=t.session)==null?void 0:g.status)??"unknown";if(Es("턴 강제 진행",n,d))try{await kl(n),R("턴을 다음 단계로 이동했습니다.","success"),Ct()}catch{R("턴 이동에 실패했습니다.","error")}finally{_a()}},u=async()=>{if(!n||!En(e))return;const d=ve.value.trim();if(!d){R("먼저 Actor를 선택하세요.","warning");return}const _=Number.parseInt(Ua.value,10),g=Number.parseInt(Ha.value,10);if(Number.isNaN(_)||Number.isNaN(g)){R("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(bn.value,10),x=bn.value.trim()===""||Number.isNaN($)?void 0:$;try{await bl({roomId:n,actorId:d,action:Ka.value.trim()||"ability_check",statValue:_,dc:g,rawD20:x}),R("주사위 판정을 기록했습니다.","success"),Ct()}catch{R("주사위 판정 기록에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${d=>{Pt.value=d.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ve.value}
            onChange=${d=>{ve.value=d.target.value}}
          >
            <option value="">Actor 선택</option>
            ${o.map(d=>s`<option value=${d.id}>${d.name} (${d.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ka.value}
              onInput=${d=>{Ka.value=d.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ua.value}
              onInput=${d=>{Ua.value=d.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ha.value}
              onInput=${d=>{Ha.value=d.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${bn.value}
              onInput=${d=>{bn.value=d.target.value}}
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
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?s`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function av({state:t}){var o;const e=Pt.value||((o=t.session)==null?void 0:o.room)||"",n=An.value,a=async()=>{if(!e){R("Room ID가 비어 있습니다.","warning");return}const i=Sn.value.trim(),r=Ja.value.trim();if(!r&&!i){R("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Ge.value.trim(),10),u=Number.parseInt(Za.value.trim(),10),f=Number.isFinite(u)?Math.max(1,u):20,d=Number.isFinite(c)?Math.max(0,Math.min(f,c)):f;let _={};try{_=Hm(ts.value)}catch(g){R(g instanceof Error?g.message:"능력치 JSON 오류","error");return}An.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await xl(e,{actor_id:i||void 0,name:r||void 0,role:Va.value,idempotencyKey:g,portrait:Xa.value.trim()||void 0,background:Qa.value.trim()||void 0,hp:d,max_hp:f,alive:d>0,stats:Object.keys(_).length>0?_:void 0}),x=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!x)throw new Error("생성 응답에 actor_id가 없습니다.");const C=Ya.value.trim();C&&await Sl(e,x,C),ve.value=x,Ft.value=x,i||(Sn.value=""),An.value="ok",R(`Actor 생성 완료: ${x}`,"success"),await Ct()}catch(g){An.value="error",R(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return s`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ja.value}
            onInput=${i=>{Ja.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Va.value}
            onChange=${i=>{Va.value=i.target.value}}
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
            value=${Ya.value}
            onInput=${i=>{Ya.value=i.target.value}}
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
              value=${Sn.value}
              onInput=${i=>{Sn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Xa.value}
              onInput=${i=>{Xa.value=i.target.value}}
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
              value=${Ge.value}
              onInput=${i=>{Ge.value=i.target.value}}
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
              value=${Za.value}
              onInput=${i=>{const r=i.target.value;Za.value=r,Wm(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Qa.value}
              onInput=${i=>{Qa.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ts.value}
              onInput=${i=>{ts.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?s`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function sv({state:t,nowMs:e}){var g;const n=Pt.value||((g=t.session)==null?void 0:g.room)||"",a=t.join_gate,o=Ga.value,i=Bt(o)?o:null,r=(t.party??[]).filter($=>$.role!=="dm"),c=Ft.value.trim(),u=r.some($=>$.id===c),f=u?c:c?"__manual__":"",d=async()=>{const $=Ft.value.trim(),x=xn.value.trim();if(!n||!$){R("Room/Actor가 필요합니다.","warning");return}gt.value="checking";try{const C=await Al(n,$,x||void 0);Ga.value=C,gt.value="ok",R("참가 가능 여부를 갱신했습니다.","success")}catch(C){gt.value="error";const I=C instanceof Error?C.message:"참가 가능 여부 확인에 실패했습니다.";R(I,"error")}},_=async()=>{var L,q;const $=Ft.value.trim(),x=xn.value.trim(),C=Ba.value.trim();if(!n||!$||!x){R("Room/Actor/Keeper가 필요합니다.","warning");return}if(!En(e))return;const I=((L=t.current_round)==null?void 0:L.phase)??((q=t.session)==null?void 0:q.status)??"unknown";if(Es("Mid-Join 승인 요청",n,I)){gt.value="requesting";try{const D=await Cl({room_id:n,actor_id:$,keeper_name:x,role:Wa.value,...C?{name:C}:{}});Ga.value=D;const T=Bt(D)?rn(D,"granted",!1):!1,N=Bt(D)?mt(D,"reason_code",""):"";T?R("Mid-Join이 승인되었습니다.","success"):R(`Mid-Join이 거절되었습니다${N?`: ${N}`:""}`,"warning"),gt.value=T?"ok":"error",Ct()}catch(D){gt.value="error";const T=D instanceof Error?D.message:"Mid-Join 요청에 실패했습니다.";R(T,"error")}finally{_a()}}};return s`
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
            value=${f}
            onChange=${$=>{const x=$.target.value;if(x==="__manual__"){(u||!c)&&(Ft.value="");return}Ft.value=x}}
          >
            <option value="">Actor 선택</option>
            ${r.map($=>s`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${f==="__manual__"?s`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Ft.value}
                onInput=${$=>{Ft.value=$.target.value}}
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
            value=${xn.value}
            onInput=${$=>{xn.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Wa.value}
            onChange=${$=>{Wa.value=$.target.value}}
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
            value=${Ba.value}
            onInput=${$=>{Ba.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${d} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${_} disabled=${gt.value==="checking"||gt.value==="requesting"}>
              ${gt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?s`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${rn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${kt(i,"effective_score",0)}/${kt(i,"required_points",0)}</span>
            ${mt(i,"reason_code","")?s`<span style="margin-left:8px;">Reason: ${mt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Qi({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?s`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:s`
    <div class="trpg-round-list">
      ${e.map(n=>s`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Zi({state:t}){var n;const e=t.current_round;return e?s`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?s`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function tr(){const t=Ms.value;if(!t)return s`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Bt(e)?e:null,o=(Array.isArray(t.statuses)?t.statuses:[]).filter(Bt).slice(-8),i=t.canon_check,r=Bt(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(N=>typeof N=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(N=>typeof N=="string").slice(0,3):[],f=n?rn(n,"advanced",!1):!1,d=n?mt(n,"progress_reason",""):"",_=n?mt(n,"progress_detail",""):"",g=n?kt(n,"player_successes",0):0,$=n?kt(n,"player_required_successes",0):0,x=n?rn(n,"dm_success",!1):!1,C=n?kt(n,"timeouts",0):0,I=n?kt(n,"unavailable",0):0,L=n?kt(n,"reprompts",0):0,q=n?kt(n,"npc_attacks",0):0,D=n?kt(n,"keeper_timeout_sec",0):0,T=n?kt(n,"roll_audit_count",0):0;return s`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${f?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${f?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${x?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${d?s`<div style="margin-top:4px; font-size:12px;">${d}</div>`:null}
        ${_?s`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${_}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${L}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${q}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${D||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${o.length>0?s`
          <div class="trpg-round-list">
            ${o.map(N=>{const p=mt(N,"status","unknown"),M=mt(N,"actor_id","-"),ot=mt(N,"role","-"),ct=mt(N,"reason",""),dt=mt(N,"action_type",""),H=mt(N,"reply","");return s`
                <div class="trpg-round-item ${p.includes("fallback")||p.includes("timeout")?"failed":"active"}">
                  <span>${M} (${ot})</span>
                  <span style="margin-left:auto; font-size:11px;">${p}</span>
                  ${dt?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${dt}</div>`:null}
                  ${ct?s`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${ct}</div>`:null}
                  ${H?s`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${H.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?s`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${mt(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(N=>s`<div>violation: ${N}</div>`)}
                </div>`:null}
            ${c.length>0?s`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(N=>s`<div>warning: ${N}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function ov({state:t,nowMs:e}){var r,c,u;const n=Pt.value||((r=t.session)==null?void 0:r.room)||"",a=((c=t.current_round)==null?void 0:c.phase)??((u=t.session)==null?void 0:u.status)??"unknown",o=Gi(e),i=Jm(e);return s`
    <${w} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${o?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${o?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${o?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${o?s`<button class="trpg-run-btn recommend" onClick=${()=>Vm(n,a)}>잠금 해제 (120초)</button>`:s`<button class="trpg-run-btn secondary" onClick=${()=>{_a(),R("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function iv({active:t}){return s`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>s`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Gm(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function rv({state:t}){const e=t.party??[],n=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${w} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${w} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Yi} events=${n.slice(-20)} />
        <//>

        ${t.map?s`
            <${w} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Zm} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${w} title="현재 라운드" semanticId="lab.trpg">
          <${Zi} state=${t} />
        <//>

        <${w} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Qi} state=${t} />
        <//>

        <${w} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>s`<${Vi} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?s`
            <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Xi} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function lv({state:t}){const e=t.story_log??[];return s`
    <div class="trpg-layout">
      <div>
        <${w} title=${`이벤트 타임라인 (${e.length})`}>
          <${tv} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${w} title="최근 라운드 결과" semanticId="lab.trpg">
          <${tr} />
        <//>

        <${w} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Zi} state=${t} />
        <//>
      </div>
    </div>
  `}function cv({state:t,nowMs:e}){const n=t.party??[];return s`
    <div>
      <${ov} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${w} title="조작 패널" semanticId="lab.trpg">
            <${nv} state=${t} nowMs=${e} />
          <//>

          <${w} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${av} state=${t} />
          <//>

          <${w} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${sv} state=${t} nowMs=${e} />
          <//>

          <${w} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${tr} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${w} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Qi} state=${t} />
          <//>

          <${w} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>s`<${Vi} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?s`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?s`
              <${w} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Xi} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function dv(){var c,u,f,d,_;const t=ni.value,e=$s.value;if(ut(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{Lo.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),e&&!t)return s`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return s`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ct()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],o=t.outcome,i=Bi.value,r=Lo.value;return s`
    <div>
      <${$t} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Pt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((f=t.session)==null?void 0:f.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ct()}>새로고침</button>
      </div>

      <${ev} outcome=${o} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((d=t.session)==null?void 0:d.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((_=t.current_round)==null?void 0:_.round_number)??0}</div>
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

      <${iv} active=${i} />

      ${i==="overview"?s`<${rv} state=${t} />`:i==="timeline"?s`<${lv} state=${t} />`:s`<${cv} state=${t} nowMs=${r} />`}
    </div>
  `}function uv(){return s`
    <div>
      <${$t} surfaceId="lab" />
      <${w} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${w} title="TRPG" class="section" semanticId="lab.trpg">
        <${dv} />
      <//>
    </div>
  `}const Eo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],zs=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function pv(){const t=le.value;return s`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Os.value} events</span>
    </div>
  `}function mv({currentTab:t,currentSectionLabel:e}){const n=le.value;return s`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>Snapshot</h3>
        <${z} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${n?"ok":"bad"}">${n?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agents</span>
          <strong>${ce.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keepers</span>
          <strong>${Ce.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Tasks</span>
          <strong>${Kt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Events</span>
          <strong>${Os.value}</strong>
        </div>
      </div>
      <div class="rail-snapshot-copy">
        <span>Connection ${n?"healthy":"recovering"}</span>
        <span>${e} workspace active</span>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{cn(),ci(),t==="command"&&(re(),Ut(),_t.value==="swarm"&&Nt()),t==="mission"&&Nn(),t==="execution"&&Tt(),t==="intervene"&&(Jt(),Et()),t==="memory"&&At(),t==="planning"&&ke(),t==="lab"&&Ct()}}
        >
          Refresh Now
        </button>
        <button class="rail-secondary-btn" onClick=${()=>et("intervene")}>
          Open Intervene
        </button>
      </div>
    </section>
  `}function vv(){const t=we.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,a=(t==null?void 0:t.keepers.length)??0;return s`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${z} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{Jt(),Et()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>et("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function _v(){const t=Q.value.tab,e=zs.find(a=>a.id===t),n=Eo.find(a=>a.id===(e==null?void 0:e.group));return s`
    <aside class="dashboard-rail">
      <${$t} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          <${z} panelId="side_rail.navigate" compact=${!0} />
          ${n?s`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Eo.map(a=>s`
          <div class="rail-nav-group" key=${a.id}>
            <div class="rail-group-label">${a.label}</div>
            <div class="rail-group-copy">${a.description}</div>
            <div class="rail-tab-list">
              ${zs.filter(o=>o.group===a.id).map(o=>s`
                  <button
                    class="rail-tab-btn ${t===o.id?"active":""}"
                    onClick=${()=>et(o.id)}
                  >
                    <span class="rail-tab-icon">${o.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${o.label}</strong>
                      <span>${o.description}</span>
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

      <${mv} currentTab=${t} currentSectionLabel=${(n==null?void 0:n.label)??"Observe"} />
      <${vv} />
    </aside>
  `}function fv(){switch(Q.value.tab){case"mission":return s`<${po} />`;case"execution":return s`<${gm} />`;case"memory":return s`<${Ep} />`;case"governance":return s`<${Lm} />`;case"planning":return s`<${wm} />`;case"intervene":return s`<${Sp} />`;case"command":return s`<${Vu} />`;case"lab":return s`<${uv} />`;default:return s`<${po} />`}}function gv(){ut(()=>{$r(),Ho(),di(),Tt(),ci(),Nn();const n=Cc();return wc(),()=>{Cr(),n(),Ic()}},[]),ut(()=>{const n=setInterval(()=>{const a=Q.value.tab;a==="command"?(re(),Ut(),_t.value==="swarm"&&Nt()):a==="mission"?Nn():a==="execution"?Tt():a==="intervene"?(Jt(),Et()):a==="memory"?At():a==="planning"?ke():a==="lab"&&Ct()},15e3);return()=>{clearInterval(n)}},[]),ut(()=>{const n=Q.value.tab;n==="command"&&(re(),Ut(),_t.value==="swarm"&&Nt()),n==="mission"&&Nn(),n==="execution"&&Tt(),n==="intervene"&&(Jt(),Et()),n==="memory"&&At(),n==="planning"&&ke(),n==="lab"&&Ct()},[Q.value.tab]);const t=Q.value.tab,e=zs.find(n=>n.id===t);return s`
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
          <${pv} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${_v} />
        <main class="dashboard-main">
          ${gs.value&&!le.value?s`<div class="loading-indicator">Loading dashboard...</div>`:s`<${fv} />`}
        </main>
      </div>

      <${em} />
      <${im} />
      <${Qu} />
    </div>
  `}const zo=document.getElementById("app");zo&&mr(s`<${gv} />`,zo);export{Wc as _};
