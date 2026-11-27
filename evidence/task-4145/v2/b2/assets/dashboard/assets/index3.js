const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["assets/create-keeper-modal.js","assets/vendor.js","assets/index.js","assets/markdown-renderer.js","assets/markdown.js","assets/config-schema.js","assets/type-guards.js","assets/index6.css","assets/markdown-renderer.css","assets/keeper-debug-companion.js","assets/unified-diff.js","assets/uplot-chart.js","assets/refresh-button.js","assets/target-locked-action.js","assets/keeper-tool-call-inspector.js","assets/lazy-component.js","assets/keeper-state.js","assets/format-string.js","assets/core.js","assets/setup-inventory-read.js","assets/quota-window.js","assets/sse-reader.js","assets/wire-decode.js","assets/types.js","assets/attachment-gallery.js","assets/copyable-code.js","assets/toast.js","assets/turn-context.js","assets/now-signal.js","assets/shared-ticker.js","assets/virtual-list.js","assets/table.js","assets/useSelector.js","assets/icons.js","assets/inline-spinner.js","assets/keeper-memory-tab.js","assets/data-table.js","assets/keeper-read.js","assets/format-time.js","assets/keeper-portrait-candle-tab.js","assets/keeper-work-sandbox-tab.js","assets/keeper-config-tab.js","assets/keeper-oauth-flow.js"])))=>i.map(i=>d[i]);
import{z as qt,A as we,aK as el,V as qr,Y as Te,X as Us,W as Bo,a as _e,Q as He,S as yt,U as $t,aM as tl,O as An,s as Jt,ai as Ea,ah as rs,B as ie,aj as Ta,T as Sa,F as os,ae as On,v as xa,R as Kr,C as sr,D as Ra,M as ss,o as In,P as Or,aT as Aa,aU as Ca,j as nl,L as as,N as tr,aV as is,K as Ia,am as rl}from"./index.js";import{m as u,d as F,y as Se,T as wt,q as be,P as Nr,z as Oa,A as X,C as ol,_ as Bs,b as sl,c as al}from"./vendor.js";import{c as Fr}from"./lazy-component.js";import{i as il,c as wa,a as ll,d as cl,f as ul}from"./keeper-state.js";import{i as ve}from"./type-guards.js";import{K as dl,b as pl,u as _l,k as qo}from"./core.js";import{M as Pa,N as Fo,h as fl}from"./setup-inventory-read.js";import{L as ml,M as et,N as wn,O as It,K as at,g as qs}from"./types.js";import{d as Cn,i as gl,r as Fs,A as kl,b as Hs,h as Eo,a as To,c as vl}from"./attachment-gallery.js";import{a as Ot,c as Ka,d as Hr,j as hl,t as bl,M as zt}from"./markdown-renderer.js";import{D as yl}from"./markdown.js";import{w as $l,a as El,b as Tl,c as Sl,e as xl,f as Rl,p as Al,g as js,i as Mr,s as Cl}from"./turn-context.js";import{a as Il,b as Ol}from"./now-signal.js";import{V as wl}from"./virtual-list.js";import{T as Pl}from"./target-locked-action.js";import{T as Kl,R as Gs,O as Nl,a as Ml}from"./icons.js";import{I as nr}from"./inline-spinner.js";import{j as Tn,e as Zt,l as ar,k as ir,f as lr,i as cr,h as Ll}from"./wire-decode.js";const Qn={face:["bare_face","glasses","shades","eye_patch","plaster","freckles","beard"],neck:["bare_neck","scarf","bow_tie","medal"],head:["bare_head","bow","crown","beanie"],hand:["empty_hand","book","mug","quill"],base:["no_dish","dish_gilt","dish_silver","dish_oak"]};function Dl(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function Ul(e,t){return Object.keys(e).length===t.length&&t.every(n=>Object.hasOwn(e,n))}function Yn(e,t){return typeof t=="string"&&e.some(n=>n===t)}function Bl(e){return Dl(e)&&Ul(e,["face","neck","head","hand","base"])&&Yn(Qn.face,e.face)&&Yn(Qn.neck,e.neck)&&Yn(Qn.head,e.head)&&Yn(Qn.hand,e.hand)&&Yn(Qn.base,e.base)}const ql=/^[A-Za-z0-9_.-]+$/,Fl=/^[A-Za-z0-9_-]{1,64}$/,Na=/^[0-9a-f]{64}$/,Hl=/[^ \f\n\r\t]/;function Ho(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function gt(e,t){return Object.keys(e).length===t.length&&t.every(r=>Object.hasOwn(e,r))}function Vt(e){return typeof e=="string"&&e.length>0&&e.length<=128&&e!=="."&&e!==".."&&ql.test(e)}function jo(e){return typeof e=="number"&&Number.isSafeInteger(e)&&e>=0}function So(e){return typeof e=="string"&&Hl.test(e)}function jl(e){if(typeof e!="string")return!1;const t=e.lastIndexOf("#");if(t<=0)return!1;const n=e.slice(t+1);return n!=="-0"&&/^-?(?:0|[1-9][0-9]*)$/.test(n)}function Gl(e){if(!Ho(e))return null;switch(e.kind){case"operation":return gt(e,["kind","operation_id"])&&Vt(e.operation_id)?{kind:"operation",operation_id:e.operation_id}:null;case"operation_checkpoint":return gt(e,["kind","operation_id","trace_id","turn_count","sha256"])&&Vt(e.operation_id)&&typeof e.trace_id=="string"&&Fl.test(e.trace_id)&&jo(e.turn_count)&&typeof e.sha256=="string"&&Na.test(e.sha256)?{kind:"operation_checkpoint",operation_id:e.operation_id,trace_id:e.trace_id,turn_count:e.turn_count,sha256:e.sha256}:null;case"operation_native":return gt(e,["kind","operation_id","continuation_id"])&&Vt(e.operation_id)&&Vt(e.continuation_id)?{kind:"operation_native",operation_id:e.operation_id,continuation_id:e.continuation_id}:null;case"fusion_run":case"workspace_message":return gt(e,["kind","request_id"])&&Vt(e.request_id)?{kind:e.kind,request_id:e.request_id}:null;case"connector_message":return gt(e,["kind","event_id"])&&Vt(e.event_id)?{kind:"connector_message",event_id:e.event_id}:null;case"approval_lifecycle":return gt(e,["kind","approval_id"])&&Vt(e.approval_id)?{kind:"approval_lifecycle",approval_id:e.approval_id}:null;case"autonomous_turn":return gt(e,["kind","turn_ref"])&&jl(e.turn_ref)?{kind:"autonomous_turn",turn_ref:e.turn_ref}:null;case"goal_notification":return gt(e,["kind","goal_id","owner","event"])&&So(e.goal_id)&&So(e.owner)&&So(e.event)?{kind:"goal_notification",goal_id:e.goal_id,owner:e.owner,event:e.event}:null;default:return null}}function Wl(e){if(!Ho(e))return null;switch(e.kind){case"accepted_user":case"settled_failure":case"terminal_result":case"approval_request":case"approval_resolution":case"approval_replay":case"approval_replay_correction":case"approval_continuation":return gt(e,["kind"])?{kind:e.kind}:null;case"tool_call":return gt(e,["kind","execution_id","ordinal"])&&typeof e.execution_id=="string"&&e.execution_id.trim().length>0&&jo(e.ordinal)?{kind:"tool_call",execution_id:e.execution_id,ordinal:e.ordinal}:null;case"tool_delivery":return gt(e,["kind","ordinal"])&&jo(e.ordinal)?{kind:"tool_delivery",ordinal:e.ordinal}:null;case"autonomous_input_binding":{if(!gt(e,["kind","inputs"])||!Array.isArray(e.inputs)||e.inputs.length===0)return null;const t=[],n=new Set;for(const r of e.inputs){if(!Ho(r)||!gt(r,["approval_id","input_fingerprint"])||!Vt(r.approval_id)||typeof r.input_fingerprint!="string"||!Na.test(r.input_fingerprint)||n.has(r.approval_id))return null;n.add(r.approval_id),t.push({approval_id:r.approval_id,input_fingerprint:r.input_fingerprint})}return{kind:"autonomous_input_binding",inputs:t}}default:return null}}function Ma(e,t){if(e===void 0&&t===void 0)return{status:"absent",value:null};const n=Gl(e),r=Wl(t);if(n&&r){if(r.kind==="autonomous_input_binding"&&n.kind!=="autonomous_turn")return{status:"invalid",value:null};if(n.kind==="autonomous_turn"&&r.kind!=="autonomous_input_binding"&&r.kind!=="tool_call"&&r.kind!=="tool_delivery")return{status:"invalid",value:null}}return n&&r?{status:"valid",value:{delivery_key:n,transcript_slot:r}}:{status:"invalid",value:null}}function Vl(e){if(!ve(e))return null;const t=ve(e.cache)?{state:at(e.cache.state),key:It(e.cache.key),ttl_s:et(e.cache.ttl_s),stale:wn(e.cache.stale),stale_reason:It(e.cache.stale_reason),latest_age_s:et(e.cache.latest_age_s),health:It(e.cache.health)}:void 0;return{schema:at(e.schema),schema_version:et(e.schema_version),surface:at(e.surface),source:at(e.source),generated_at_iso:at(e.generated_at_iso),cache:t}}function zl(e){return ve(e)?{schema:at(e.schema),ts:et(e.ts),ts_iso:It(e.ts_iso),source:at(e.source),producer:at(e.producer),durable_store:at(e.durable_store),dashboard_surface:at(e.dashboard_surface),stale_reason:at(e.stale_reason),keeper_name:It(e.keeper_name),trace_id:It(e.trace_id),error:It(e.error),error_class:It(e.error_class)}:null}function Ql(e){const t=ml(e.coverage_gaps).map(zl).filter(n=>n!==null);return{source:at(e.source),producer:at(e.producer),durable_store:at(e.durable_store),dashboard_surface:at(e.dashboard_surface),dashboard_surface_envelope:Vl(e.dashboard_surface_envelope),freshness_slo_s:et(e.freshness_slo_s),latest_ts_unix:et(e.latest_ts_unix),latest_ts_iso:It(e.latest_ts_iso),latest_age_s:et(e.latest_age_s),health:at(e.health),stale_reason:It(e.stale_reason),entry_count:et(e.entry_count),exists:wn(e.exists),coverage_gaps:t,coverage_gap_count:et(e.coverage_gap_count,t.length),active_coverage_gap_count:et(e.active_coverage_gap_count)}}const Ws={reader:0,worker:1,admin:2};function Yl(e){return e.replace(/\s+/g," ").trim()}function Jl(e){return e&&e.replace(/^[^\w가-힣@]+/u,"").trim()||null}function Xl(e){return e==="reader"||e==="worker"||e==="admin"?e:null}function Zl(e){const t=e.requested_agent??"dashboard",n=e.token_agent?`@${e.token_agent}`:null,r=Jl(e.auth_error_detail??e.keeper_msg_error);switch(e.auth_error_code){case"missing_token":return r??"Bearer token is required.";case"invalid_token":return r??"Bearer token could not be verified.";case"token_expired":return r??"Bearer token has expired.";case"actor_mismatch":return r??`Current actor @${t} does not match token owner ${n??"unknown"}.`;case"same_origin_blocked":return r??"Cross-origin browser requests require a Bearer token.";case"insufficient_role":return r??"Current session role cannot perform this action.";case"unknown":return r??"Auth status must be checked.";default:return r}}function ec(e,t="worker"){if(!e)return{allowed:!1,required_role:t,effective_role:null,reason:"Checking auth status."};const n=Xl(e.effective_role),r=n==null||Ws[n]<Ws[t],o=Zl(e),i=r?Yl(`Current role is ${n??"unknown"}; ${t} role is required.`):null;return{allowed:o==null&&!r,required_role:t,effective_role:n,reason:o??i}}const tc=2e3;function ls(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function Zn(e){return typeof e=="string"&&/^[1-9][0-9]*$/.test(e)}async function nc(){const e=await qt.fetch("keepers:discord-operator",s=>we("/api/v1/dashboard/shell?light=true",{signal:s}));if(e.kind!=="value")return null;const{auth:t,paths:n}=e.data;if(!t?.enabled||!t.require_token||!t.token_valid||!ec(t,"admin").allowed)return null;const r=t.token_agent??t.effective_agent;if(!r||!ls(n))return null;const{effective_base_path:o,effective_masc_root:i}=n;return typeof o!="string"||!o.startsWith("/")||typeof i!="string"||!i.startsWith("/")?null:{actor:r,workspace:{base_path:o,masc_root:i}}}function rc(e,t){if(!ls(e)||e.kind!=="discord"||!Zn(e.channel_id)||!Zn(t))return null;const{guild_id:n,channel_id:r,parent_channel_id:o,thread_id:i}=e;return n!=null&&!Zn(n)||(o==null?i!=null:!Zn(o)||o===r||i!==r)?null:{guildId:n??null,channelId:r,messageId:t}}function Vs(e,t){return`https://discord.com/channels/${e.guildId??"@me"}/${e.channelId}/${t}`}function oc(e,t,n){if(!ls(e)||e.operation_id!==n||e.keeper_name!==t.keeperName||e.chat_id!==t.chatId||e.channel_id!==t.origin.channelId||e.original_message_id!==t.origin.messageId)throw new Error("Discord 전송 결과의 대상이 요청과 일치하지 않습니다.");switch(e.state){case"sending":case"outcome_unknown":return{state:e.state};case"delivered":if(Zn(e.message_id))return{state:e.state,messageId:e.message_id};break;case"refused":if(e.reason==="binding_changed"||e.reason==="discord_unconfigured"||e.reason==="discord_rejected")return{state:e.state,reason:e.reason};break}throw new Error("Discord 전송 결과 형식을 읽을 수 없습니다.")}function sc(e,t,n,r,o){const i={expected_workspace:e,operation_id:n};return el({method:"POST",path:`/api/v1/keepers/discord/reply${r.kind==="status"?"/status":""}`,body:r.kind==="status"?i:{...i,keeper_name:t.keeperName,chat_id:t.chatId,content:r.content},signal:o,decode:s=>oc(s,t,n)})}function Qt(e,t){return Object.keys(e).length===t.length&&t.every(n=>Object.hasOwn(e,n))}function Sr(e){return typeof e=="string"&&e.trim().length>0}function rr(e){return typeof e=="number"&&Number.isSafeInteger(e)&&e>=0}function xo(e){return e===null||rr(e)}function ac(e){if(!ve(e)||!Qt(e,["requested","effective","ceiling","ceiling_source","policy","envelope"])||!xo(e.requested)||!xo(e.effective)||!xo(e.ceiling)||e.ceiling!==null&&e.ceiling<=0||![null,"catalog_model","declared_capability_override","provider_default"].includes(e.ceiling_source)||e.ceiling===null!=(e.ceiling_source===null)||!["openai_chat_max_tokens","openai_responses_max_output_tokens","anthropic_messages_max_tokens","gemini_generation_config_max_output_tokens","ollama_options_num_predict"].includes(e.envelope))return null;const t=e.envelope==="anthropic_messages_max_tokens";switch(e.policy){case"omitted":if(t||e.requested!==null||e.effective!==null)return null;break;case"explicit":if(e.requested===null||e.effective!==e.requested||e.ceiling!==null&&e.effective>e.ceiling)return null;break;case"explicit_clamped":if(e.requested===null||e.ceiling===null||e.effective!==e.ceiling||e.requested<=e.ceiling)return null;break;case"required_catalog_fallback":if(!t||e.requested!==null||e.effective!==e.ceiling||e.ceiling===null||e.ceiling_source!=="catalog_model")return null;break;case"required_capability_override_fallback":if(!t||e.requested!==null||e.effective!==e.ceiling||e.ceiling===null||e.ceiling_source!=="declared_capability_override")return null;break;default:return null}return e}function ic(e){if(!ve(e)||!Qt(e,["state","request"]))return null;switch(e.state){case"not_serialized":case"external_unobserved":case"interrupted_unobserved":return e.request===null?{state:e.state,request:null}:null;case"serialized":case"cache_reused":{const t=e.request;if(!ve(t)||!Qt(t,["output_token_receipt","body_bytes","body_sha256"]))return null;const n=ac(t.output_token_receipt);return n===null||!rr(t.body_bytes)||t.body_bytes===0||typeof t.body_sha256!="string"||!/^[0-9a-f]{64}$/.test(t.body_sha256)?null:{state:e.state,request:{output_token_receipt:n,body_bytes:t.body_bytes,body_sha256:t.body_sha256}}}default:return null}}function lc(e){if(!Array.isArray(e))return null;const t=[];for(const n of e){if(!ve(n)||!Qt(n,["runtime_profile","attempt","evidence"])||!Sr(n.runtime_profile)||!rr(n.attempt)||!ve(n.evidence))return null;const r=n.evidence;switch(r.status){case"not_dispatched":case"no_durable_scope":case"no_matching_call":if(!Qt(r,["status"]))return null;t.push({runtime_profile:n.runtime_profile,attempt:n.attempt,evidence:{status:r.status}});break;case"read_failed":if(!Qt(r,["status","detail"])||!Sr(r.detail))return null;t.push({runtime_profile:n.runtime_profile,attempt:n.attempt,evidence:{status:"read_failed",detail:r.detail}});break;case"recorded":{if(!Qt(r,["status","call_id","requests"])||!Sr(r.call_id)||!Array.isArray(r.requests))return null;const o=[],i=new Set;for(const s of r.requests){if(!ve(s)||!Qt(s,["node_id","turn","ordinal","provenance"])||!Sr(s.node_id)||!rr(s.turn)||!rr(s.ordinal)||i.has(s.node_id))return null;i.add(s.node_id);const a=s.provenance===null?null:ic(s.provenance);if(s.provenance!==null&&a===null)return null;o.push({node_id:s.node_id,turn:s.turn,ordinal:s.ordinal,provenance:a})}t.push({runtime_profile:n.runtime_profile,attempt:n.attempt,evidence:{status:"recorded",call_id:r.call_id,requests:o}});break}default:return null}}return t}const cc=["keeper_instructions","dynamic_context","active_goals","direct_input_source","completion_authority","goals_awaiting_proof","constitution_amendments","temporal_summary","memory_os_recall","librarian_working_context","recalled_memory","recalled_memory_status","operator_note","skill_compositions","arrived_stimuli"];function La(e){return cc.includes(e)?e:null}const uc=["tool_schemas","message_user","message_system","message_assistant_text","message_thinking","message_redacted_thinking","message_tool_use","message_tool_result","message_image","message_document","message_audio"],dc=["per_request","turn_total","conversation_cumulative","unavailable"],pc=["measured_request","context_estimate","agent_held_context"];function zs(e){return e.tag==="custom"?e.name:e.tag}const _c=["code_change","fact","preference","blocker","goal","constraint","validated_approach","lesson"];function fc(e){const t=_c.find(n=>n===e);return t?{tag:t}:e===e.trim()&&/^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/.test(e)?{tag:"custom",name:e}:null}function We(e,t){const n=Object.keys(e);return n.length===t.length&&n.every(r=>t.includes(r))}function Lr(e,t){return Object.keys(e).every(n=>t.includes(n))}function Ae(e){return typeof e=="string"&&e.trim().length>0?e:null}function cs(e){return typeof e!="string"||e.length!==71||!e.startsWith("sha256:")?!1:[...e.slice(7)].every(t=>t>="0"&&t<="9"||t>="a"&&t<="f")}function mc(e){return e===null?null:typeof e=="string"?e:void 0}function er(e){return e===null?null:typeof e=="number"&&Number.isFinite(e)?e:void 0}function Fe(e){const t=et(e);return t!=null&&Number.isSafeInteger(t)&&t>=0?t:null}function gc(e){const t=Fe(e);return t!==null&&t>0?t:null}function Jn(e){return et(e)??null}function kc(e){return wn(e)??null}function Qe(e,t,n){if(Object.hasOwn(e,t))return n(e[t])}function Xt(e,t){if(!Array.isArray(e))return null;const n=e.map(t);return n.every(r=>r!==null)?n:null}function vc(e){const t=new Date(Math.floor(e)*1e3);return Number.isFinite(t.getTime())?t.toISOString().replace(".000Z","Z"):null}function Go(e){if(!ve(e)||!We(e,["block","bytes","digest"]))return null;const t=La(e.block),n=Ae(e.digest),r=et(e.bytes);return t===null||n===null||!/^[0-9a-f]{64}$/.test(n)||r==null||!Number.isSafeInteger(r)||r<0?null:{block:t,bytes:r,digest:n}}function Wo(e){const t=Xt(e,Go);return t===null?null:new Set(t.map(n=>n.block)).size===t.length?t:null}const Qs="prompt.";function hc(e){if(typeof e!="string")return null;const t=uc.find(r=>r===e);if(t!==void 0)return t;if(!e.startsWith(Qs))return null;const n=La(e.slice(Qs.length));return n===null?null:`prompt.${n}`}function bc(e){if(!Array.isArray(e))return null;const t=[];for(const n of e){if(!ve(n)||!We(n,["component","bytes"]))return null;const r=hc(n.component),o=Fe(n.bytes);if(r===null||o===null)return null;t.push({component:r,bytes:o})}return new Set(t.map(n=>n.component)).size===t.length?t:null}function yc(e){if(!ve(e)||!We(e,["worker_run_id","path","start_seq","end_seq","agent_name","session_id"]))return null;const t=Ae(e.worker_run_id),n=Ae(e.path),r=Fe(e.start_seq),o=Fe(e.end_seq),i=Ae(e.agent_name),s=Ae(e.session_id);return t===null||n===null||r===null||o===null||o<r||i===null||s===null?null:{worker_run_id:t,path:n,start_seq:r,end_seq:o,agent_name:i,session_id:s}}function $c(e){return e==="wire_shape"||e==="durable_shape"?e:null}function Ec(e){return ve(e)?e.kind==="empty_history"&&Lr(e,["kind"])?{kind:"empty_history"}:(e.kind==="at_atom"||e.kind==="after_history")&&Lr(e,["kind","digest"])&&typeof e.digest=="string"&&/^[0-9a-f]{64}$/.test(e.digest)?{kind:e.kind,digest:e.digest}:null:null}function Da(e){const t=Fe(e.transmitted_atoms),n=Fe(e.total_atoms),r=$c(e.model_input_measurement),o=Ec(e.model_input_front);return t===null||n===null||t>n||r===null||o===null||o.kind==="at_atom"&&t===0||o.kind==="after_history"&&(t!==0||n===0)||o.kind==="empty_history"&&t!==0?null:{transmitted_atoms:t,total_atoms:n,model_input_measurement:r,model_input_front:o}}function Tc(e){if(!ve(e)||!Lr(e,["runtime_profile","transmitted_atoms","total_atoms","model_input_measurement","model_input_front"]))return null;const t=Ae(e.runtime_profile),n=Da(e);return t===null||n===null?null:{runtime_profile:t,...n}}function Sc(e){return pc.includes(e)?e:null}function xc(e){if(!ve(e)||!Lr(e,["execution_ids","keeper","agent_name","turn_kind","request_observations","raw_trace_run_ref","trace_id","absolute_turn","turn_ref","blocks","input_components","tool_surface_ref","request_runtime_profile","request_body_bytes","transmitted_atoms","total_atoms","model_input_measurement","response_observed_model_input","refused_model_input","model_input_front","runtime_profile","selected_model","finish_reason","context_window","provider_context_window","price_input_per_million","price_output_per_million","request_latency_ms","ttfrc_ms","temperature","top_p","max_tokens","enable_thinking","usage_scope","input_provenance","input_tokens","cache_creation_input_tokens","cache_read_input_tokens","output_tokens","turn_output_tokens","ts"]))return null;const t=Ae(e.keeper),n=Ae(e.agent_name),r=e.turn_kind==="autonomous"||e.turn_kind==="direct"?e.turn_kind:null,o=e.raw_trace_run_ref===null?null:yc(e.raw_trace_run_ref),i=Ae(e.trace_id),s=lc(e.request_observations),a=et(e.absolute_turn),_=Ae(e.turn_ref),f=Ae(e.runtime_profile),c=et(e.ts),k=Wo(e.blocks),b=e.input_components===null?null:bc(e.input_components),l=e.request_runtime_profile===null?null:Ae(e.request_runtime_profile),g=e.request_body_bytes===null?null:Fe(e.request_body_bytes),v=l!==null&&g!==null?{request_runtime_profile:l,request_body_bytes:g}:l===null&&g===null?{request_runtime_profile:null,request_body_bytes:null}:null,E=dc.find(pe=>pe===e.usage_scope),I=Qe(e,"input_provenance",Sc),S=Qe(e,"tool_surface_ref",Ae),M=Qe(e,"selected_model",Ae),w=Qe(e,"finish_reason",Ae),D=Qe(e,"context_window",Fe),re=Qe(e,"provider_context_window",gc),W=["transmitted_atoms","total_atoms","model_input_measurement","model_input_front"].every(pe=>e[pe]===null)?void 0:Da(e),z=e.response_observed_model_input===null?null:Tc(e.response_observed_model_input),ce=Qe(e,"price_input_per_million",Jn),xe=Qe(e,"price_output_per_million",Jn),te=Qe(e,"request_latency_ms",Fe),se=Qe(e,"ttfrc_ms",Jn),ue=Qe(e,"temperature",Jn),Y=Qe(e,"top_p",Jn),de=Qe(e,"max_tokens",Fe),Me=Qe(e,"enable_thinking",kc),Ce=Qe(e,"input_tokens",Fe),De=Qe(e,"output_tokens",Fe),ke=Qe(e,"turn_output_tokens",Fe),me=Qe(e,"cache_creation_input_tokens",Fe),Pe=Qe(e,"cache_read_input_tokens",Fe);return t===null||n===null||r===null||!Object.hasOwn(e,"raw_trace_run_ref")||o===null&&e.raw_trace_run_ref!==null||i===null||a==null||!Number.isSafeInteger(a)||a<0||_===null||_!==`${i}#${a}`||f===null||c==null||k===null||!Object.hasOwn(e,"input_components")||b===null&&e.input_components!==null||!Object.hasOwn(e,"request_runtime_profile")||l===null&&e.request_runtime_profile!==null||!Object.hasOwn(e,"request_body_bytes")||g===null&&e.request_body_bytes!==null||v===null||!Array.isArray(e.execution_ids)||!e.execution_ids.every(pe=>typeof pe=="string"&&pe.length>0)||E===void 0||I===null||!Object.hasOwn(e,"response_observed_model_input")||z===null&&e.response_observed_model_input!==null||S===null||M===null||w===null||D===null||re===null||W===null||ce===null||xe===null||te===null||se===null||ue===null||Y===null||s===null||de===null||Me===null||Ce===null||De===null||ke===null||me===null||Pe===null?null:{execution_ids:e.execution_ids,keeper:t,agent_name:n,turn_kind:r,raw_trace_run_ref:o,trace_id:i,absolute_turn:a,turn_ref:_,blocks:k,input_components:b,tool_surface_ref:S,...v,runtime_profile:f,selected_model:M,finish_reason:w,temperature:ue,top_p:Y,request_observations:s,max_tokens:de,enable_thinking:Me,usage_scope:E,input_provenance:I,response_observed_model_input:z,input_tokens:Ce,output_tokens:De,turn_output_tokens:ke,cache_creation_input_tokens:me,cache_read_input_tokens:Pe,context_window:D,provider_context_window:re,transmitted_atoms:W?.transmitted_atoms,total_atoms:W?.total_atoms,model_input_measurement:W?.model_input_measurement,model_input_front:W?.model_input_front,price_input_per_million:ce,price_output_per_million:xe,request_latency_ms:te,ttfrc_ms:se,ts:c}}function Rc(e){if(!ve(e)||!We(e,["added","removed","changed"]))return null;const t=Wo(e.added),n=Wo(e.removed);if(t===null||n===null||!Array.isArray(e.changed))return null;const r=e.changed.map(o=>{if(!ve(o)||!We(o,["prev","next"]))return null;const i=Go(o.prev),s=Go(o.next);return i&&s?{prev:i,next:s}:null});return r.every(o=>o!==null)?{added:t,removed:n,changed:r}:null}function Ac(e){if(!ve(e)||!We(e,["record","diff_vs_prev"]))return null;const t=xc(e.record),n=e.diff_vs_prev===null?null:Rc(e.diff_vs_prev);return!t||e.diff_vs_prev!==null&&n===null?null:{record:t,diff_vs_prev:n}}function Cc(e){if(!ve(e)||!We(e,["rule_id","premise_ids"]))return null;const t=Ae(e.rule_id),n=Xt(e.premise_ids,Ae);return t===null||n===null||n.length===0||new Set(n).size!==n.length||n.some((r,o)=>{const i=n[o-1];return i!==void 0&&i>=r})||n.some(r=>!cs(r))?null:{rule_id:t,premise_ids:n}}function Ic(e){if(!ve(e))return null;if(We(e,["post_id"])){const r=Ae(e.post_id);return r===null?null:{post_id:r,comment_id:null}}if(!We(e,["post_id","comment_id"]))return null;const t=Ae(e.post_id),n=Ae(e.comment_id);return t===null||n===null?null:{post_id:t,comment_id:n}}function Oc(e){if(!ve(e))return null;if(We(e,["kind"])&&e.kind==="observed")return{kind:"observed",board:null};if(We(e,["kind","board"])&&e.kind==="observed"){const n=Ic(e.board);return n===null?null:{kind:"observed",board:n}}if(!We(e,["kind","derivations"])||e.kind!=="derived")return null;const t=Xt(e.derivations,Cc);return t===null||t.length===0||new Set(t.map(n=>n.rule_id)).size!==t.length?null:{kind:"derived",derivations:t}}function Ua(e){if(!ve(e)||!We(e,["memory_id","claim","category","first_seen","current","basis"]))return null;const t=cs(e.memory_id)?e.memory_id:null,n=Ae(e.claim),r=typeof e.category=="string"?fc(e.category):null,o=et(e.first_seen),i=wn(e.current),s=Oc(e.basis);return t===null||n===null||r===null||o==null||i==null||s===null?null:{memory_id:t,claim:n,category:r,first_seen:o,current:i,basis:s}}function wc(e){if(!ve(e)||!We(e,["fact","missing_premise_ids"]))return null;const t=Ua(e.fact),n=Xt(e.missing_premise_ids,Ae);return t===null||t.current||t.basis.kind!=="derived"||n===null||n.length===0||new Set(n).size!==n.length||n.some((r,o)=>{const i=n[o-1];return i!==void 0&&i>=r})||n.some(r=>!cs(r))?null:{fact:t,missing_premise_ids:n}}function Pc(e){if(!ve(e)||!We(e,["kind","trace_id"]))return null;const t=Ae(e.kind),n=Ae(e.trace_id);return t!=="librarian"&&t!=="explicit_write"&&t!=="explicit_retract"||n===null?null:{kind:t,trace_id:n}}function Ys(e,t){return e.memory_id===t.memory_id&&e.claim===t.claim&&zs(e.category)===zs(t.category)&&e.first_seen===t.first_seen&&JSON.stringify(e.basis)===JSON.stringify(t.basis)}function Kc(e){const t=new Map;for(const i of e)if(i.basis.kind==="derived")for(const s of i.basis.derivations){const a={target:i.memory_id,remaining:s.premise_ids.length};for(const _ of s.premise_ids){const f=t.get(_)??[];f.push(a),t.set(_,f)}}const n=new Set,r=[],o=i=>{n.has(i)||(n.add(i),r.push(i))};for(const i of e)i.basis.kind==="observed"&&o(i.memory_id);for(let i=0;i<r.length;i+=1){const s=r[i];if(s!==void 0)for(const a of t.get(s)??[])a.remaining-=1,a.remaining===0&&o(a.target)}return n}function Nc(e){if(!ve(e)||!We(e,["shown","current","items"]))return null;const t=Fe(e.shown),n=Fe(e.current);return t===null||n===null?null:{shown:t,current:n}}function Mc(e){if(!ve(e)||!We(e,["keeper","snapshot_store","recall_enabled","revision","updated_at","update_source","read_errors","facts","change"]))return null;const t=Ae(e.keeper),n=Ae(e.snapshot_store),r=wn(e.recall_enabled),o=Fe(e.revision),i=er(e.updated_at),s=e.update_source===null?null:Pc(e.update_source),a=Xt(e.read_errors,W=>{if(!ve(W)||!We(W,["scope","error"]))return null;const z=Ae(W.scope),ce=Ae(W.error);return z===null||ce===null?null:{scope:z,error:ce}}),_=ve(e.facts)?e.facts:null,f=ve(e.change)?e.change:null,c=Nc(e.facts);if(t===null||n===null||r==null||o===null||i===void 0||e.update_source!==null&&s===null||a===null||!_||!f||!c||!We(f,["added","removed","retained","invalidated"]))return null;const k=W=>Xt(W,Ua),b=k(_.items),l=k(f.added),g=k(f.removed),v=Fe(f.retained),E=Xt(f.invalidated,wc),I=new Set(b?.map(W=>W.memory_id)??[]),S=new Map((b??[]).map(W=>[W.memory_id,W])),M=(l??[]).every(W=>{const z=S.get(W.memory_id);return z!==void 0&&Ys(W,z)}),w=(g??[]).every(W=>{const z=S.get(W.memory_id);return z===void 0||!Ys(W,z)}),D=Kc(b??[]),re=(E??[]).every(W=>{const z=W.fact.basis.kind==="derived"?W.fact.basis.derivations:[],ce=z.some(te=>te.premise_ids.every(se=>I.has(se))),xe=[...new Set(z.flatMap(te=>te.premise_ids.filter(se=>!I.has(se))))].sort();return!I.has(W.fact.memory_id)&&!ce&&xe.length===W.missing_premise_ids.length&&xe.every((te,se)=>te===W.missing_premise_ids[se])});return b===null||l===null||g===null||E===null||b.length!==c.shown||c.current!==c.shown||b.some(W=>!W.current)||D.size!==b.length||l.some(W=>!W.current)||g.some(W=>W.current)||v===null||v+l.length!==c.shown||!M||!w||new Set(l.map(W=>W.memory_id)).size!==l.length||new Set(g.map(W=>W.memory_id)).size!==g.length||new Set(E.map(W=>W.fact.memory_id)).size!==E.length||!re||o===0&&(i!==null||s!==null||c.shown!==0||l.length!==0||g.length!==0||E.length!==0||v!==0)||o>0&&(i===null||s===null)?null:{keeper:t,snapshot_store:n,recall_enabled:r,revision:o,updated_at:i,update_source:s,read_errors:a,facts:{...c,items:b},change:{added:l,removed:g,retained:v,invalidated:E}}}function Lc(e){if(!ve(e)||!We(e,["keeper","count","skipped_rows","source","producer","durable_store","dashboard_surface","freshness_slo_s","live_turn_in_progress","live_turn_started_at_unix","live_turn_last_progress_at_unix","latest_ts_unix","latest_ts_iso","latest_age_s","health","stale_reason","memory_os","entries"]))return null;const t=Ae(e.keeper),n=Fe(e.count),r=Fe(e.skipped_rows),o=e.source==="turn_record"?e.source:null,i=e.producer==="keeper_agent_run.run_turn|keeper_turn_record_writer"?e.producer:null,s=Ae(e.durable_store),a=e.dashboard_surface==="/api/v1/keepers/:name/turn-records"?e.dashboard_surface:null,_=et(e.freshness_slo_s),f=wn(e.live_turn_in_progress),c=er(e.live_turn_started_at_unix),k=er(e.live_turn_last_progress_at_unix),b=er(e.latest_ts_unix),l=mc(e.latest_ts_iso),g=er(e.latest_age_s),v=e.health==="empty"||e.health==="incompatible"||e.health==="stale"||e.health==="ok"||e.health==="live"?e.health:null,E=e.stale_reason===null||e.stale_reason==="no_entries"||e.stale_reason==="incompatible_rows"||e.stale_reason==="freshness_slo_exceeded"?e.stale_reason:void 0,I=Mc(e.memory_os),S=Xt(e.entries,Ac),M=S===null||S.length===0?null:Math.max(...S.map(D=>D.record.ts)),w=b==null?b:vc(b);return t===null||n===null||r===null||o===null||i===null||s===null||a===null||_==null||_<=0||f==null||c===void 0||k===void 0||f!==(c!==null)||f!==(k!==null)||b===void 0||l===void 0||g===void 0||g!==null&&g<0||v===null||E===void 0||I===null||I.keeper!==t||S===null||n!==S.length||S.some(D=>D.record.keeper!==t)||v!=="live"&&S.length===0!=(v==="empty"||v==="incompatible")||b!==M||l!==w||v==="empty"&&(b!==null||l!==null||g!==null||r!==0||E!=="no_entries")||v==="incompatible"&&(b!==null||l!==null||g!==null||r===0||E!=="incompatible_rows")||v==="stale"&&(b===null||l===null||g===null||g<=_||E!=="freshness_slo_exceeded")||v==="ok"&&(b===null||l===null||g===null||g>_||E!==null)||v==="live"&&(!f||E!==null)?null:{source:o,producer:i,durable_store:s,dashboard_surface:a,freshness_slo_s:_,live_turn_in_progress:f,live_turn_started_at_unix:c,live_turn_last_progress_at_unix:k,latest_ts_unix:b,latest_ts_iso:l,latest_age_s:g,health:v,stale_reason:E,keeper:t,count:n,skipped_rows:r,memory_os:I,entries:S}}function Dc(e){if(Object.hasOwn(e,"disposition"))switch(e.disposition){case"completed":return"succeeded";case"failed":return"failed";case"deferred":return"deferred";default:return"malformed"}if(Object.hasOwn(e,"wire_outcome"))switch(e.wire_outcome){case"ok":return"succeeded";case"error":return"failed";case"unknown":return"unsettled";default:return"malformed"}return"unsettled"}function Uc(e,t){const n=new URLSearchParams({state:"queued"});return t!==void 0&&n.set("after_sequence",t),`/api/v1/keepers/${encodeURIComponent(e)}/chat/operations?${n}`}function Bc(e,t,n){if(typeof e!="object"||e===null||!("schema"in e)||e.schema!=="masc.keeper_chat_operations.list.v1"||!("state"in e)||e.state!=="Queued"||!("operations"in e)||!Array.isArray(e.operations))throw new Error("Keeper chat operation list has an invalid contract");let r=t;return e.operations.map(o=>{const i=n(o);if(r!==void 0&&BigInt(i.sequence)<=BigInt(r))throw new Error("Keeper chat operation page sequence did not advance");return r=i.sequence,i})}async function qc(e,t){const n=new Map;let r=t;for(;;){const o=await e(r);if(!o.ok)return o;if(o.value.length===0)return qr([...n.values()]);for(const i of o.value)r=i.sequence,n.delete(i.operationId),n.set(i.operationId,i)}}const Fc="[masc:blob ",Hc=/^\[masc:blob sha256=([0-9a-fA-F]{64}) bytes=(\d+) mime=(\S+)(?: answer_sha256=([0-9a-fA-F]{64}))? preview="((?:[^"\\]|\\.)*)"\]$/;function jc(e){if(!e.startsWith(Fc))return null;const t=e.match(Hc);if(!t)return null;const[,n,r,o,i,s]=t;return n===void 0||r===void 0||o===void 0||s===void 0?null:{sha256:n.toLowerCase(),bytes:Number(r),mime:o,preview:Gc(s),...i===void 0?{}:{answerSha256:i.toLowerCase()}}}function Gc(e){const t=new TextEncoder,n=[],r=i=>{for(const s of t.encode(i))n.push(s)};let o=0;for(;o<e.length;){const i=e.indexOf("\\",o);if(i===-1){r(e.slice(o));break}i>o&&r(e.slice(o,i));const s=e[i+1];if(s===void 0)break;const a=e.slice(i+1,i+4);if(/^[0-9]{3}$/.test(a)){n.push(Number(a)&255),o=i+4;continue}const _=e.slice(i+2,i+4);if(s==="x"&&/^[0-9a-fA-F]{2}$/.test(_)){n.push(parseInt(_,16)),o=i+4;continue}switch(o=i+2,s){case"\\":n.push(92);break;case'"':n.push(34);break;case"n":n.push(10);break;case"t":n.push(9);break;case"r":n.push(13);break;case"b":n.push(8);break;default:r(s)}}return new TextDecoder().decode(Uint8Array.from(n))}const un=Object.freeze({thinking:"collapsed",tools:"summary",internal:"hidden"}),Ba="masc:keeper-chat-block-prefs:v1";function Js(e){return e==="hidden"?"collapsed":e==="collapsed"?"expanded":"hidden"}function Wc(e){return e==="hidden"?"summary":e==="summary"?"full":"hidden"}function Vc(e){return e==="hidden"?"shown":"hidden"}function Xs(e){return e==="hidden"?"숨김":e==="collapsed"?"접힘":"펼침"}function Zs(e){return e==="hidden"?"숨김":e==="summary"?"요약":"전체"}function ea(e){return e==="hidden"?"숨김":"표시"}function zc(){if(typeof window>"u")return un;try{const e=window.localStorage.getItem(Ba);if(!e)return un;const t=JSON.parse(e);if(typeof t!="object"||t===null)return un;const n=t,r=n.thinking==="hidden"||n.thinking==="collapsed"||n.thinking==="expanded"?n.thinking:un.thinking,o=n.tools==="hidden"||n.tools==="summary"||n.tools==="full"?n.tools:un.tools,i=n.internal==="hidden"||n.internal==="shown"?n.internal:un.internal;return{thinking:r,tools:o,internal:i}}catch{return un}}function Qc(e){if(!(typeof window>"u"))try{window.localStorage.setItem(Ba,JSON.stringify(e))}catch{}}function Vo(e){const t=e.trim();if(!t.startsWith("{")||!t.endsWith("}"))return null;try{const n=JSON.parse(t);return typeof n=="object"&&n!==null&&!Array.isArray(n)?n:null}catch{return null}}function Yt(e,t=110){if(e==null)return"";const n=typeof e=="string"?e.replace(/\s+/g," ").trim():JSON.stringify(e);return n.length<=t?n:`${n.slice(0,t-1)}…`}function pn(e){if(e==null)return"";if(typeof e=="string"){const t=e.trim();if(t.startsWith("{")&&t.endsWith("}")||t.startsWith("[")&&t.endsWith("]"))try{return JSON.stringify(JSON.parse(t),null,2)}catch{return e}return e}return JSON.stringify(e,null,2)}function Yc(e){const t=jc(e);return t?.mime.toLowerCase().split(";",1)[0]==="text/markdown"&&t.preview.trim()?t.preview:null}const qa="think|thinking|thought|reasoning|memory_recall|memory|recalled_memory",Fa=new RegExp(`
 {0,3}<(?:${qa})>`,"i"),Ha=new RegExp(`^ {0,3}<(${qa})>([\\s\\S]*?)</\\1\\s*>`,"i"),Jc=new yl().use({extensions:[{name:"chatAuxiliary",level:"block",start(e){const t=e.search(Fa);return t>=0?t+1:void 0},tokenizer(e){const t=Ha.exec(e);if(!t)return;const n=t[1]?.toLowerCase(),r=n==="think"||n==="thinking"||n==="thought"||n==="reasoning"?"thinking":"memory";return{type:"chatAuxiliary",raw:t[0],kind:r,text:(t[2]??"").trim()}}}]});function Xc(e){const t=[],n=[];if(!Ha.test(e)&&!Fa.test(e))return{thinking:t,memory:n,body:e.trim()};const r=[];for(const o of Jc.lexer(e))if(o.type==="chatAuxiliary"){if(!o.text)continue;o.kind==="thinking"?t.push(o.text):n.push(o.text)}else r.push(o.raw);return{thinking:t,memory:n,body:r.join("").trim()}}const ta=new WeakMap;function ja(e){const t=ta.get(e);if(t!==void 0&&t.role===e.role&&t.kind===e.kind&&t.content===e.content&&t.thinking===e.thinking&&t.toolName===e.toolName&&t.executionId===e.executionId&&t.toolCalls===e.toolCalls&&t.memoryItems===e.memoryItems&&t.autonomousTurn===e.autonomousTurn)return t.parsed;const n=Zc(e);return ta.set(e,{role:e.role,kind:e.kind,content:e.content,thinking:e.thinking,toolName:e.toolName,executionId:e.executionId,toolCalls:e.toolCalls,memoryItems:e.memoryItems,autonomousTurn:e.autonomousTurn,parsed:n}),n}function Zc(e){if(e.role==="user")return{thinkingText:null,bodyText:e.content,toolBlocks:[],memoryItems:[],autonomousSummary:null,autonomousDetails:null,isInternalOnly:!1,isToolOnly:!1};const t=Xc(e.content),n=t.body,r=[e.thinking?.trim(),...t.thinking].filter(E=>!!(E&&E.length>0)),o=r.length>0?r.join(`

`):null,i=[...e.toolCalls??[]],s=[...e.memoryItems??[],...t.memory];let a=n,_=null,f=null;const c=Vo(n);if((e.role==="tool"||e.kind==="tool_call"||e.kind==="tool_result"||c!==null&&(typeof c.tool_name=="string"||typeof c.tool=="string")&&("args"in c||"input"in c||"result"in c||"output"in c))&&i.length===0){const E=e.toolName??(typeof c?.tool_name=="string"?c.tool_name:void 0)??(typeof c?.tool=="string"?c.tool:void 0)??"tool",I=c!==null&&(typeof c.tool_name=="string"||typeof c.tool=="string")&&("args"in c||"input"in c||"arguments"in c||"result"in c||"output"in c);let S,M,w;if(e.role==="tool"&&!I)c!==null?S=c:n&&(S=n);else{const D=c?c.args??c.input??c.arguments:void 0,re=c?c.result??c.output:void 0;S=D,M=re,S===void 0&&M===void 0&&(c!==null?e.kind==="tool_call"?S=c:M=c:e.content&&(M=e.content)),w=typeof c?.status=="string"?c.status:typeof c?.outcome=="string"?c.outcome:void 0}i.push({executionId:e.executionId,name:E,args:S!==void 0?pn(S):void 0,result:typeof M=="string"?M:M!==void 0?pn(M):void 0,status:w}),a=""}if(e.kind==="memory_recall"||c!==null&&(Array.isArray(c.memory_recall)||Array.isArray(c.recalled_facts)||c.kind==="memory_recall")){if(c){const E=Array.isArray(c.memory_recall)?c.memory_recall:Array.isArray(c.recalled_facts)?c.recalled_facts:Array.isArray(c.facts)?c.facts:[];for(const I of E)if(typeof I=="string"&&I.trim())s.push(I.trim());else if(typeof I=="object"&&I!==null){const S=I,M=typeof S.claim=="string"?S.claim:Yt(S,160);M&&s.push(M)}s.length===0&&s.push(pn(c))}else n&&s.length===0&&s.push(n);a=""}(e.autonomousTurn===!0||e.kind==="autonomous"||c!==null&&(c.autonomous===!0||c.turn_kind==="autonomous"||c.source==="autonomous"))&&(c?(_=typeof c.summary=="string"&&c.summary.trim()||typeof c.reply=="string"&&c.reply.trim()||typeof c.action=="string"&&c.action.trim()||Yt(c,120),f=pn(c),a=""):(_=Yt(n||"자율 턴 기록",120),f=n||null,i.length===0&&(a="")));const l=e.kind==="memory_recall"||e.kind==="autonomous"||e.kind==="system_internal"||e.autonomousTurn===!0||e.role==="system"&&a.length===0&&(s.length>0||_!==null),g=a.length===0&&o===null&&i.length>0&&s.length===0&&_===null,v=a.length===0&&i.length===0&&(l||s.length>0||_!==null);return{thinkingText:o,bodyText:a,toolBlocks:i,memoryItems:s,autonomousSummary:_,autonomousDetails:f,isInternalOnly:v,isToolOnly:g}}function eu(e,t,n){if(e.errorDetail||e.attachments?.length||e.retainedImages?.length||e.deliveryState==="Streaming")return!0;if(t.isInternalOnly&&n.internal==="hidden"||t.isToolOnly&&n.tools==="hidden")return!1;const r=t.bodyText.length>0,o=t.thinkingText!==null&&n.thinking!=="hidden",i=t.toolBlocks.length>0&&n.tools!=="hidden",s=n.internal==="shown"&&(t.memoryItems.length>0||t.autonomousSummary!==null);return r||o||i||s}function Dr(e){const t=new Map,n=new Map;for(const s of e){if(s.role!=="tool")continue;const a=ja(s);for(const _ of a.toolBlocks){const f=_.executionId?.trim()||s.executionId?.trim();if(!f)continue;const c=Ot([..._.attachments??[],...s.attachments??[]]);c.length>0&&n.set(f,Ot([...n.get(f)??[],...c]));const k=t.get(f);if(!k)t.set(f,{..._,executionId:f,...c.length>0?{attachments:c}:{}});else{const b=Ot([...k.attachments??[],...c]);t.set(f,{...k,name:k.name!=="tool"?k.name:_.name,args:k.args??_.args,result:k.result??_.result,status:k.status??_.status,duration:k.duration??_.duration,...b.length>0?{attachments:b}:{}})}}}const r=new Set,o=e.map(s=>{if(s.role==="tool"||!s.toolCalls||s.toolCalls.length===0)return s;let a=!1;const _=[],f=s.toolCalls.map(k=>{const b=k.executionId?.trim();if(!b)return k;r.add(b);const l=t.get(b),g=n.get(b)??[];if(g.length>0&&_.push(...g),!l&&g.length===0)return k;const v=k.name!=="tool"?k.name:l?.name??k.name,E=k.args??l?.args,I=k.result??l?.result,S=k.status??l?.status,M=Ot([...k.attachments??[],...g]),w=M.length>0?M:void 0;return v!==k.name||E!==k.args||I!==k.result||S!==k.status||(w?.length??0)!==(k.attachments?.length??0)?(a=!0,{...k,name:v,args:E,result:I,status:S,...w?{attachments:w}:{}}):k});if(!a&&_.length===0)return s;const c=_.length>0?Ot([...s.attachments??[],..._]):s.attachments;return{...s,toolCalls:f,...c&&c.length>0?{attachments:c}:{}}}),i=new Set;return o.filter(s=>{if(s.role!=="tool")return!0;const a=s.executionId?.trim()||s.toolCalls?.find(_=>_.executionId?.trim())?.executionId?.trim();return a?r.has(a)||i.has(a)?!1:(i.add(a),!0):!0})}function zo(e,t){const n=t.streamKey?.trim()||void 0,r=t.toolCallId?.trim()||void 0;if(n){const o=e.findIndex(i=>i.streamKey===n);if(o>=0)return o}if(r)if(n){const o=e.findIndex(i=>i.id===r&&(!i.streamKey||i.streamKey===n));if(o>=0)return o}else{let o=-1;for(let i=e.length-1;i>=0;i-=1){const s=e[i];if(s.id===r){if(s.status==="running"||s.status==="awaiting_result"||s.status==="awaiting_approval"||s.status==="result_ready")return i;o<0&&(o=i)}}if(o>=0)return o}return!n&&!r&&e.length>0?e.length-1:-1}function kt(e,t,n,r){const o=[...e??[]],i=zo(o,t);return i>=0?(o[i]=n(o[i]),o):(r&&o.push(r()),o)}function tu(e){switch(e){case"running":case"pending":return{label:"실행 중",tone:"info"};case"awaiting_result":return{label:"결과 대기",tone:"info"};case"result_ready":return{label:"결과 준비",tone:"info"};case"awaiting_approval":return{label:"승인 대기",tone:"warn"};case"interrupted":return{label:"중단됨",tone:"bad"};case"error":case"failed":case"err":case"denied":case"rejected":return{label:"오류",tone:"bad"};case"completed":case"ok":case"settled":return{label:"완료",tone:"ok"};default:return{label:e||"실행됨",tone:"info"}}}function nu(e){const t=typeof e.kind=="string"?e.kind:null;if(!t)return null;if(t==="message_reported"&&typeof e.message=="string"&&e.message.trim())return Yt(e.message,80);if(t==="heartbeat_reported"&&typeof e.elapsed_seconds=="number")return`실행 중 (${e.elapsed_seconds}s)`;if(t==="output_observed"&&typeof e.byte_count=="number")return`출력 ${e.byte_count.toLocaleString("en-US")}B`;if(t==="retry_reported"){const n=typeof e.attempt=="number"?e.attempt:null,r=typeof e.max_retries=="number"?e.max_retries:null,o=typeof e.error_category=="string"?e.error_category:"";return`재시도 ${n!==null&&r!==null?`${n}/${r}`:""}${o?` · ${o}`:""}`.trim()}return t==="retry_cleared"?"재시도 복구됨":null}function ru(e){const t=typeof e.kind=="string"?e.kind:"end_observed",n=typeof e.exit_code=="number"?e.exit_code:null,r=t==="error_reported"||t==="decline_reported"||t==="result_received"&&e.is_error===!0||n!==null&&n!==0,o=[];return t==="error_reported"?o.push("오류 보고됨"):t==="decline_reported"?o.push("거절됨"):t==="unrecognized_status"&&typeof e.status=="string"&&o.push(e.status),n!==null&&o.push(`exit ${n}`),{status:r?"error":"completed",summary:o.length>0?o.join(" · "):void 0}}function st(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}function us(e){const t=e.name.trim();let n=null;if(t==="masc_keeper_delegate"?n="delegate":t==="masc_keeper_delegate_status"||t==="masc_keeper_delegate_status_many"?n="delegate_status":t==="masc_keeper_delegate_cancel"&&(n="delegate_cancel"),!n)return null;const r=e.args?Vo(e.args):null,o=e.result?Vo(e.result):null,i=S=>{if(!S)return null;if(typeof S.target=="object"&&S.target!==null&&!Array.isArray(S.target)){const M=S.target,w=st(M.name);if(w)return w}return st(S.target)??st(S.keeper_name)??st(S.delegate)},s=new Set,a=i(r)??i(o);a&&s.add(a);let _=0,f=null;const c=[];r&&Array.isArray(r.operations)&&c.push(r.operations),o&&Array.isArray(o.operations)&&c.push(o.operations),o&&Array.isArray(o.results)&&c.push(o.results);for(const S of c){S.length>_&&(_=S.length);for(const M of S){if(typeof M!="object"||M===null||Array.isArray(M))continue;const w=M,D=i(w);D&&s.add(D),f||(f=st(w.operation_id)??st(w.request_id))}}const k=Array.from(s),b=k[0]??null,l=(r?st(r.prompt)??st(r.message):null)??(o?st(o.prompt):null),g=(r?st(r.operation_id)??st(r.request_id):null)??(o?st(o.operation_id)??st(o.request_id):null)??f;_===0&&g&&(_=1);const v=r&&Array.isArray(r.artifacts)?r.artifacts.length:0,E=(o?st(o.state)??st(o.status):null)??(r?st(r.state):null),I=o&&typeof o.target_turn_age_s=="number"&&Number.isFinite(o.target_turn_age_s)?Math.max(0,Math.round(o.target_turn_age_s)):null;return{kind:n,targetKeeper:b,targetKeepers:k,operationCount:_,prompt:l,operationId:g,artifactCount:v,delegateState:E,targetTurnAgeSec:I}}function ou(e){const t=us(e);if(t){if(t.kind==="delegate")return t.targetKeeper?`위임(@${t.targetKeeper})`:"위임";if(t.kind==="delegate_status"){if(t.targetKeepers.length>1){const n=t.targetKeepers.slice(0,2).map(o=>`@${o}`).join(","),r=t.targetKeepers.length-2;return r>0?`위임조회(${n} 외 ${r})`:`위임조회(${n})`}return t.targetKeeper?`위임조회(@${t.targetKeeper})`:t.operationCount>1?`위임조회(${t.operationCount}건)`:"위임조회"}return t.targetKeeper?`위임취소(@${t.targetKeeper})`:"위임취소"}return e.name}function Ga(e,t=4){const n=new Map;for(const s of e){const a=ou(s);n.set(a,(n.get(a)??0)+1)}const r=Array.from(n.entries()),o=r.slice(0,t).map(([s,a])=>a>1?`${s} ×${a}`:s),i=r.length-o.length;return i>0&&o.push(`외 ${i}종`),o.join(" · ")}function su(e){const t=[];let n=[];const r=()=>{if(n.length===0)return;const o=[],i=new Set;for(const s of n)for(const a of s.blocks.toolBlocks){o.push(a);const _=us(a);if(_)for(const f of _.targetKeepers)i.add(f)}t.push({kind:"tool_group",id:`tool-group:${n[0].msg.id}`,entries:n,toolBlocks:o,toolSummary:Ga(o),delegateTargets:Array.from(i)}),n=[]};for(const o of e)o.blocks.isToolOnly&&!o.msg.errorDetail&&!o.msg.retainedImages?.length&&!o.msg.attachments?.length?n.push(o):(r(),t.push({kind:"message",id:o.msg.id,entry:o}));return r(),t}function xr(e){return e.operationId!==void 0&&e.deliveryProvenance===void 0||e.deliveryState!==void 0&&e.deliveryState!=="Delivered"&&e.deliveryState!=="Cut_recovered"}function Qo(e,...t){const n=e.deliveryProvenance;return n?.delivery_key.kind==="operation"&&t.includes(n.transcript_slot.kind)?n.delivery_key.operation_id:void 0}function au(e,t){return e.some(n=>Qo(n,"terminal_result","settled_failure")===t)}function iu(e,t,n=null,r){const o=l=>l.role==="assistant"&&l.deliveryProvenance===void 0&&l.deliveryState==="Delivered"&&l.operationId!==void 0&&r?.has(l.operationId)===!0;if(t.length===0)return e.filter(l=>xr(l)&&!o(l));let i=t;if(n!==null){const l=e.filter(S=>S.operationId===n.operationId&&S.deliveryProvenance===void 0),g=l.find(S=>S.role==="user"),v=l.find(S=>S.role==="assistant"),E=S=>t.find(M=>Qo(M,"terminal_result","settled_failure")===S),I=E(n.operationId)??E(n.executionId);i=t.map(S=>S===I&&v?v:g&&Qo(S,"accepted_user")===n.operationId?g:S)}const s=new Set(t.map(l=>l.id)),a=new Set,_=new Set;for(const l of i){s.add(l.id);const g=l.deliveryProvenance;if(g?.delivery_key.kind!=="operation")continue;const v=g.delivery_key.operation_id;switch(g.transcript_slot.kind){case"accepted_user":a.add(v);break;case"terminal_result":case"settled_failure":_.add(v);break}}const f=l=>s.has(l.id)?!1:l.operationId===void 0||l.deliveryProvenance!==void 0?!0:l.role==="user"?!a.has(l.operationId):o(l)?!1:!_.has(l.operationId)&&(l.replyOperationId===void 0||!_.has(l.replyOperationId)),c=e.findIndex(l=>s.has(l.id));if(c>=0){const l=e.slice(0,c).filter(f),g=e.slice(c).filter(v=>f(v)&&xr(v));return Dr([...l,...i,...g])}const k=e.filter(l=>f(l)&&!xr(l)),b=e.filter(l=>f(l)&&xr(l));return Dr([...k,...i,...b])}function Wa(e){switch(e){case"autonomous":case"proactive":return"자율 턴";case"delegated":case"delegate":return"위임 턴";case"schedule":case"scheduled":return"예약 턴";case"board":case"board_attention":return"보드 턴";case"chat":case"chat_operation":case"direct":return"대화 턴";case"maintenance":return"유지보수 턴";case"keepalive":return"유지 턴";case"task":return"작업 턴";case"verification":return"검증 턴";case"internal":return"내부 턴";default:return e?`${e} 턴`:"활성 턴"}}function ds(e){switch(e){case"preparing":return{label:"준비 중",tone:"info"};case"waiting":return{label:"응답 대기 중",tone:"warn"};case"streaming":return{label:"스트리밍 중",tone:"brass"};case"tool":return{label:"도구 실행 중",tone:"info"};case"tool_observed":return{label:"도구 관측",tone:"info"};case"failed":return{label:"시도 실패",tone:"bad"};default:return{label:"진행 중",tone:"info"}}}function lu(e){switch(e){case"event_queue_pending":case"event_queue":return"이벤트 큐";case"chat_operation_queued":return"대화 대기";case"chat_operation_running":case"chat_operation":return"대화 실행";case"hitl_pending":case"approval":case"approval_count":case"approval_detail":return"승인 대기";case"fusion_running":return"퓨전 실행";case"schedule_waiting":return"예약 대기";case"owner_shutdown":return"종료 중";case"operator_pending_confirm":return"운영자 확인";case"runtime_quota_spent":return"할당 소진";case"read_error":return"조회 오류";case"observation_unavailable":return"관측 불가";case"delegate":case"keeper_delegate":return"위임";default:return e}}function fn(e){const t=Math.max(0,Math.floor(e));return t<60?`${t}s`:t<3600?`${Math.floor(t/60)}m ${String(t%60).padStart(2,"0")}s`:`${Math.floor(t/3600)}h ${String(Math.floor(t%3600/60)).padStart(2,"0")}m`}function Va(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function na(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function ra(e){return typeof e=="number"&&Number.isInteger(e)&&e>=0?e:null}function cu(e){switch(e){case"none":case"thinking":case"text":return e;default:return null}}function uu(e){switch(e){case"requested":case"executing":return e;default:return null}}function du(e){switch(e){case void 0:case null:return{ok:!0,value:null};case"masc_state":case"sandbox":case"network":case"model_provider":return{ok:!0,value:e};default:return{ok:!1}}}function pu(e){if(e==null)return{ok:!0,value:null};if(!Va(e))return{ok:!1};const t=ra(e.batch_index),n=ra(e.batch_size);return t===null||n===null||typeof e.concurrent!="boolean"?{ok:!1}:{ok:!0,value:{batch_index:t,batch_size:n,concurrent:e.concurrent}}}function _u(e){if(!Va(e))return null;const t=na(e.started_at_unix),n=na(e.since_unix);if(t===null||n===null)return null;if(e.kind==="response"){const r=cu(e.channel);return r===null?null:{kind:"response",channel:r,started_at_unix:t,since_unix:n}}if(e.kind==="tool"){const r=typeof e.name=="string"?e.name.trim():"",o=uu(e.stage),i=pu(e.cohort),s=du(e.reach),a=e.tool_use_id;return r===""||o===null||!i.ok||!s.ok||a!=null&&typeof a!="string"?null:{kind:"tool",tool_use_id:typeof a=="string"?a:null,name:r,stage:o,started_at_unix:t,since_unix:n,cohort:i.value,reach:s.value}}return null}function fu(e){if(!Array.isArray(e))return null;const t=[];for(const n of e){const r=_u(n);if(r===null)return null;t.push(r)}return t}function mu(e){return e.kind!=="tool"||e.cohort===null?null:e.cohort.concurrent&&e.cohort.batch_size>1?{index:e.cohort.batch_index,size:e.cohort.batch_size}:null}function gu(e){const t=[],n=new Map;for(const r of e){const o=mu(r);if(o===null||r.kind!=="tool"){t.push({kind:"single",activity:r});continue}const i=n.get(o.index);if(i===void 0)n.set(o.index,t.length),t.push({kind:"batch",batchSize:o.size,members:[r]});else{const s=t[i];s?.kind==="batch"&&(t[i]={kind:"batch",batchSize:Math.max(s.batchSize,o.size),members:[...s.members,r]})}}return t}function za(e){switch(e){case"requested":return"호출 준비";case"executing":return"실행 중"}}function Qa(e){if(e.kind==="response")switch(e.channel){case"thinking":return"추론 중";case"text":return"답변 쓰는 중";case"none":return"모델 응답 기다리는 중"}return`${e.name} · ${za(e.stage)}`}function ku(e){const t=e.filter(r=>r.kind==="tool"),n=t.find(r=>r.stage==="executing")??t[0]??e[0];return n===void 0?null:{lead:n,otherCalls:n.kind==="tool"?t.length-1:0}}function vu(e,t){return e.some(n=>n.kind==="tool"&&n.name===t)}function Ya(e){return`외 ${e}건`}function hu({lead:e,otherCalls:t}){return e.kind==="response"||t===0?Qa(e):`${e.name} ${Ya(t)} · ${za(e.stage)}`}function bu(e){if(e.kind!=="tool")return null;switch(e.reach){case"network":return"외부 · 네트워크";case"model_provider":return"외부 · 모델";case"sandbox":return"샌드박스";case"masc_state":case null:return null}}function yu(e){return e.kind==="tool"&&(e.reach==="network"||e.reach==="model_provider")}function $u(e){return e.kind==="tool"?"tool":e.channel==="thinking"?"thinking":"active"}const Eu=["KEEPER_CONNECTED","KEEPER_RUNTIME_ATTEMPT_STARTED","KEEPER_PROVIDER_RETRY","KEEPER_STREAM_MESSAGE_START","KEEPER_STREAM_MESSAGE_DELTA","KEEPER_STREAM_MESSAGE_STOP","KEEPER_STREAM_PING","KEEPER_CONTENT_BLOCK_START","KEEPER_CONTENT_BLOCK_STOP","KEEPER_MODEL_CONTENT_ACTIVITY","KEEPER_THINKING_DELTA","KEEPER_THINKING_SNAPSHOT","KEEPER_THINKING_SIGNATURE_DELTA","KEEPER_ATTACHMENT","KEEPER_MEDIA_DELTA","KEEPER_STREAM_PROTOCOL_ERROR","KEEPER_CHAT_OPERATION_ACCEPTED","KEEPER_CHAT_BATCH_BOUND","KEEPER_CONTINUATION_CHECKPOINT","KEEPER_EXTERNAL_EFFECT_COMPLETED","KEEPER_REPLY_DETAILS","KEEPER_TOOL_APPROVAL_REQUESTED","KEEPER_TOOL_APPROVAL_SETTLED","KEEPER_TOOL_CALL_ADMITTED","KEEPER_TOOL_RESULT_READY","KEEPER_TOOL_TRANSCRIPT_COMMITTED","KEEPER_NATIVE_TOOL_START","KEEPER_NATIVE_TOOL_END","KEEPER_NATIVE_TOOL_PROGRESS"],Tu=["tool_start_duplicate_index","tool_start_missing_identity","tool_args_without_start","tool_stop_without_start","tool_replay_mismatch","tool_delta_invalid_kind","tool_attempt_superseded","tool_message_start_conflict","stream_event_after_terminal","tool_occurrence_mapping_invalid","media_delta_invalid_block","media_source_unsupported","media_decode_failed","media_payload_too_large","media_persist_failed","sse_error","ndjson_error","sse_parse_failed","ndjson_parse_failed","sse_unknown_event_type","sse_unsupported_part","sse_unsupported_response","sse_stream_incomplete","sse_timeout"],Su=new Set(["RUN_STARTED","RUN_FINISHED","RUN_ERROR","TEXT_MESSAGE_START","TEXT_MESSAGE_CONTENT","TEXT_MESSAGE_END","TOOL_CALL_START","TOOL_CALL_ARGS","TOOL_CALL_END","CUSTOM"]),xu=new Set(Eu);function oa(e){return xu.has(e)}const Ct=["type","threadId","timestamp"],Ru=new Map([["RUN_STARTED",new Set([...Ct,"runId"])],["RUN_FINISHED",new Set([...Ct,"runId"])],["RUN_ERROR",new Set([...Ct,"runId","message","code"])],["TEXT_MESSAGE_START",new Set([...Ct,"runId","messageId","role"])],["TEXT_MESSAGE_CONTENT",new Set([...Ct,"runId","messageId","delta","textStreamScope","textResponse"])],["TEXT_MESSAGE_END",new Set([...Ct,"runId","messageId"])],["TOOL_CALL_START",new Set([...Ct,"runId","toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","toolCallName"])],["TOOL_CALL_ARGS",new Set([...Ct,"runId","toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","delta","snapshot"])],["TOOL_CALL_END",new Set([...Ct,"runId","toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId"])],["CUSTOM",new Set([...Ct,"runId","name","value"])]]);function fe(e){return{success:!0,data:e}}function Z(e,t){return{success:!1,error:{issues:[{path:e,message:t}]}}}const Au=new Set(Tu),Cu=new Set(["visible_reply","continuation_checkpoint","external_effect_completed","external_effect_pending","no_visible_reply"]);function it(e,t,n,r="ag_ui_event.value"){if(!ve(e))return Z(r,`Expected ${t} object payload`);const o=new Set(n),i=Object.keys(e).find(s=>!o.has(s));return i?Z(`${r}.${i}`,`Unexpected ${t} payload field`):fe(e)}function Ee(e,t,n=!1){return typeof e[t]=="string"&&(n||e[t].trim()!=="")?fe(!0):Z(`ag_ui_event.value.${t}`,`Expected non-empty ${t}`)}function Oe(e,t,n=0){const r=e[t];return typeof r=="number"&&Number.isSafeInteger(r)&&r>=n?fe(!0):Z(`ag_ui_event.value.${t}`,`Expected ${t} integer >= ${n}`)}function Rr(e){const t=it(e,"response",["content_generation","stream_scope"]);if(!t.success)return t;const n=Oe(t.data,"content_generation");return n.success?Oe(t.data,"stream_scope"):n}function Sn(e,t){return e[t]===void 0||typeof e[t]=="string"&&e[t].trim()!==""?fe(!0):Z(`ag_ui_event.value.${t}`,`Expected non-empty optional ${t}`)}function Iu(e,t){return e[t]===void 0||typeof e[t]=="string"?fe(!0):Z(`ag_ui_event.value.${t}`,`Expected optional string ${t}`)}function _n(e,t){for(const n of["toolStreamScope","toolCallBlockIndex"]){const r=e[n];if(typeof r!="number"||!Number.isSafeInteger(r)||r<0)return Z(`${t}.${n}`,`Expected ${n} non-negative integer`)}for(const n of["providerMessageId","toolCallId"]){const r=e[n];if(r!==void 0&&(typeof r!="string"||r.trim()===""))return Z(`${t}.${n}`,`Expected non-empty optional ${n}`)}return fe(!0)}function Ou(e){const t="ag_ui_event.value.quarantined_occurrence",n=it(e,"quarantined_occurrence",["toolStreamScope","toolCallBlockIndex","providerMessageId"],t);return n.success?_n(n.data,t):n}function wu(e){const t=it(e,"usage",["input_tokens","output_tokens","total_tokens","cache_creation_input_tokens","cache_read_input_tokens","cost_usd"]);if(!t.success)return t;for(const n of["input_tokens","output_tokens","total_tokens","cache_creation_input_tokens","cache_read_input_tokens"]){const r=Oe(t.data,n);if(!r.success)return r}return t.data.cost_usd===void 0||typeof t.data.cost_usd=="number"&&Number.isFinite(t.data.cost_usd)?fe(!0):Z("ag_ui_event.value.usage.cost_usd","Expected finite cost_usd")}function Pu(e){const t=it(e,"usage",["input_tokens","output_tokens","cache_creation_input_tokens","cache_read_input_tokens","cost_usd"]);if(!t.success)return t;for(const n of["input_tokens","output_tokens","cache_creation_input_tokens","cache_read_input_tokens"]){if(t.data[n]===void 0)continue;const r=Oe(t.data,n);if(!r.success)return r}return t.data.cost_usd===void 0||typeof t.data.cost_usd=="number"&&Number.isFinite(t.data.cost_usd)&&t.data.cost_usd>=0?fe(!0):Z("ag_ui_event.value.usage.cost_usd","Expected finite nonnegative cost_usd")}function Ro(e){const t=_n(e,"ag_ui_event.value");if(!t.success)return t;for(const n of["providerMessageId","toolCallId","toolCallName"]){if(!Object.prototype.hasOwnProperty.call(e,n))continue;const r=Ee(e,n);if(!r.success)return r}return fe(!0)}function Ku(e){const t="ag_ui_event.value.completion";if(!ve(e))return Z(t,"Expected native completion object");let n;switch(e.kind){case"end_observed":case"completion_reported":case"error_reported":case"decline_reported":n=["kind","exit_code"];break;case"result_received":if(n=["kind","exit_code","is_error"],e.is_error!==null&&typeof e.is_error!="boolean")return Z(`${t}.is_error`,"Expected reported native error boolean or null");break;case"unrecognized_status":if(n=["kind","exit_code","status"],typeof e.status!="string")return Z(`${t}.status`,"Expected original native status string");break;case"completion_unrecorded":if(n=["kind","exit_code"],e.exit_code!==null)return Z(`${t}.exit_code`,"Expected no exit code for an unrecorded native completion");break;default:return Z(`${t}.kind`,"Expected typed native completion kind")}const r=it(e,"native completion",n,t);return r.success?e.exit_code===null||typeof e.exit_code=="number"&&Number.isSafeInteger(e.exit_code)?fe(!0):Z(`${t}.exit_code`,"Expected native exit code integer or null"):r}function sa(e){if(typeof e!="string")return!1;for(const t of e)switch(t){case" ":case"	":case`
`:case"\r":case"\f":break;default:return!0}return!1}function Nu(e){const t="ag_ui_event.value.progress";if(!ve(e))return Z(t,"Expected native progress object");switch(e.kind){case"retry_reported":case"retry_cleared":{const n=["kind","agent_id","subagent_type"];e.kind==="retry_reported"&&n.push("attempt","max_retries","retry_delay_ms","error_status","error_category");const r=it(e,"native retry observation",n,t);if(!r.success)return r;for(const o of["agent_id","subagent_type"]){const i=e[o];if(!sa(i))return Z(`${t}.${o}`,"Expected nonblank native retry identity")}if(e.kind==="retry_reported"){for(const o of["attempt","max_retries","retry_delay_ms"]){const i=e[o];if(typeof i!="number"||!Number.isSafeInteger(i))return Z(`${t}.${o}`,"Expected native retry safe integer")}if(e.error_status!==null&&(typeof e.error_status!="number"||!Number.isSafeInteger(e.error_status)))return Z(`${t}.error_status`,"Expected native retry status integer or null");if(!sa(e.error_category))return Z(`${t}.error_category`,"Expected native retry error category")}return fe(!0)}case"output_observed":{const n=it(e,"native output observation",["kind","byte_count"],t);return n.success?typeof e.byte_count=="number"&&Number.isSafeInteger(e.byte_count)&&e.byte_count>0?fe(!0):Z(`${t}.byte_count`,"Expected positive native output byte count"):n}case"heartbeat_reported":{const n=it(e,"native heartbeat",["kind","elapsed_seconds"],t);return n.success?typeof e.elapsed_seconds=="number"&&Number.isSafeInteger(e.elapsed_seconds)&&e.elapsed_seconds>=0?fe(!0):Z(`${t}.elapsed_seconds`,"Expected nonnegative provider elapsed seconds"):n}case"message_reported":{const n=it(e,"native progress message",["kind","message"],t);return n.success?typeof e.message=="string"?fe(!0):Z(`${t}.message`,"Expected native progress message string"):n}default:return Z(`${t}.kind`,"Expected typed native progress kind")}}function Mu(e,t){if(["KEEPER_CONNECTED","KEEPER_STREAM_PING"].includes(e))return t===null?fe(!0):Z("ag_ui_event.value",`Expected null ${e} payload`);if(e==="KEEPER_STREAM_MESSAGE_STOP"&&t===null||e==="KEEPER_RUNTIME_ATTEMPT_STARTED"&&t===null)return fe(!0);if(e==="KEEPER_EXTERNAL_EFFECT_COMPLETED"){const s=it(t,e,["target"]);if(!s.success)return s;const a=s.data.target;if(!ve(a))return Z("ag_ui_event.value.target",`Expected ${e} target object`);const _=it(a,e,["kind","channel_id","thread_ts"]);if(!_.success)return _;const f=a.kind;return f==="dashboard"?fe(!0):f!=="discord"&&f!=="slack"?Z("ag_ui_event.value.target.kind",`Unknown ${e} target kind`):Ee(_.data,"channel_id")}const r=it(t,e,{KEEPER_CONNECTED:[],KEEPER_RUNTIME_ATTEMPT_STARTED:["runtime_id","attempt_index"],KEEPER_PROVIDER_RETRY:["attempt","retry"],KEEPER_STREAM_MESSAGE_STOP:["content_generation","stream_scope"],KEEPER_STREAM_PING:[],KEEPER_EXTERNAL_EFFECT_COMPLETED:["target"],KEEPER_CHAT_OPERATION_ACCEPTED:["operation_id","state","queued_count","interactive"],KEEPER_CHAT_BATCH_BOUND:["operation_id","execution_id"],KEEPER_TOOL_APPROVAL_REQUESTED:["approval_id","tool_call_id","tool_call_name","args","question","because"],KEEPER_TOOL_APPROVAL_SETTLED:["approval_id","tool_call_id","outcome"],KEEPER_STREAM_MESSAGE_START:["content_generation","stream_scope","provider_message_id","model","usage"],KEEPER_STREAM_MESSAGE_DELTA:["content_generation","stream_scope","stop_reason","usage"],KEEPER_CONTENT_BLOCK_START:["index","content_type","tool_call_id","tool_call_name"],KEEPER_CONTENT_BLOCK_STOP:["index"],KEEPER_NATIVE_TOOL_START:["toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","toolCallName"],KEEPER_NATIVE_TOOL_END:["toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","toolCallName","completion"],KEEPER_NATIVE_TOOL_PROGRESS:["toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","toolCallName","progress"],KEEPER_MODEL_CONTENT_ACTIVITY:["generation","stream_scope","block_index","provider_message_id","channel","state"],KEEPER_THINKING_DELTA:["index","delta","response"],KEEPER_THINKING_SNAPSHOT:["index","snapshot","response"],KEEPER_THINKING_SIGNATURE_DELTA:["index","signature_bytes"],KEEPER_ATTACHMENT:["attachment_id","id","sha256","url","mime_type","kind","bytes","width","height","filename","origin","created_at_unix","retention","caption","block_index","tool_call_id","role","response"],KEEPER_MEDIA_DELTA:["index","media_type","source_type","media_ref","response"],KEEPER_STREAM_PROTOCOL_ERROR:["kind","index","tool_call_id","event_type","reason","raw_bytes","quarantined_occurrence"],KEEPER_CONTINUATION_CHECKPOINT:["message","request_id"],KEEPER_REPLY_DETAILS:["reply","turn_outcome","turn_ref","terminal_stream_scope"],KEEPER_TOOL_TRANSCRIPT_COMMITTED:["deliveryKey","executionId","ordinal"],KEEPER_TOOL_CALL_ADMITTED:["toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","providerToolName","toolCallName"],KEEPER_TOOL_RESULT_READY:["toolStreamScope","toolCallBlockIndex","providerMessageId","toolCallId","executionId","isError"]}[e]);if(!r.success)return r;const o=r.data;switch(e){case"KEEPER_NATIVE_TOOL_START":return Ro(o);case"KEEPER_NATIVE_TOOL_END":{const s=Ro(o);return s.success?Object.prototype.hasOwnProperty.call(o,"completion")?Ku(o.completion):fe(!0):s}case"KEEPER_NATIVE_TOOL_PROGRESS":{const s=Ro(o);return s.success?Nu(o.progress):s}case"KEEPER_STREAM_MESSAGE_START":{if(o.content_generation!==void 0){const f=Oe(o,"content_generation");if(!f.success)return f}const s=Oe(o,"stream_scope");if(!s.success)return s;const a=Ee(o,"provider_message_id",!0);if(!a.success)return a;const _=Ee(o,"model",!0);return _.success?o.usage===void 0?fe(!0):wu(o.usage):_}case"KEEPER_STREAM_MESSAGE_DELTA":{if(o.content_generation!==void 0){const _=Oe(o,"content_generation",0);if(!_.success)return _}const s=Oe(o,"stream_scope");if(!s.success)return s;const a=Sn(o,"stop_reason");return a.success?o.usage===void 0?fe(!0):Pu(o.usage):a}case"KEEPER_CONTENT_BLOCK_START":{const s=Oe(o,"index");if(!s.success)return s;const a=Ee(o,"content_type");if(!a.success)return a;const _=Sn(o,"tool_call_id");return _.success?Sn(o,"tool_call_name"):_}case"KEEPER_CONTENT_BLOCK_STOP":return Oe(o,"index");case"KEEPER_MODEL_CONTENT_ACTIVITY":{for(const s of["generation","stream_scope","block_index"]){const a=Oe(o,s);if(!a.success)return a}if(Object.prototype.hasOwnProperty.call(o,"provider_message_id")){const s=Ee(o,"provider_message_id");if(!s.success)return s}return o.channel!=="text"&&o.channel!=="thinking"?Z("ag_ui_event.value.channel","Expected text or thinking content channel"):o.state==="observed"||o.state==="ended"?fe(!0):Z("ag_ui_event.value.state","Expected observed or ended content state")}case"KEEPER_TOOL_TRANSCRIPT_COMMITTED":{if(Ma(o.deliveryKey,{kind:"terminal_result"}).status!=="valid")return Z("ag_ui_event.value.deliveryKey","Expected exact tool delivery identity");const a=Ee(o,"executionId");return a.success?Oe(o,"ordinal"):a}case"KEEPER_TOOL_CALL_ADMITTED":{const s=_n(o,"ag_ui_event.value");if(!s.success)return s;const a=Ee(o,"providerToolName");return a.success?Ee(o,"toolCallName"):a}case"KEEPER_TOOL_RESULT_READY":{const s=_n(o,"ag_ui_event.value");if(!s.success)return s;const a=Ee(o,"executionId");return a.success?o.isError!==void 0&&typeof o.isError!="boolean"?Z("ag_ui_event.value.isError","Expected boolean"):fe(!0):a}case"KEEPER_TOOL_APPROVAL_REQUESTED":{const s=Ee(o,"approval_id");if(!s.success)return s;const a=Ee(o,"tool_call_id");if(!a.success)return a;const _=Ee(o,"tool_call_name");if(!_.success)return _;const f=Ee(o,"args");if(!f.success)return f;const c=Ee(o,"question");return c.success?Iu(o,"because"):c}case"KEEPER_TOOL_APPROVAL_SETTLED":{const s=Ee(o,"approval_id");if(!s.success)return s;const a=Ee(o,"tool_call_id");return a.success?Ee(o,"outcome"):a}case"KEEPER_CHAT_BATCH_BOUND":{const s=Ee(o,"operation_id");return s.success?Ee(o,"execution_id"):s}case"KEEPER_CHAT_OPERATION_ACCEPTED":{const s=Ee(o,"operation_id");if(!s.success)return s;const a=Ee(o,"state");if(!a.success)return a;const _=Oe(o,"queued_count");if(!_.success||o.interactive===void 0)return _;const f=it(o.interactive,"interactive",["outcome","chat_control_token","signalled","resumed","interrupt_error","interrupt_error_code","interrupt_incident_id"]);if(!f.success)return f;const c=Ee(f.data,"chat_control_token");if(!c.success)return c;const{outcome:k,signalled:b,resumed:l,interrupt_error:g,interrupt_error_code:v,interrupt_incident_id:E}=f.data;if(k!=="applied"&&k!=="stale_control"&&k!=="paused"&&k!=="replayed")return Z("ag_ui_event.value.interactive.outcome","Unknown interactive admission outcome");if(typeof b!="boolean"||typeof l!="boolean"||g!==null&&typeof g!="string")return Z("ag_ui_event.value.interactive","Invalid interactive control receipt");if(k!=="applied"&&(b||l||g!==null))return Z("ag_ui_event.value.interactive","Inactive admission cannot report control effects");if(g===null){if(v!==null||E!==null)return Z("ag_ui_event.value.interactive","Successful control cannot report an error incident")}else if(v!=="interrupt_failed"||E!==o.operation_id)return Z("ag_ui_event.value.interactive","Interrupt failure requires its code and incident identity");return fe(!0)}case"KEEPER_CONNECTED":case"KEEPER_STREAM_MESSAGE_STOP":{const s=Oe(o,"content_generation",0);return s.success?Oe(o,"stream_scope",0):s}case"KEEPER_STREAM_PING":return fe(!0);case"KEEPER_PROVIDER_RETRY":{const s=it(o.attempt,"attempt",["routing_run_id","runtime_id","lane_attempt_index"]);if(!s.success)return s;for(const c of["routing_run_id","runtime_id"]){const k=Ee(s.data,c);if(!k.success)return k}const a=Oe(s.data,"lane_attempt_index",0);if(!a.success)return a;const _=it(o.retry,"retry",["observation_id","attempt","max_retries","retry_delay_ms","error_status"]);if(!_.success)return _;const f=Ee(_.data,"observation_id");if(!f.success)return f;for(const c of["attempt","max_retries","retry_delay_ms"]){const k=Oe(_.data,c,0);if(!k.success)return k}return _.data.error_status===null?fe(!0):Oe(_.data,"error_status",0)}case"KEEPER_RUNTIME_ATTEMPT_STARTED":{const s=Sn(o,"runtime_id");return s.success?o.attempt_index===void 0?fe(!0):Oe(o,"attempt_index",0):s}case"KEEPER_THINKING_SNAPSHOT":{const s=Rr(o.response);if(!s.success)return s;const a=Oe(o,"index");return a.success?Ee(o,"snapshot",!0):a}case"KEEPER_THINKING_DELTA":{if(o.response!==void 0){const a=Rr(o.response);if(!a.success)return a}const s=Oe(o,"index");return s.success?Ee(o,"delta",!0):s}case"KEEPER_THINKING_SIGNATURE_DELTA":{const s=Oe(o,"index");return s.success?Oe(o,"signature_bytes"):s}case"KEEPER_ATTACHMENT":{if(o.response!==void 0){const s=Rr(o.response);if(!s.success)return s}for(const s of["attachment_id","url","mime_type"]){const a=Ee(o,s);if(!a.success)return a}if(o.created_at_unix!==void 0&&(typeof o.created_at_unix!="number"||!Number.isFinite(o.created_at_unix)||o.created_at_unix<0))return Z("ag_ui_event.value.created_at_unix","Expected non-negative finite created_at_unix");if(o.retention!==void 0){const s=Ee(o,"retention");if(!s.success)return s}return o.kind==="image"||o.kind==="audio"||o.kind==="document"?fe(!0):Z("ag_ui_event.value.kind","Expected typed attachment kind")}case"KEEPER_MEDIA_DELTA":{const s=Rr(o.response);if(!s.success)return s;const a=Oe(o,"index");if(!a.success)return a;for(const _ of["media_type","media_ref"]){const f=Ee(o,_);if(!f.success)return f}return o.source_type==="base64"||o.source_type==="url"||o.source_type==="file_id"?fe(!0):Z("ag_ui_event.value.source_type","Expected typed media source")}case"KEEPER_STREAM_PROTOCOL_ERROR":{if(typeof o.kind!="string"||!Au.has(o.kind))return Z("ag_ui_event.value.kind","Expected typed stream protocol error kind");for(const s of["tool_call_id","event_type","reason"]){const a=Sn(o,s);if(!a.success)return a}if(o.index!==void 0){const s=Oe(o,"index");if(!s.success)return s}if(o.raw_bytes!==void 0){const s=Oe(o,"raw_bytes");if(!s.success)return s}return o.quarantined_occurrence===void 0?fe(!0):Ou(o.quarantined_occurrence)}case"KEEPER_CONTINUATION_CHECKPOINT":{const s=Ee(o,"message",!0);return s.success?Sn(o,"request_id"):s}case"KEEPER_REPLY_DETAILS":{if(typeof o.reply!="string")return Z("ag_ui_event.value.reply","Expected reply string");const s=Ee(o,"turn_ref");if(!s.success)return s;if(!(typeof o.turn_outcome=="string"&&Cu.has(o.turn_outcome)))return Z("ag_ui_event.value.turn_outcome","Expected typed Keeper turn outcome");const _=o.terminal_stream_scope;return _===void 0||typeof _=="number"&&Number.isSafeInteger(_)&&_>=0?fe(!0):Z("ag_ui_event.value.terminal_stream_scope","Expected terminal_stream_scope integer >= 0")}}return Z("ag_ui_event.name",`No payload contract for ${String(e)}`)}function Lu(e,t={}){if(typeof e.type!="string"||!Su.has(e.type))return Z("ag_ui_event.type","Expected a supported AG-UI event type");const n=Ru.get(e.type),r=Object.keys(e).find(o=>!n?.has(o));if(r)return Z(`ag_ui_event.${r}`,`Unexpected ${e.type} event field`);if(typeof e.threadId!="string"||e.threadId.trim()==="")return Z("ag_ui_event.threadId","Expected non-empty AG-UI threadId");if(typeof e.timestamp!="number"||!Number.isFinite(e.timestamp))return Z("ag_ui_event.timestamp","Expected finite AG-UI timestamp");for(const o of["runId","messageId","delta","providerMessageId","toolCallId","toolCallName","message","code","name"])if(e[o]!=null&&typeof e[o]!="string")return Z(`ag_ui_event.${o}`,`Expected AG-UI ${o} to be a string`);switch(e.type){case"RUN_STARTED":case"RUN_FINISHED":return typeof e.runId=="string"&&e.runId.trim()!==""?fe(!0):Z("ag_ui_event.runId","Expected non-empty AG-UI runId");case"RUN_ERROR":return typeof e.message=="string"&&e.message.trim()!==""?fe(!0):Z("ag_ui_event.message","Expected non-empty AG-UI error message");case"TEXT_MESSAGE_START":return typeof e.messageId!="string"||e.messageId.trim()===""?Z("ag_ui_event.messageId","Expected non-empty AG-UI messageId"):e.role==="assistant"||e.role==="user"?fe(!0):Z("ag_ui_event.role","Expected assistant or user AG-UI role");case"TEXT_MESSAGE_CONTENT":if("textResponse"in e){if("textStreamScope"in e)return Z("ag_ui_event.textResponse","Conflicting text ownership fields");const o=it(e.textResponse,"textResponse",["content_generation","stream_scope"]);if(!o.success)return o;const i=Oe(o.data,"content_generation",0);if(!i.success)return i;const s=Oe(o.data,"stream_scope",0);if(!s.success)return s}return"textStreamScope"in e&&(typeof e.textStreamScope!="number"||!Number.isSafeInteger(e.textStreamScope)||e.textStreamScope<0)?Z("ag_ui_event.textStreamScope","Expected textStreamScope non-negative integer"):typeof e.delta=="string"?fe(!0):Z("ag_ui_event.delta","Expected AG-UI text delta");case"TEXT_MESSAGE_END":return typeof e.messageId=="string"&&e.messageId.trim()!==""?fe(!0):Z("ag_ui_event.messageId","Expected non-empty AG-UI messageId");case"TOOL_CALL_START":{const o=_n(e,"ag_ui_event");if(!o.success)return o}return typeof e.toolCallName=="string"&&e.toolCallName.trim()!==""?fe(!0):Z("ag_ui_event.toolCallName","Expected non-empty AG-UI toolCallName");case"TOOL_CALL_ARGS":{const o=_n(e,"ag_ui_event");if(!o.success)return o}return typeof e.delta=="string"||typeof e.snapshot=="string"?fe(!0):Z("ag_ui_event","Expected AG-UI tool args delta or snapshot");case"TOOL_CALL_END":return _n(e,"ag_ui_event");case"CUSTOM":return t.tolerateUnknownCustomName&&typeof e.name=="string"&&e.name.trim()!==""&&!oa(e.name)?fe(!0):typeof e.name!="string"||!oa(e.name)?Z("ag_ui_event.name","Expected a supported Keeper custom event name"):Object.prototype.hasOwnProperty.call(e,"value")?Mu(e.name,e.value):Z("ag_ui_event.value","Expected Keeper custom event value")}return Z("ag_ui_event.type","Expected a supported AG-UI event type")}function Du(e){return{parse(t){const n=e(t);if(n.success)return n.data;throw new Error(n.error.issues.map(r=>r.message).join("; "))},safeParse:e}}const Uu=Du(e=>{if(!ve(e))return Z("ag_ui_event","Expected an AG-UI event object");const t=Lu(e,{tolerateUnknownCustomName:!0});return t.success?fe(e):t});function b_(e,t=!1){if(t)return"bad";const n={};e.disposition!==void 0&&(n.disposition=e.disposition),e.wire_outcome!==void 0&&(n.wire_outcome=e.wire_outcome);const r=Dc(n);return r==="failed"||r==="malformed"?"bad":r==="deferred"||r==="unsettled"?"warn":"ok"}function x(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function d(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}function C(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function y_(e){return ul(e)}function ps(e){return typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?Us(Math.max(0,Math.min(100,Math.round(e.context_ratio*100)))):e.context_provenance==="estimated"&&typeof e.estimated_context_ratio=="number"&&Number.isFinite(e.estimated_context_ratio)?Us(Math.max(0,Math.min(100,Math.round(e.estimated_context_ratio*100)))):e.context_unavailable_reason?Bo(e.context_unavailable_reason):Bo()}function Ja(e){if(e.kind!=="value")return;const t=wa(e.data);return t==="absent"?void 0:t}function Ur(e){if(typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)){const n=Math.max(0,Math.min(100,Math.round(e.context_ratio*100))),r=e.context_tokens!=null&&e.context_max!=null?`${e.context_tokens.toLocaleString("en-US")} / ${e.context_max.toLocaleString("en-US")} tok`:`측정됨 (${n}%)`;return{label:`${n}%`,tooltip:r,estimated:!1}}if(e.context_provenance==="estimated"&&typeof e.estimated_context_ratio=="number"&&Number.isFinite(e.estimated_context_ratio)){const n=Math.max(0,Math.min(100,Math.round(e.estimated_context_ratio*100)));return{label:`~${n}%`,tooltip:`추정 컨텍스트 비율 (~${n}%)${e.context_unavailable_reason?` · ${e.context_unavailable_reason}`:""}`,estimated:!0}}const t=e.context_unavailable_reason;return{label:"없음",tooltip:t?`컨텍스트 미측정 (${t})`:"컨텍스트 미측정",estimated:!1}}function jr(e){if(e.runtime_path_rest?.status!=="resting"||e.paused||!e.keepalive_running)return!1;const t=e.health.toLowerCase(),n=e.phase.toLowerCase();return t!=="offline"&&n!=="offline"&&n!=="stopped"&&n!=="paused"}function $_(e,t=256,n,r){const o=new URLSearchParams({size:String(t)}),i=typeof n=="string"?n.trim():"";return i.length>0&&o.set("preview",i),r&&o.set("expected_equipment",JSON.stringify({face:r.face,neck:r.neck,head:r.head,hand:r.hand,base:r.base})),`/api/v1/keepers/${encodeURIComponent(e)}/portrait.png?${o.toString()}`}function Bu(e){return ll(e)}function qu(e){return cl(e)}function Xa(e){if(!x(e)||typeof e.status_text!="string")return null;const t=d(e.activity),n=C(e.updated_at_unix);if(!t||n===null)return null;const r=e.status_text,o=typeof e.text_tail=="string"?e.text_tail:"",i=d(e.last_tool),s=C(e.revision);return{status_text:r,activity:t,open_activities:fu(e.open_activities),preparation:Sl(e.preparation),work_context:Tl(e.work_context),text_tail:o,last_tool:i,last_failure:d(e.last_failure),updated_at_unix:n,revision:s!==null&&Number.isInteger(s)&&s>=1?s:null}}function Fu(e){const t=new Map,n=x(e)&&Array.isArray(e.keepers)?e.keepers:Array.isArray(e)?e:[],r=x(e)?xl(e.waiting_errors):null;for(const o of n){if(!x(o))continue;const i=d(o.keeper_name)??d(o.name);if(!i)continue;const s="active_turn"in o?o.active_turn:o.turn,a=o.status==="ok"&&(s===null||x(s))?"ok":"unavailable",_=a==="ok"&&x(s)?s:null,f=_?Xa(_.preview):null,c=_?{lane:d(_.lane)??"chat",turn_ref:d(_.turn_ref),owner_key:d(_.owner_key),preview_observed_through:C(_.preview_observed_through),started_at_unix:C(_.started_at_unix)??C(_.started_at)??0,preview:f}:null,k=r??Rl(o.waiting);t.set(i,{keeper_name:i,status:a,chat_control_token:a==="ok"?d(o.chat_control_token):null,active:c,waiting:k})}return t}function Hu(e){const t=x(e)&&Array.isArray(e.keepers)?e.keepers:[],n=[];for(const r of t){if(!x(r))continue;const o=d(r.name);if(!o)continue;const i=x(r.meta)?r.meta:null,s=x(r.effective_meta_error)?d(r.effective_meta_error.message):null,a=x(r.last_failure)&&d(r.last_failure.cause)?{cause:d(r.last_failure.cause),at_unix:C(r.last_failure.at_unix)}:null,_=El(r.recent_turns),f=_===null?null:_.ok+_.rested+_.failed;let c=null;x(r.portrait)&&r.portrait.state==="ready"&&Bl(r.portrait.equipment)&&(c=r.portrait.equipment);const k=typeof r.candle_balance_milli=="string"||typeof r.candle_balance_milli=="number"?r.candle_balance_milli:null,b=d(r.context_provenance),l=b==="measured"||b==="estimated"||b==="unavailable"?b:null,g=Bu(r.runtime_path_rest),v=qu(r.runtime_lane_observation);n.push({name:o,status:d(r.status)??"unknown",phase:d(r.phase)??(s?"error":"idle"),health:d(r.health)??(s?"failing":"unknown"),paused:r.paused===!0,keepalive_running:r.keepalive_running===!0,activation_mode:d(r.activation_mode)??"manual",runtime_id:d(r.runtime_id)??"unassigned",sandbox_profile:i?d(i.sandbox_profile):null,company:d(r.group)??"General",context_ratio:C(r.context_ratio),context_tokens:C(r.context_tokens),context_max:C(r.context_max),context_provenance:l,estimated_context_ratio:C(r.estimated_context_ratio),context_unavailable_reason:d(r.context_metrics_unavailable_reason),runtime_blocker_summary:d(r.runtime_blocker_summary),runtime_blocker_signature:d(r.runtime_blocker_signature),runtime_blocker_class:d(r.runtime_blocker_class),runtime_path_rest:g,operator_disposition:d(r.operator_disposition),operator_disposition_reason:d(r.operator_disposition_reason),failing_since:C(r.failing_since),next_action:d(r.next_action),runtime_lane_failures:v,last_failure:a,directory_issue:s,turns_24h:f,turns_24h_breakdown:_,candle_balance_milli:k,portrait_equipment:c,chat_control_token:null,waiting_summary:null,active_turn:null})}return n}function Gr(e){return il(e)}function ju(e,t,n){const r=n.trim().toLowerCase(),o=r.length===0?[...e]:e.filter(i=>i.name.toLowerCase().includes(r)||i.company.toLowerCase().includes(r)||i.runtime_id.toLowerCase().includes(r)||i.health.toLowerCase().includes(r)||(i.runtime_blocker_summary?.toLowerCase().includes(r)??!1));if(t==="attention"){const i=o.map(s=>{const a=Gr(s)?0:jr(s)?1:s.paused?2:3,_=s.context_ratio!==null?s.context_ratio:s.context_provenance==="estimated"&&s.estimated_context_ratio!=null?s.estimated_context_ratio:-1;return{item:s,score:a,ctx:_}});return i.sort((s,a)=>s.score!==a.score?s.score-a.score:a.ctx-s.ctx||s.item.name.localeCompare(a.item.name)),i.map(s=>s.item)}return t==="wall24h"?o.sort((i,s)=>{const a=(s.turns_24h??-1)-(i.turns_24h??-1);return a!==0?a:i.name.localeCompare(s.name)}):o.sort((i,s)=>{const a=i.company.localeCompare(s.company);return a!==0?a:i.name.localeCompare(s.name)})}const Gu=["keeper","keeper_roster_changed","keeper_row_changed","keeper_turn_changed","keeper_turn_complete","keeper_waiting_inventory_changed","provider_standing","keeper_turn","keeper_lifecycle"],Yo="keepers:roster",_s="keepers:turns";function Za(e){return qt.fetch(_s,t=>we("/api/v1/keepers/turns",{signal:t,decode:Fu}),{ttlMs:1e4,topics:["keeper","keeper_turn","keeper_lifecycle","keeper_turn_changed"],reason:e})}function Wu(){return{roster:qt.observe(Yo).value,turns:qt.observe(_s).value}}async function Vu(e="mount"){e==="sse"&&(qt.invalidateKey(Yo),qt.invalidateKey(_s)),await Promise.all([qt.fetch(Yo,t=>we("/api/v1/gate/keepers?detailed=true",{signal:t,decode:Hu}),{ttlMs:1e4,topics:["keeper","keeper_turn","keeper_lifecycle","keeper_row_changed","keeper_roster_changed"],reason:e}),Za(e)])}async function zu(e){const t=await Za("manual");return t.kind==="value"?t.data.get(e)?.chat_control_token??null:null}function Qu(e){const t={};if(x(e)&&Array.isArray(e.overrides))for(const n of e.overrides){if(!x(n))continue;const r=d(n.keeper)??d(n.name),o=d(n.mode);r&&o&&(t[r]=o)}return{defaultMode:(x(e)?d(e.default):null)??"auto",overrides:t,restoreError:x(e)?d(e.restore_error):null}}async function Ao(e="mount"){return _e.peek().kind!=="single_user_local"?Bo("multi_account_unsupported"):qt.fetch("keepers:tool-approval-modes",t=>we("/api/v1/keepers/tool-approval-mode",{signal:t,decode:Qu}),{ttlMs:15e3,topics:["keeper_tool_approval_mode_changed","keeper_tool_approval_waits_changed","tool_approval"],reason:e})}function Yu(e){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/boot`,{})}function Ju(e){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/directive`,{action:"pause"})}function Xu(e){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/directive`,{action:"resume",operator_operation_id:`dashboard-resume-${Cn()}`})}function Co(e,t){return He("POST","/api/v1/keepers/turn/interrupt",{name:e})}function Zu(e){return He("POST","/api/v1/dashboard/agents/purge",{agent_name:e})}function E_(e,t,n=!0){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/clear`,{reason:t,preserve_system_prompt:n})}function T_(e){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/reset`,{})}function Rn(e){if(e!=null)return typeof e=="string"?e:JSON.stringify(e,null,2)}function Jo(e){if(e)return e==="ok"?"completed":e==="err"?"error":e==="pending"?"running":e}function ei(e){if(!Array.isArray(e))return[];const t=[];for(const n of e){const r=Hr(n);r&&t.push(r)}return t}function ed(e){if(!Array.isArray(e))return{thinking:[],redactedThinking:!1,toolCalls:[],attachments:[]};const t=[];let n=!1;const r=[],o=[];for(const i of e){if(!x(i))continue;const s=d(i.t);if(s==="thinking")i.redacted===!0?n=!0:typeof i.content=="string"&&i.content.trim()&&t.push(i.content.trim());else if(s==="attachment"||s==="image"){const a=Hr(i);a&&o.push(a)}else if(s==="trace"&&Array.isArray(i.trace))for(const a of i.trace){if(!x(a))continue;const _=d(a.kind);if(_==="think")a.content_withheld===!0?n=!0:typeof a.text=="string"&&a.text.trim()&&t.push(a.text.trim());else if(_==="reason"){const f=typeof a.text=="string"?a.text.trim():"",c=typeof a.detail=="string"?a.detail.trim():"",k=[f,c].filter(Boolean).join(`
`);k&&t.push(k)}else if(_==="tool"){const f=d(a.name)??"tool",c=ei(a.attachments);c.length>0&&o.push(...c),r.push({id:d(a.tool_call_id)??void 0,executionId:d(a.execution_id)??void 0,name:f,args:Rn(a.args),result:Rn(a.result),status:Jo(d(a.status)),duration:d(a.dur)??void 0,...c.length>0?{attachments:c}:{}})}}}return{thinking:t,redactedThinking:n,toolCalls:r,attachments:o}}function td(e){const t=[];if(Array.isArray(e.tool_calls))for(const n of e.tool_calls){if(!x(n))continue;const r=d(n.name)??d(n.tool_name)??d(n.tool)??"tool",o=n.args??n.input??n.arguments,i=n.result??n.output;t.push({id:d(n.id)??d(n.tool_call_id)??void 0,executionId:d(n.execution_id)??void 0,name:r,args:Rn(o),result:Rn(i),status:Jo(d(n.status)??d(n.outcome)),duration:d(n.dur)??void 0})}else{const n=d(e.tool_call_name)??d(e.tool_name);if(n&&(e.tool_input!==void 0||e.tool_output!==void 0||e.tool_result!==void 0)){const r=e.tool_input??e.args,o=e.tool_output??e.tool_result??e.output;t.push({id:d(e.tool_call_id)??void 0,executionId:d(e.execution_id)??void 0,name:n,args:Rn(r),result:Rn(o),status:Jo(d(e.status))})}}return t.length>0?t:void 0}function nd(e){const t=d(e);if(t)return t;if(!x(e))return null;const n=d(e.kind);if(!n)return null;if(n==="gate")return d(e.label)??"gate";if(n==="slack"||n==="discord"){const r=d(e.channel_name);return r?`${n} #${r}`:n}if(n==="webhook"){const r=d(e.source);return r?`webhook:${r}`:"webhook"}return n}function rd(e){if(!x(e))return null;const t=d(e.id);if(!t)return null;const n=d(e.role),r=n==="user"||n==="assistant"||n==="system"||n==="tool"||n==="request_failure"?n:"assistant",o=typeof e.content=="string"?e.content:"",i=Array.isArray(e.blocks)?e.blocks.flatMap(te=>x(te)&&te.t==="image"&&Ka(te.src)?[{path:te.src,caption:d(te.cap)??void 0,workspaceEpoch:Te()}]:[]):[],s=C(e.ts)??Date.now()/1e3,a=ed(e.blocks),_=ei(e.attachments),f=Ot([..._,...a.attachments]),c=d(e.thinking)??d(e.reasoning)??d(e.reasoning_content)??void 0,k=[];c&&k.push(c);for(const te of a.thinking)k.includes(te)||k.push(te);const b=k.length>0?k.join(`

`):a.redactedThinking?"[추론 내용 비공개 (redacted)]":void 0,g=[...td(e)??[]];if(a.toolCalls.length>0){const te=new Set,se=new Set;for(let ue=0;ue<g.length;ue++){const Y=g[ue];Y.executionId&&te.add(Y.executionId),Y.id&&se.add(`${Y.id}\0${Y.name}`)}for(let ue=0;ue<a.toolCalls.length;ue++){const Y=a.toolCalls[ue],de=Y.id?`${Y.id}\0${Y.name}`:null;Y.executionId&&te.has(Y.executionId)||de!==null&&se.has(de)||(g.push(Y),Y.executionId&&te.add(Y.executionId),de!==null&&se.add(de))}}const v=g.length>0?g:void 0,E=e.autonomous===!0||x(e.autonomous_turn)||d(e.source)==="autonomous"||d(e.turn_kind)==="autonomous"||x(e.metadata)&&(e.metadata.autonomous===!0||d(e.metadata.turn_kind)==="autonomous"),I=Array.isArray(e.memory_recall)?e.memory_recall:Array.isArray(e.recalled_facts)?e.recalled_facts:null,S=I?I.map(te=>typeof te=="string"?te.trim():x(te)&&typeof te.claim=="string"?te.claim.trim():JSON.stringify(te)).filter(Boolean):void 0,M=d(e.kind),w=M==="tool_call"||M==="tool_result"||M==="memory_recall"||M==="autonomous"||M==="system_internal"||M==="chat"?M:E?"autonomous":S&&S.length>0&&!o.trim()?"memory_recall":r==="tool"?"tool_result":void 0,D=d(e.speaker_authority)?.toLowerCase(),re=D==="owner"||D==="keeper"||D==="external"?D:null,W=d(e.speaker_name),z=d(e.speaker_id),ce=r==="user"?W??z??(re==="owner"?"Operator":void 0):void 0,xe=nd(e.surface);return{id:t,role:r,speakerLabel:ce,content:o,attachments:f.length>0?f:void 0,retainedImages:i.length>0?i:void 0,thinking:b,ts:s,deliveryProvenance:Ma(e.delivery_key,e.transcript_slot).value??void 0,turnRef:d(e.turn_ref)??void 0,executionId:d(e.execution_id)??void 0,toolName:d(e.tool_call_name)??d(e.tool_name)??void 0,kind:w,toolCalls:v,memoryItems:S&&S.length>0?S:void 0,autonomousTurn:E||void 0,deliveryState:"Delivered",speakerAuthority:re,speakerName:W,speakerId:z,surface:xe,discordReplyOrigin:r==="user"&&re==="external"?rc(e.surface,e.external_message_id):null}}function od(e,t){return we(`/api/v1/keepers/${encodeURIComponent(e)}/waiting-inventory`,{signal:t,decode:n=>{const r=x(n)&&x(n.data)?n.data:n;if(!x(r))return null;const o=Array.isArray(r.rows)?r.rows:[],i=[];for(const s of o){if(!x(s))continue;const a=d(s.source),_=d(s.waiting_on);!a||!_||i.push({keeper_name:d(s.keeper_name),source:a,waiting_on:_,what:typeof s.what=="string"?s.what:"",wake_producer:d(s.wake_producer)??"",since:C(s.since),due_at:C(s.due_at),next_action:typeof s.next_action=="string"?s.next_action:"",detail_lines:$l(s.detail)})}return{schema:d(r.schema)??"masc.keeper_waiting_inventory",keeper_count:C(r.keeper_count)??0,waiting_keeper_count:C(r.waiting_keeper_count)??0,row_count:C(r.row_count)??i.length,total_row_count:C(r.total_row_count)??i.length,oldest_age_seconds:C(r.oldest_age_seconds),rows:i}}})}function ti(e){return x(e)?x(e.params)?e.params:e:null}function ni(e){return d(e.keeper_name)??d(e.keeper)??d(e.name)??d(e.agent_name)}function sd(e,t){const n=ti(t),r=n?ni(n):null;if(r===null)return null;const o=ri(e,t,r);return o?.kind==="turn_preview"&&o.ownerKey!==null?{keeperName:r,ownerKey:o.ownerKey,preview:o.preview}:null}function ri(e,t,n){const r=ti(t),o=(r?d(r.type)??d(r.event_type)??d(r.event):null)??(e!=="message"?e:null);if(!o||(r?ni(r):null)!==n)return null;if(o==="keeper_waiting_inventory_changed")return{kind:"waiting_changed",queueChanged:r?.queue_kind==="chat_operation"};if(o==="keeper_chat_appended")return{kind:"chat_appended"};if(o==="keeper_chat_operation_event"&&r){const s=d(r.operation_id),a=x(r.ag_ui_event)?r.ag_ui_event:null;if(!s||!a||!d(a.type))return null;const _=r.seq;return _!=null&&(typeof _!="number"||!Number.isSafeInteger(_)||_<0)?null:{kind:"chat_operation_event",operationId:s,seq:typeof _=="number"?_:null,agUiEvent:a}}if(o==="keeper_turn_succeeded"&&r){const s=C(r.elapsed_ms),a=C(r.ts_unix);return s===null||!Number.isInteger(s)||s<0||a===null||a<=0||!Number.isFinite(new Date(a*1e3).getTime())?null:{kind:"turn_succeeded",elapsedMs:s,atUnix:a}}if(o==="keeper_turn_changed")return{kind:"turn_changed"};if(o==="keeper_turn_preview_changed"&&r){const s=x(r.observation)?r.observation:null,a=(s&&x(s.preview)?s.preview:null)??(x(r.preview)?r.preview:null),_=Xa(a);return _?{kind:"turn_preview",ownerKey:(s?d(s.owner_key):null)??d(r.owner_key),preview:_}:null}return null}function oi(e,t,n=16384,r,o){const i=new URLSearchParams({execution_id:t,max_bytes:String(n)});return o?.offset!==void 0&&Number.isFinite(o.offset)&&o.offset>=0&&i.set("offset",String(Math.trunc(o.offset))),o?.sourceId&&o.sourceId.trim().length>0&&i.set("source_id",o.sourceId.trim()),we(`/api/v1/keepers/${encodeURIComponent(e)}/tool-result?${i.toString()}`,{signal:r,decode:s=>{const a=x(s)&&x(s.data)?s.data:s;if(!x(a))throw new Error("Invalid tool-result payload");const _=d(a.state),f=d(a.execution_id)??t;if(_==="pending")return{state:"pending",executionId:f};if(_==="unavailable")return{state:"unavailable",executionId:f,reason:d(a.reason)??"unavailable"};if(_==="page"&&x(a.page)){if(a.page.ok===!1)return{state:"unavailable",executionId:f,reason:d(a.page.error)??"page_read_failed"};const c=typeof a.page.content=="string"?a.page.content:"",k=d(a.page.encoding)??"utf-8",b=C(a.recorded_bytes)??c.length,l=C(a.page.offset)??0,g=C(a.page.total_bytes)??b,v=C(a.page.next_offset)??l+c.length,E=d(a.source_id)??void 0,I=d(a.body_sha256)??d(a.page.sha256)??void 0,S=k==="base64"?`[binary/base64 · ${b.toLocaleString("en-US")}B]`:c;return{state:"page",executionId:f,sourceId:E,bodySha256:I,offset:l,nextOffset:v,encoding:k,content:S,isError:a.is_error===!0,recordedBytes:b,totalBytes:g,eof:a.page.eof!==!1}}throw new Error(`Unknown tool-result state: ${String(_)}`)}})}function aa(e,t,n=40,r){const o=new URLSearchParams({limit:String(n)});return t&&o.set("cursor",t),we(`/api/v1/keepers/${encodeURIComponent(e)}/chat/history/page?${o.toString()}`,{signal:r,decode:i=>{if(!x(i)||!Array.isArray(i.messages))throw new Error("Invalid chat history page");const s=i.messages.map(rd).filter(_=>_!==null);return{messages:Dr(s),hasMore:i.has_more===!0,nextCursor:typeof i.next_cursor=="string"&&i.next_cursor.trim()?i.next_cursor:null}}})}function ad(e){if(!x(e)||e.schema!=="masc.keeper_chat_operation.v1"||e.state!=="Queued")throw new Error("Expected a queued Keeper chat operation");const t=d(e.operation_id),n=d(e.sequence),r=C(e.created_at),o=e.input;if(!t||n===null||!/^\d+$/.test(n)||r===null||r<0||!x(o)||typeof o.message!="string")throw new Error("Queued Keeper chat operation has an invalid contract");return{operationId:t,sequence:n,createdAt:r,message:o.message,state:e.state}}function Io(e,t){const n=Te();return qc(r=>ie(n)?we(Uc(e,r),{signal:t,decode:o=>Bc(o,r,ad)}):Promise.resolve($t({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1})))}function id(e,t){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/chat/operations/${encodeURIComponent(t)}/cancel`,{})}function ld(e,t){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/chat/operations/${encodeURIComponent(t)}/move-to-end`,{})}function cd(e,t,n){const r=_e.peek();if(r.kind!=="single_user_local"||An("admin",r))return Promise.resolve($t({kind:"forbidden",status:null,code:"admin_only",message:"지금 실행(/api/v1/keepers/turn/run-next)은 관리자 전용입니다.",retryable:!1}));const o={name:e,request_id:t};return n&&(o.interrupt_token=n),He("POST","/api/v1/keepers/turn/run-next",o)}function dn(e){const t=x(e.response)?e.response:x(e.textResponse)?e.textResponse:null;if(t){const r=C(t.content_generation),o=C(t.stream_scope);if(r!==null&&o!==null)return{kind:"observed_response",contentGeneration:r,streamScope:o}}return{kind:"unobserved_scope",streamScope:C(e.stream_scope)??C(e.textStreamScope)}}function ud(e,t){if(!x(e)||!Array.isArray(e.events))throw new Error("Invalid chat journal page");const n=[];for(const a of e.events){if(!x(a))continue;const _=x(a.event)?a.event:a,f=d(_.type)??d(a.kind)??"";if(f==="RUN_STARTED"||f==="run_started")n.push({kind:"run_started"});else if(f==="batch_bound"){const c=d(_.execution_id);c&&d(_.operation_id)===t&&n.push({kind:"batch_bound",executionId:c})}else if(f==="agent_core_runtime_attempt_started"||f==="CUSTOM"&&d(_.name)==="KEEPER_RUNTIME_ATTEMPT_STARTED")n.push({kind:"runtime_attempt_started"});else if(f==="TEXT_MESSAGE_CONTENT"||f==="text_delta"){const c=typeof _.delta=="string"?_.delta:typeof _.text=="string"?_.text:"";n.push({kind:"text_delta",text:c,owner:dn(_)})}else f==="RUN_FINISHED"||f==="run_finished"?n.push({kind:"run_finished"}):f==="RUN_ERROR"||f==="error"||f==="event_error"?n.push({kind:"error",detail:d(_.message)??d(_.detail)??"stream error"}):n.push({kind:"other"})}const r=e.has_more===!0,o=C(e.next_since_seq),i=C(e.next_since_offset);return{operationId:t,events:n,next:r&&o!==null&&i!==null?{lastSeq:o,nextOffset:i}:null}}const Xo={admitted:null,closed:null,unobservedScope:null};function Zo(e,t){return e.contentGeneration!==t.contentGeneration?e.contentGeneration-t.contentGeneration:e.streamScope-t.streamScope}function si(e,t){if(t.kind==="unobserved_scope")return t.streamScope!=null?{accept:!0,ownership:{...e,unobservedScope:t.streamScope}}:{accept:!0,ownership:e};const n={contentGeneration:t.contentGeneration??0,streamScope:t.streamScope??0},r=e.closed!==null&&Zo(n,e.closed)<=0,o=e.admitted!==null&&(Zo(n,e.admitted)<0||n.contentGeneration===e.admitted.contentGeneration&&e.unobservedScope!==null&&n.streamScope<e.unobservedScope);return r||o?{accept:!1}:{accept:!0,ownership:{...e,admitted:n,unobservedScope:null}}}function ai(e){let t=e.closed;return e.admitted!==null&&(t===null||Zo(t,e.admitted)<0)&&(t=e.admitted),{admitted:null,closed:t,unobservedScope:null}}function dd(e){let t=[],n=Xo,r=null;for(const o of e)switch(o.kind){case"run_started":t=[],n=Xo;break;case"batch_bound":r=o.executionId;break;case"runtime_attempt_started":t=[],n=ai(n);break;case"text_delta":{const i=si(n,o.owner);i.accept&&(t.push(o.text),n=i.ownership);break}case"run_finished":return{text:t.join(""),finished:!0,error:null,executionId:r};case"error":return{text:t.join(""),finished:!1,error:o.detail,executionId:r}}return{text:t.join(""),finished:!1,error:null,executionId:r}}async function Oo(e,t){const n=_e.peek();if(!yt(n))return $t({kind:"forbidden",status:null,code:n.kind!=="single_user_local"?"single_user_only":"admin_only",message:n.kind!=="single_user_local"?"대화 저널 복구는 싱글유저 모드 전용입니다.":"대화 저널 복구(/chat/events)는 토큰 인증 관리자 전용입니다.",retryable:!1});const r=[];let o=null,i=0;for(;i<8;){i+=1;const s=new URLSearchParams({operation_id:t,limit:"2000"});o&&(s.set("since_seq",String(o.lastSeq)),s.set("since_offset",String(o.nextOffset)));const a=await we(`/api/v1/keepers/${encodeURIComponent(e)}/chat/events?${s.toString()}`,{decode:_=>ud(_,t)});if(!a.ok)return a;if(r.push(...a.value.events),!a.value.next)break;o=a.value.next}return qr({...dd(r),eventCount:r.length})}function ii(e){const t={request_id:e.operationId,name:e.keeper,message:e.message};if(e.mode.kind==="steer"?t.admission_intent={kind:"interactive",control_token:e.mode.controlToken,interrupt_token:null,operation_id:e.operationId}:e.mode.kind==="btw"&&(t.turn_instructions="Answer concisely as an ephemeral /btw side-query."),e.attachments&&e.attachments.length>0){const n=[];e.message.trim().length>0&&n.push({type:"text",text:e.message});for(const r of e.attachments)n.push({type:"attachment",attachment_id:r.attachment_id||r.id});t.user_blocks=n,t.attachments=e.attachments.map(bl)}return t}const pd=new Set(["KEEPER_RUNTIME_ATTEMPT_STARTED","KEEPER_PROVIDER_RETRY","KEEPER_STREAM_PROTOCOL_ERROR","KEEPER_CONTINUATION_CHECKPOINT"]);function _d(e){return[e.kind??"stream protocol error",e.event_type?`event=${e.event_type}`:"",e.reason??""].filter(t=>t.trim()!=="").join(" · ")}function fd(e,t,n){const r=Uu.safeParse(t);if(!r.success){e==="KEEPER_RUNTIME_ATTEMPT_STARTED"&&n.onAttemptStarted?.(null),n.onStreamProtocolError?.({message:`${e}: payload outside the stream contract`});return}const o=r.data;if(o.type==="CUSTOM")switch(o.name){case"KEEPER_RUNTIME_ATTEMPT_STARTED":n.onAttemptStarted?.({runtimeId:o.value?.runtime_id??null,attemptIndex:o.value?.attempt_index??null});return;case"KEEPER_PROVIDER_RETRY":n.onProviderRetry?.(o.value);return;case"KEEPER_STREAM_PROTOCOL_ERROR":{const i=o.value.quarantined_occurrence;n.onStreamProtocolError?.({message:_d(o.value),quarantinedStreamKey:i?`occ:${i.toolStreamScope}:${i.toolCallBlockIndex}`:void 0});return}case"KEEPER_CONTINUATION_CHECKPOINT":n.onContinuationCheckpoint?.(o.value.message??null);return;default:return}}function md(e){const t=d(e.interrupt_error);if(t){const n=d(e.interrupt_error_code);return n?`${t} (${n})`:t}switch(d(e.outcome)){case"stale_control":return"실행 중인 턴이 이미 바뀌어서 끼어들지 않았어요. 메시지는 접수돼 차례를 기다려요.";case"paused":return"지금은 턴을 새로 받지 않는 상태라 끼어들지 않았어요. 메시지는 접수됐어요.";default:return null}}function Ut(e){const t=C(e.toolStreamScope),n=C(e.toolCallBlockIndex);if(t!==null&&n!==null&&Number.isInteger(t)&&Number.isInteger(n))return`occ:${t}:${n}`}function wo(e){return e?`native:${e}`:void 0}function Po(e){return e?`native:${e}`:void 0}function ia(e){const t=C(e.index)??0,n=x(e.response)?e.response:null,r=n?C(n.content_generation)??0:0,o=n?C(n.stream_scope)??0:0;return`${r}:${o}:${t}`}function li(){const e={Accept:"text/event-stream","Content-Type":"application/json"};if(_e.peek().kind==="multi_account_signed_in"){const n=Ea();n&&(e["x-masc-csrf-token"]=n)}else{const n=Ta();n&&(e.Authorization=`Bearer ${n}`)}return e}async function gd(e){const t=e.fetchImpl??globalThis.fetch,n=Te();if(e.signal?.aborted)return{accepted:!1,rejected:!1,state:null,controlToken:null,error:"aborted"};const r=new AbortController,o=()=>r.abort(e.signal?.reason);e.signal?.addEventListener("abort",o,{once:!0});const i=Jt.subscribe(s=>{s!==n&&!r.signal.aborted&&r.abort("session_epoch_changed")});try{const s=await t(rs("/api/v1/keepers/chat/stream"),{method:"POST",credentials:"same-origin",headers:li(),body:JSON.stringify(ii(e)),signal:r.signal});if(!ie(n))return{accepted:!1,rejected:!1,state:null,controlToken:null,error:"session_epoch_changed"};if(!s.ok)return{accepted:!1,rejected:!0,state:null,controlToken:null,error:(await s.text().catch(()=>`HTTP ${s.status}`)).trim()||`HTTP ${s.status}`};if(!s.body)return{accepted:!1,rejected:!1,state:null,controlToken:null,error:"스트림 본문 없음"};const a=s.body.getReader(),_=new TextDecoder;let f="",c=null;const k=g=>{let v="";for(const S of g.split(/\r?\n/))S.startsWith("data:")&&(v+=(v?`
`:"")+S.slice(5).trim());if(!v)return;let E;try{const S=JSON.parse(v);if(!x(S))return;E=S}catch{return}const I=d(E.type);if(I==="RUN_ERROR"){c={accepted:!1,rejected:!0,state:null,controlToken:null,error:d(E.message)??"전송 오류"};return}if(I==="CUSTOM"&&d(E.name)==="KEEPER_CHAT_OPERATION_ACCEPTED"&&x(E.value)){const S=x(E.value.interactive)?E.value.interactive:null;c={accepted:!0,rejected:!1,state:d(E.value.state)??"Queued",controlToken:S?d(S.chat_control_token):null,error:null}}};let b=!1,l;try{for(;c===null;){const{done:g,value:v}=await a.read();if(g)break;if(!ie(n)||r.signal.aborted){b=r.signal.aborted,l=r.signal.reason;break}f+=_.decode(v,{stream:!0});const E=f.split(/\r?\n\r?\n/);f=E.pop()??"";for(const I of E)if(k(I),c!==null)break}c===null&&f.trim()&&ie(n)&&!r.signal.aborted&&k(f)}finally{try{await a.cancel()}catch{}a.releaseLock(),r.signal.aborted||r.abort("accepted_close")}return c!==null?c:ie(n)?b?{accepted:!1,rejected:!1,state:null,controlToken:null,error:l==="session_epoch_changed"?"session_epoch_changed":"aborted"}:{accepted:!1,rejected:!1,state:null,controlToken:null,error:"acceptance_unconfirmed"}:{accepted:!1,rejected:!1,state:null,controlToken:null,error:"session_epoch_changed"}}catch(s){return r.signal.aborted?{accepted:!1,rejected:!1,state:null,controlToken:null,error:r.signal.reason==="session_epoch_changed"?"session_epoch_changed":"aborted"}:{accepted:!1,rejected:!1,state:null,controlToken:null,error:s instanceof Error?s.message:String(s)}}finally{e.signal?.removeEventListener("abort",o),i()}}function ci(e){let t=!1,n=null,r=!1,o=Xo;const i=new Map,s=new Set,a=c=>{if(c.kind==="observed_response"&&(!Number.isSafeInteger(c.contentGeneration)||(c.contentGeneration??-1)<0||!Number.isSafeInteger(c.streamScope)||(c.streamScope??-1)<0))return!1;const k=si(o,c);return k.accept?(o=k.ownership,!0):!1};return{dispatch:c=>{if(t)return{terminal:!0};const k=d(c.type);if(k==="RUN_STARTED")e.callbacks.onRunStarted?.();else if(k==="TEXT_MESSAGE_CONTENT"&&typeof c.delta=="string"){if(!a(dn(c)))return{terminal:t};e.callbacks.onTextDelta?.(c.delta)}else if(k==="TOOL_CALL_START")e.callbacks.onToolStart?.(d(c.toolCallName)??"tool",d(c.toolCallId)??void 0,Ut(c));else if(k==="TOOL_CALL_ARGS"){const b=d(c.toolCallId)??"",l=Ut(c);typeof c.snapshot=="string"?e.callbacks.onToolArgsSnapshot?.(b,c.snapshot,l):typeof c.delta=="string"&&e.callbacks.onToolArgsDelta?.(b,c.delta,l)}else if(k==="TOOL_CALL_END")e.callbacks.onToolEnd?.(d(c.toolCallId)??void 0,Ut(c));else if(k==="TOOL_CALL_RESULT"){const b=typeof c.content=="string"?c.content:c.result!==void 0?JSON.stringify(c.result,null,2):"";e.callbacks.onToolResult?.(d(c.toolCallId)??"",b,Ut(c))}else if(k==="RUN_FINISHED")t=!0,e.callbacks.onFinished?.();else if(k==="RUN_ERROR")t=!0,e.callbacks.onError?.(d(c.message)??"Turn error");else if(k==="CUSTOM"){const b=d(c.name),l=x(c.value)?c.value:null;if(b!==null&&pd.has(b))b==="KEEPER_RUNTIME_ATTEMPT_STARTED"&&(o=ai(o)),fd(b,c,e.callbacks);else if(b==="KEEPER_STREAM_MESSAGE_START"&&l)a(dn({...l,response:l}));else if(b==="KEEPER_MODEL_CONTENT_ACTIVITY"&&l){const g=d(l.channel);(g==="thinking"||g==="text")&&e.callbacks.onModelActivity?.(g)}else if(b==="KEEPER_THINKING_DELTA"&&l&&typeof l.delta=="string"){if(!a(dn(l)))return{terminal:t};e.callbacks.onThinkingDelta?.(l.delta,ia(l))}else if(b==="KEEPER_THINKING_SNAPSHOT"&&l&&typeof l.snapshot=="string"){if(!a(dn(l)))return{terminal:t};e.callbacks.onThinkingSnapshot?.(l.snapshot,ia(l))}else if(b==="KEEPER_TOOL_CALL_ADMITTED"&&l){const g=d(l.toolCallName);g&&e.callbacks.onToolAdmitted?.(g,d(l.toolCallId)??void 0,Ut(l))}else if(b==="KEEPER_TOOL_RESULT_READY"&&l){const g=d(l.executionId)??d(l.execution_id);g&&e.callbacks.onToolResultReady?.({executionId:g,toolCallId:d(l.toolCallId)??void 0,streamKey:Ut(l),isError:typeof l.isError=="boolean"?l.isError:void 0})}else if(b==="KEEPER_NATIVE_TOOL_START"&&l)e.callbacks.onToolStart?.(d(l.toolCallName)??"native_tool",Po(d(l.toolCallId)),wo(Ut(l)));else if(b==="KEEPER_NATIVE_TOOL_PROGRESS"&&l&&x(l.progress)){const g=nu(l.progress);g&&e.callbacks.onNativeToolProgress?.({toolName:d(l.toolCallName)??void 0,toolCallId:Po(d(l.toolCallId)),streamKey:wo(Ut(l)),progressLabel:g})}else if(b==="KEEPER_NATIVE_TOOL_END"&&l){const g=x(l.completion)?ru(l.completion):{status:"completed"};e.callbacks.onNativeToolEnd?.({toolName:d(l.toolCallName)??void 0,toolCallId:Po(d(l.toolCallId)),streamKey:wo(Ut(l)),status:g.status,summary:g.summary})}else if(b==="KEEPER_TOOL_APPROVAL_REQUESTED"&&l){const g=d(l.tool_call_id)??"";e.callbacks.onToolApprovalRequested?.({toolCallId:g,toolName:d(l.tool_call_name)??"tool",args:typeof l.args=="string"&&l.args.trim()?l.args:void 0,question:d(l.question)??void 0,because:d(l.because)??void 0})}else if(b==="KEEPER_TOOL_APPROVAL_SETTLED"&&l){const g=d(l.tool_call_id)??"",v=d(l.outcome)??"";v&&e.callbacks.onToolApprovalSettled?.({toolCallId:g,toolName:d(l.tool_call_name)??void 0,outcome:v})}else if(b==="KEEPER_CHAT_BATCH_BOUND"&&l){const g=d(l.operation_id),v=d(l.execution_id);g&&v&&e.callbacks.onBatchBound?.(g,v)}else if(b==="KEEPER_ATTACHMENT"&&l){const g=Hr(l);if(g&&(!x(l.response)||a(dn(l)))){const I=d(l.role),S=I==="user"||I==="assistant"||I==="tool"?I:void 0,M=d(l.tool_call_id)??d(l.toolCallId)??void 0,w=C(l.block_index),D=w!==null&&Number.isSafeInteger(w)&&w>=0?w:void 0,re=`${S??"assistant"}:${M??""}:${g.attachment_id||g.url}`;s.has(re)||(s.add(re),e.callbacks.onAttachment?.({attachment:g,role:S,toolCallId:M,blockIndex:D}))}}else if(b==="KEEPER_MEDIA_DELTA"&&l&&Ka(l.media_ref)&&hl(l.media_type)&&l.source_type==="base64"){const g=C(l.index),v=dn(l);if(g!==null&&Number.isSafeInteger(g)&&g>=0&&v.kind==="observed_response"&&a(v)){const E=`${v.contentGeneration}:${v.streamScope}:${g}`;i.has(E)||(i.set(E,{path:l.media_ref,workspaceEpoch:e.startEpoch}),e.callbacks.onRetainedImages?.([...i.values()]))}}else if(b==="KEEPER_CHAT_OPERATION_ACCEPTED"&&l){const g=d(l.state)??"Queued",v=x(l.interactive)?l.interactive:null;e.callbacks.onAccepted?.({operationId:d(l.operation_id)??e.operationId,state:g,queuedCount:C(l.queued_count)??0,controlToken:v?d(v.chat_control_token):null,interruptProblem:v?md(v):null}),(g==="Succeeded"||g==="Failed"||g==="Cancelled")&&(n=g)}else b==="KEEPER_EXTERNAL_EFFECT_COMPLETED"?e.callbacks.onExternalEffectCompleted?.():b==="KEEPER_REPLY_DETAILS"&&l&&typeof l.reply=="string"&&(r=!0,e.callbacks.onReplyDetails?.(l.reply,d(l.turn_ref),d(l.turn_outcome)))}return{terminal:t}},finalizeOnEof:()=>t?!0:n===null?!1:n==="Succeeded"?r?(t=!0,e.callbacks.onFinished?.(),!0):!1:(t=!0,e.callbacks.onError?.(n==="Cancelled"?"작업이 취소되었습니다.":"작업이 실패했습니다."),!0),isTerminal:()=>t}}async function la(e){const t=e.fetchImpl??globalThis.fetch,n=Te();if(e.signal?.aborted)return{terminal:!1,error:"aborted"};const r=`keeper-chat:${e.keeper}:${e.mode.kind}:${e.operationId}`,o=li(),i=_=>{const f=new AbortController,c=()=>f.abort(_?.aborted?_.reason:e.signal?.reason);_?.addEventListener("abort",c,{once:!0}),e.signal?.addEventListener("abort",c,{once:!0});const k=Jt.subscribe(l=>{l!==n&&!f.signal.aborted&&f.abort("session_epoch_changed")});return{promise:(async()=>{try{const l=await t(rs("/api/v1/keepers/chat/stream"),{method:"POST",credentials:"same-origin",headers:o,body:JSON.stringify(ii(e)),signal:f.signal});if(!ie(n))return{terminal:!1,error:"session_epoch_changed"};if(!l.ok){const w=(await l.text().catch(()=>`HTTP ${l.status}`)).trim()||`HTTP ${l.status}`;return e.callbacks.onError?.(w),{terminal:!0,error:w}}if(!l.body)return{terminal:!1,error:"스트림 본문 없음"};const g=l.body.getReader(),v=new TextDecoder;let E="";const I=ci({operationId:e.operationId,startEpoch:n,callbacks:e.callbacks}),S=M=>{if(!ie(n)||f.signal.aborted)return;const w=M.split(/\r?\n/).filter(re=>re.startsWith("data:")).map(re=>re.slice(5).trimStart());if(w.length===0)return;let D;try{D=JSON.parse(w.join(`
`))}catch{return}x(D)&&I.dispatch(D)};try{for(;;){const{done:M,value:w}=await g.read();if(M||!ie(n)||f.signal.aborted)break;E+=v.decode(w,{stream:!0});const D=E.split(/\r?\n\r?\n/);E=D.pop()??"";for(const re of D)if(S(re),I.isTerminal())break;if(I.isTerminal())break}!I.isTerminal()&&E.trim()&&ie(n)&&!f.signal.aborted&&S(E)}finally{try{await g.cancel()}catch{}g.releaseLock()}return ie(n)&&!f.signal.aborted&&I.finalizeOnEof(),{terminal:I.isTerminal(),error:null}}catch(l){return{terminal:!1,error:l instanceof Error?l.message:String(l)}}finally{k(),_?.removeEventListener("abort",c),e.signal?.removeEventListener("abort",c)}})(),abort:()=>{f.signal.aborted||f.abort("view_stream_released")}}};if(e.mode.kind==="btw")return i().promise;let s=null;const a=tl(r,_=>{if(s!==null)return;const f=i(_);return s=f.promise,f.abort});try{return s?await s:{terminal:!1,error:"tab_hidden"}}finally{a.release()}}async function kd(e,t,n={}){const r=_e.peek();if(r.kind!=="single_user_local"||An("admin",r))return $t({kind:"forbidden",status:null,code:r.kind!=="single_user_local"?"single_user_only":"admin_only",message:r.kind!=="single_user_local"?"음성 전사(/api/v1/voice/transcribe)는 싱글유저 로컬 세션 전용입니다.":"음성 전사(/api/v1/voice/transcribe)는 관리자 전용입니다.",retryable:!1});const o=n.fetchImpl??globalThis.fetch,i=Te(),s=new AbortController,a=()=>s.abort(n.signal?.reason);if(n.signal){if(n.signal.aborted)return $t({kind:"aborted",status:null,code:null,message:"Aborted",retryable:!1});n.signal.addEventListener("abort",a,{once:!0})}const _=Jt.subscribe(k=>{k!==i&&s.abort("epoch_stale")}),f={Accept:"application/json","Content-Type":t.trim()?t.trim():"audio/webm"};if(_e.peek().kind==="multi_account_signed_in"){const k=Ea();k&&(f["x-masc-csrf-token"]=k)}else{const k=Ta();k&&(f.Authorization=`Bearer ${k}`)}try{const k=e instanceof Uint8Array?new Uint8Array(e):e,b=await o(rs("/api/v1/voice/transcribe"),{method:"POST",credentials:"same-origin",headers:f,body:k,signal:s.signal});if(!ie(i))return $t({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1});const l=await b.json().catch(()=>null);if(!b.ok){const v=x(l)&&typeof l.error=="string"?l.error:`HTTP ${b.status}`;return $t({kind:b.status>=500?"server":"validation",status:b.status,code:null,message:v,retryable:b.status>=500})}const g=x(l)&&typeof l.text=="string"?l.text:x(l)&&typeof l.transcript=="string"?l.transcript:"";return qr(g)}catch(k){return ie(i)?$t({kind:s.signal.aborted?"aborted":"network",status:null,code:null,message:k instanceof Error?k.message:String(k),retryable:!s.signal.aborted,cause:k}):$t({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1,cause:k})}finally{_(),n.signal?.removeEventListener("abort",a)}}function S_(e,t=60){return we(`/api/v1/keepers/${encodeURIComponent(e)}/turn-records?limit=${t}`,{decode:n=>{const r=Lc(n);if(!r)throw new Error("유효하지 않은 keeper turn record payload");return r}})}function ui(e){const t=e.projection_diagnostics;return!x(t)||t.cache_state!=="stale"?null:{lastSuccessAt:d(t.last_success_at),reason:d(t.stale_reason)}}function di(e){const t=Ql(e);return{...t,health:t.health??"unknown",retained:ui(e)}}function x_(e,t=50,n){return we(`/api/v1/keepers/${encodeURIComponent(e)}/tool-calls?limit=${t}`,{signal:n,decode:r=>{if(!x(r)||!Array.isArray(r.entries))throw new Error("도구 호출 응답에 entries가 없습니다.");const o=r,i=r.entries,s=[];for(const a of i){if(!x(a))continue;const _=a.record_kind;s.push({ts:C(a.ts)??0,record_kind:_==="composition_run"||_==="lifecycle_event"?_:"tool_call",keeper:d(a.keeper)??e,tool:d(a.tool)??"unknown",duration_ms:C(a.duration_ms)??0,wire_outcome:d(a.wire_outcome)??"unknown",disposition:a.disposition==="completed"||a.disposition==="deferred"||a.disposition==="failed"?a.disposition:void 0,failure_class:d(a.failure_class)??void 0,execution_id:d(a.execution_id)??void 0,trace_id:d(a.trace_id)??void 0,turn:C(a.turn)??void 0,task_id:d(a.task_id)??void 0,model:d(a.model)??void 0,result_bytes:C(a.result_bytes)??void 0,truncated_to:C(a.truncated_to)??void 0,input:a.input,output:a.output})}return{keeper:d(o.keeper)??e,count:C(o.count)??s.length,...di(o),entries:s}}})}function R_(e,t=24,n){return we(`/api/v1/keepers/${encodeURIComponent(e)}/tool-stats?window_hours=${t}`,{signal:n,decode:r=>{if(!x(r)||!Array.isArray(r.tools))throw new Error("도구 통계 응답에 tools가 없습니다.");const o=r,i=r.tools.filter(x).map(s=>({name:d(s.name)??"unknown",call_count:C(s.call_count)??0,success_count:C(s.success_count)??0,failure_count:C(s.failure_count)??0,avg_duration_ms:C(s.avg_duration_ms)??0,p95_duration_ms:C(s.p95_duration_ms)??0}));return{keeper:d(o.keeper)??e,window_hours:C(o.window_hours)??t,total_entries:C(o.total_entries)??i.reduce((s,a)=>s+a.call_count,0),...di(o),tools:i}}})}function A_(e){return we(`/api/v1/keepers/${encodeURIComponent(e)}/last-prompt`,{decode:t=>{const n=x(t)?t:{},r=Array.isArray(n.blocks)?n.blocks.filter(x).map(o=>({id:d(o.id)??"block",bytes:C(o.bytes)??0,text:typeof o.text=="string"?o.text:""})):[];return{keeper:d(n.keeper)??e,captured_at:C(n.captured_at)??0,trace_id:d(n.trace_id)??"",absolute_turn:C(n.absolute_turn)??0,assembled:typeof n.assembled=="string"?n.assembled:null,assembled_bytes:C(n.assembled_bytes)??0,system_prompt:typeof n.system_prompt=="string"?n.system_prompt:null,blocks:r}}})}function C_(e,t){return we(`/api/v1/keepers/${encodeURIComponent(e)}/provider-input?turn_ref=${encodeURIComponent(t)}`,{decode:n=>{const r=x(n)?n:{},o=x(r.wire)?r.wire:{},i=Array.isArray(r.parts)?r.parts.filter(x).map((s,a)=>({index:C(s.index)??a,kind:s.kind==="system_prompt"||s.kind==="tool_schema"?s.kind:"message",role:d(s.role)??void 0,name:d(s.name)??void 0,bytes:C(s.bytes)??0,sha256:d(s.sha256)??""})):[];return{keeper:d(r.keeper)??e,turn_ref:d(r.turn_ref)??t,runtime_profile:d(r.runtime_profile)??"",wire:{provider:d(o.provider)??"unknown",model:d(o.model)??"unknown",http_codec:d(o.http_codec)??"",body_bytes:C(o.body_bytes)??0},parts:i}}})}function I_(e,t=15){return we(`/api/v1/keepers/${encodeURIComponent(e)}/raw-traces?limit=${t}`,{decode:n=>(x(n)&&Array.isArray(n.turns)?n.turns:[]).filter(x).map(o=>{const i=x(o.census)?o.census:null;return{file:d(o.file)??"",trace_id:d(o.trace_id),bytes:C(o.bytes)??0,records:i&&i.state==="whole_file"?C(i.records):null,modified_at:C(o.modified_at)??0}}).filter(o=>o.file.length>0)})}function O_(e,t,n=30){const r=new URLSearchParams({file:t,limit:String(n)});return we(`/api/v1/keepers/${encodeURIComponent(e)}/raw-trace?${r.toString()}`)}function w_(e){return we(`/api/v1/keepers/${encodeURIComponent(e)}/checkpoints`,{decode:t=>{const n=x(t)?t:{},r=i=>{if(!x(i))return null;const s=d(i.snapshot_id);return s?{snapshot_id:s,message_count:C(i.message_count)??0,created_at:C(i.created_at)??0,latest_preview:d(i.latest_preview)}:null},o=n.current_status;return{keeper:d(n.keeper)??e,trace_id:d(n.trace_id)??"",current_status:o==="available"||o==="unavailable"?o:"missing",current:r(n.current),history:Array.isArray(n.history)?n.history.map(r).filter(i=>i!==null):[]}}})}function vd(e){if(!x(e))return{state:"read_error",read_error:"invalid_ordinary_memory_payload"};if(typeof e.read_error=="string"&&e.read_error.trim().length>0)return{state:"read_error",read_error:e.read_error};if(e.present===!1)return{state:"absent"};if(e.present===!0){const t=Array.isArray(e.facts)?e.facts.filter(x).map(r=>({memory_id:d(r.memory_id)??"",claim:typeof r.claim=="string"?r.claim:"",category:d(r.category)??"general",first_seen:C(r.first_seen)??0,last_seen:C(r.last_seen)??0})):[],n=Array.isArray(e.support_invalidations)?e.support_invalidations.filter(x).map(r=>({memory_id:d(r.memory_id)??"",claim:typeof r.claim=="string"?r.claim:"",missing_premise_ids:Array.isArray(r.missing_premise_ids)?r.missing_premise_ids.filter(o=>typeof o=="string"):[]})):[];return{state:"present",revision:C(e.revision)??0,snapshot_sha256:d(e.snapshot_sha256)??"",updated_at:C(e.updated_at)??0,facts:t,support_invalidations:n}}return{state:"read_error",read_error:"unrecognized_ordinary_memory_discriminant"}}function hd(e){if(!x(e))return{state:"read_error",read_error:"invalid_source_bound_payload"};if(typeof e.read_error=="string"&&e.read_error.trim().length>0)return{state:"read_error",read_error:e.read_error};if(e.present===!1)return{state:"absent"};if(e.present===!0){const t=Array.isArray(e.facts)?e.facts.filter(x).map(r=>({claim:typeof r.claim=="string"?r.claim:"",first_seen:C(r.first_seen)??0,path:d(r.path)??"",sha256:d(r.sha256)??""})):[],n=Array.isArray(e.invalidations)?e.invalidations.filter(x).map(r=>({source_path:d(r.source_path)??"",invalidated_at:C(r.invalidated_at)??0,reason:d(r.reason)??"source_changed"})):[];return{state:"present",revision:C(e.revision)??0,updated_at:C(e.updated_at)??0,facts:t,invalidations:n}}return{state:"read_error",read_error:"unrecognized_source_bound_discriminant"}}function bd(e,t){const n=x(e)?e:{};return{keeper:d(n.keeper)??t,ordinary:vd(n.ordinary),source_bound:hd(n.source_bound),events_unreadable_lines:C(n.events_unreadable_lines)??0,events_read_error:d(n.events_read_error)}}function P_(e,t){return we(`/api/v1/keepers/${encodeURIComponent(e)}/memory-facts`,{signal:t,decode:n=>bd(n,e)})}function K_(e,t){return we(`/api/v1/keepers/${encodeURIComponent(e)}/memory-os-internals`,{signal:t,decode:n=>{const r=x(n)?n:{},o=x(r.compaction)?r.compaction:{},i=x(r.canonical_turns)?r.canonical_turns:{},s=x(r.memory_digest)?r.memory_digest:{},a=x(r.librarian_molt)?r.librarian_molt:{},_=Array.isArray(a.available_acts)?a.available_acts.map(f=>typeof f=="string"?f:x(f)?d(f.action)??JSON.stringify(f):String(f)):[];return{keeper:d(r.keeper)??e,compaction:{present:o.present===!0,epoch_count:C(o.epoch_count)??0,archived_turns_count:C(o.archived_turns_count)??0,anchor_bytes:C(o.anchor_bytes)??0,latest_epoch_id:C(o.latest_epoch_id),verified_facts_count:C(o.verified_facts_count)??0,decisions_count:C(o.decisions_count)??0,open_threads_count:C(o.open_threads_count)??0,read_error:d(o.read_error)},canonical_turns:{present:i.present===!0,turn_count:C(i.turn_count)??0,latest_turn_id:d(i.latest_turn_id),compaction_watermark_seq:C(i.compaction_watermark_seq),compaction_watermark_epoch:C(i.compaction_watermark_epoch),history_resets_count:C(i.history_resets_count)??0,read_error:d(i.read_error)},memory_digest:{present:s.present===!0,revision:C(s.revision),digest_sha256:d(s.digest_sha256),bytes:C(s.bytes)??0,fact_count:C(s.fact_count)??0,derived_count:C(s.derived_count)??0},librarian_molt:{writer_kind:d(a.writer_kind)??"unknown",writer_state:a.writer_state??null,pending_molt:a.pending_molt??null,available_acts:_}}}})}function N_(e,t=50,n){return we(`/api/v1/keepers/${encodeURIComponent(e)}/memory-journal?activity=1&limit=${t}`,{signal:n,decode:r=>{if(!x(r)||!Array.isArray(r.entries)||!r.entries.every(x))throw new Error("메모리 저널 응답에 유효한 entries가 없습니다.");const o=r.entries.map(a=>{const _=x(a.source)?a.source:null,f=x(a.change)?a.change:null,c=k=>Array.isArray(k)?k.length:C(k)??0;return{structural_id:d(a.structural_id)??"",ok:a.ok===!0,error:d(a.error)??void 0,recorded_at:C(a.recorded_at)??void 0,revision:C(a.revision)??void 0,source_kind:_?d(_.kind)??void 0:void 0,added:f?c(f.added):void 0,removed:f?c(f.removed):void 0,retained:f?C(f.retained)??0:void 0,invalidated:f?c(f.invalidated):void 0}}),i=x(r.activity)?r.activity:null,s=i?{events:Array.isArray(i.events)?i.events.filter(x).map(a=>({identity:d(a.identity)??"",recorded_at:C(a.recorded_at)??0,revision:C(a.revision)??0,kind:d(a.kind)??"unknown",reason:d(a.reason)})):[],notes:Array.isArray(i.notes)?i.notes.filter(a=>typeof a=="string"):[]}:null;return{keeper:d(r.keeper)??e,returned:C(r.returned)??o.length,undecodable_lines:C(r.undecodable_lines)??0,entries:o,activity:s}}})}function M_(e,t,n){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/memory/act`,t,{signal:n,decode:r=>{if(!x(r)||r.ok!==!0||r.keeper!==e||r.action!==t.action)throw new Error("메모리 복구 결과를 확인할 수 없습니다.");return r}})}function L_(e,t,n=`dashboard-retract-${Cn()}`,r){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/memory/retractions`,{plan_id:n,retractions:t},{signal:r,decode:o=>{if(!x(o)||o.ok!==!0||o.keeper!==e||o.plan_id!==n||!Array.isArray(o.retractions))throw new Error("메모리 철회 결과를 확인할 수 없습니다.");return o.retractions.map(i=>{if(!x(i)||typeof i.memory_id!="string"||i.outcome!=="retracted"&&i.outcome!=="not_current")throw new Error("메모리 철회 응답에 확인 가능한 결과가 없습니다.");return{memoryId:i.memory_id,outcome:i.outcome}})}})}function D_(e,t=100,n){return Sa(`/api/v1/candle/ledger?keeper=${encodeURIComponent(e)}&limit=${t}`,{signal:n,decode:r=>{const o=x(r)?r:{},i=x(o.policy)?o.policy:{},s=x(i.half_life)?i.half_life:{},a=x(o.supply)?o.supply:{},_=v=>typeof v=="string"&&v.trim()?v.trim():typeof v=="number"?String(Math.trunc(v)):"0",f=Array.isArray(o.balances)?o.balances.filter(x):[],c=f.find(v=>d(v.keeper)===e)??f[0]??null,k=c&&x(c.equipped)?c.equipped:{},b=c?{keeper:d(c.keeper)??e,balance_milli:C(c.balance_milli)??0,decayed_milli:_(c.decayed_milli),last_event_unix:C(c.last_event_unix),owned_items:Array.isArray(c.owned_items)?c.owned_items.filter(v=>typeof v=="string"):[],equipped:{face:d(k.face),neck:d(k.neck),head:d(k.head),hand:d(k.hand),base:d(k.base)}}:null,l=Array.isArray(o.recent_events)?o.recent_events.filter(x).map(v=>({seq:C(v.seq)??0,at_unix:C(v.at_unix)??0,at_rfc3339:d(v.at_rfc3339)??"",kind:d(v.kind)??"event",summary:d(v.item)??d(v.goal_id)??(typeof v.amount_milli=="string"||typeof v.amount_milli=="number"?`${_(v.amount_milli)} mC`:d(v.reason)??"")})):[],g=i.configuration;return{ledger_state:o.ledger_state==="present"?"present":"missing",total_events:C(o.total_events)??0,policy_configuration:g==="enabled"?"enabled":g==="disabled"?"disabled":"off",disabled_reason:d(i.disabled_reason),pricing_mode:d(i.pricing_mode)??"off",half_life_hours:C(s.half_life_hours),supply:{issued_milli:_(a.issued_milli),burned_milli:_(a.burned_milli),circulating_milli:_(a.circulating_milli)},balance:b,recent_events:l}}})}function U_(e,t){return we(`/api/v1/keepers/${encodeURIComponent(e)}/items`,{signal:t,decode:n=>{const r=x(n)?n:{},o=r.status==="ready"?"ready":r.status==="disabled"?"disabled":"off",i=Array.isArray(r.catalog)?r.catalog.filter(x).map(s=>{const a=d(s.slot),_=a==="face"||a==="neck"||a==="head"||a==="hand"||a==="base"?a:"head",f=s.price_status==="priced"?"priced":"unpriced";return{id:d(s.id)??"",slot:_,price_status:f,price_milli:typeof s.price_milli=="string"?s.price_milli:null}}).filter(s=>s.id.length>0):[];return{status:o,reason:d(r.reason)??void 0,account_revision:d(r.account_revision),balance_milli:typeof r.balance_milli=="string"?r.balance_milli:null,owned_items:Array.isArray(r.owned_items)?r.owned_items.filter(s=>typeof s=="string"):[],catalog:i}}})}function B_(e,t){return we("/api/v1/dashboard/execution?light=true",{signal:t,decode:n=>{if(!x(n)||!Array.isArray(n.tasks))throw new Error("작업 목록 응답에 tasks가 없습니다.");const r=x(n.task_counts)?n.task_counts:null,o=qs(r?.total),i=qs(r?.shown);return{tasks:n.tasks.filter(x).filter(a=>d(a.assignee)===e).map(a=>({id:d(a.id)??"",title:d(a.title)??"",status:d(a.status)??"Todo",priority:C(a.priority)??0,goal_id:d(a.goal_id),updated_at:d(a.updated_at)})).filter(a=>a.id.length>0),workspaceScope:o!==null&&i!==null&&i>=0&&o>=i?{total:o,shown:i}:null,retained:ui(n)}}})}function pi(e,t){if(!x(e)||e.keeper!==t||typeof e.pending!="boolean"||!x(e.note)||typeof e.note.text!="string")throw new Error("운영자 노트 응답을 확인할 수 없습니다.");return{keeper:t,pending:e.pending,text:e.note.text,created_by:d(e.note.created_by)??"",created_at:C(e.note.created_at)??0,consumed_turn:C(e.note.consumed_turn)}}function q_(e,t){return we(`/api/v1/keepers/${encodeURIComponent(e)}/operator-note`,{signal:t,decode:n=>pi(n,e)})}function F_(e,t,n){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/operator-note`,{text:t},{signal:n,decode:r=>pi(r,e)})}async function H_(e,t){const n=await Sa(`/api/v1/infra/sandboxes/${encodeURIComponent(e)}`,{signal:t,decode:r=>{if(!x(r)||r.keeper!==e||!x(r.sandbox))throw new Error("Invalid sandbox observation for this Keeper");const o=x(r.probe_state)?r.probe_state:{},i=r.sandbox;return{keeper:e,probe_kind:d(o.kind)??"unknown",backend:d(i.backend)??d(i.kind)??d(i.sandbox_profile)??"observed",summary:i}}});return!n.ok&&n.error.status===404&&n.error.code==="sandbox_telemetry_missing"?qr(null):!n.ok&&n.error.kind==="forbidden"?$t({...n.error,message:"이 Keeper의 샌드박스 상태는 소유자 또는 관리자만 조회할 수 있습니다 (403)."}):n}function yd(e){return(x(e)&&Array.isArray(e.providers)?e.providers:[]).filter(x).map(n=>({provider:d(n.provider)??"",provider_label:d(n.provider_label)??d(n.provider)??"",attached:n.attached===!0,enabled:typeof n.enabled=="boolean"?n.enabled:void 0,tools:Array.isArray(n.tools)?n.tools.filter(r=>typeof r=="string"):void 0,problem:d(n.problem)??void 0,switch_problem:d(n.switch_problem)??void 0})).filter(n=>n.provider.length>0)}function j_(e,t){return we(`/api/v1/keepers/oauth/attached-tools?keeper=${encodeURIComponent(e)}`,{signal:t,decode:n=>{const r=x(n)&&x(n.callback)?n.callback:null;return{providers:yd(n),callbackUrl:r?d(r.url):null}}})}function G_(e,t,n){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/identity-switch`,{provider:t,enabled:n})}function W_(e,t){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/identity-refresh`,{provider:t})}function V_(e,t){return He("POST",`/api/v1/keepers/${encodeURIComponent(e)}/secrets`,t)}function _i(e,t,n,r){if(r?.has(n.ownerKey))return e;const o=e.find(s=>s.ownerKey===n.ownerKey);if(o){const s=o.preview,a=n.preview;if(s.revision!==null&&(a.revision===null||a.revision<=s.revision)||s.revision===null&&a.revision===null&&a.updated_at_unix<=s.updated_at_unix)return e}const i=t&&t!==n.ownerKey?e.find(s=>s.ownerKey===t):e.find(s=>s.ownerKey!==n.ownerKey);return i?[n,i]:[n]}function fi(e,t,n,r){if(t){const o=t.preview_observed_through??t.preview?.revision??0;return e.find(i=>i.ownerKey===t.owner_key&&(i.preview.revision??0)>o)}return e.find(o=>!r?.has(o.ownerKey)&&(n===void 0||o.receivedAt>n))}const ca=new Map;function $d(e,t,n){const r=e.get(t)??[],o=_i(r,void 0,n);return o===r?e:new Map(e).set(t,o)}function mi(e,t){const n=e.active_turn;if(!n||!t)return e;const r=fi(t,n,void 0);return r?{...e,active_turn:{...n,preview:r.preview,preview_observed_through:r.preview.revision}}:e}const ua="턴 경과 시간",da="이 상태로 지난 시간";function fs(e){return Il(e),e?Math.max(Ol.value,Date.now()):Date.now()}function gi({startedAt:e,observedAt:t,live:n}){const r=fs(n),i=((n?Math.max(r,t):t)-e)/1e3;return u`<span class="kp-turn-elapsed" role="timer" aria-label=${ua} title=${ua}>${fn(i)}</span>`}function Ed({sinceUnix:e}){const t=Math.max(0,fs(!0)/1e3-e);return u`<span class="kp-turn-elapsed" role="timer" aria-label=${da} title=${da}>${fn(t)}</span>`}function Td(e){switch(e.state){case"active":{const t=ds("preparing");return{phrase:`${t.label} · ${js(e.phase)}`,sinceUnix:e.started_at_unix,tone:t.tone}}case"prepared":return{phrase:`${js(e.phase)} 준비 완료`,sinceUnix:null,tone:"info"};case"rejected":case"raised":case"cancelled":return{phrase:Al(e),sinceUnix:null,tone:"bad"}}}function ms(e){if(e.preparation!==null)return null;switch(e.activity){case"failed":case"preparing":return null;default:return ku(e.open_activities??[])}}function ur(e){if(e.preparation!==null)return Td(e.preparation);const t=ds(e.activity),n=ms(e);return n!==null?{phrase:hu(n),sinceUnix:n.lead.since_unix,tone:t.tone}:{phrase:t.label,sinceUnix:null,tone:t.tone}}function Sd(e){return ms(e)===null?ur(e):null}const ki="턴 실행 중";function xd(e){if(e===null)return{kind:"words",words:ki};const t=ms(e);return t===null||t.lead.kind!=="tool"?{kind:"words",words:ur(e).phrase}:{kind:"tool",name:t.lead.name,otherCalls:t.otherCalls}}const Rd=Oa(async()=>({default:(await On(async()=>{const{CreateKeeperModal:e}=await import("./create-keeper-modal.js");return{CreateKeeperModal:e}},__vite__mapDeps([0,1,2,3,4,5,6,7,8]))).CreateKeeperModal})),es="대기 목록 읽기 실패",Ad="대기 ?";function Cd(e){return Mr(e.waiting_summary)?es:e.waiting_summary&&e.waiting_summary.count>0?`대기 ${e.waiting_summary.count}`:null}const wr=12,Id=`${wr+2}ch`;function Od(e){const t=[...e];return t.length>wr?[t.slice(0,-wr).join(""),t.slice(-wr).join("")]:[e,""]}function wd(e){return Gr(e)?"bad":jr(e)||e.paused?"warn":e.active_turn?"brass":e.keepalive_running?"ok":"idle"}function Pd(e){const t=e.turnsObservation,n=An("admin",_e.value),[r,o]=F("companies"),[i,s]=F(""),[a,_]=F(!1);Se(()=>{n&&a&&_(!1)},[n,a]);const f=e.roster.kind==="value"?e.roster.data:[],c=Pa(),k=wt(()=>ju(f,r,i),[f,r,i]),b=be(l=>l.name,[]);return u`
    <aside class="kp-roster" aria-label="Keeper 로스터">
      <div class="kp-roster-head">
        <div class="kp-roster-top">
          <h2 class="kp-roster-title">
            <span class="kp-roster-title-text" title=${`Keepers (${f.length})`}>
              Keepers (<span class="tnum">${f.length}</span>)
            </span>
            ${e.roster.kind==="value"&&e.roster.stale&&u`
              <span class="kp-pill" data-tone="warn">지연됨</span>
            `}
          </h2>
          ${!n&&u`
            <button
              type="button"
              class="btn-primary"
              onClick=${()=>_(!0)}
            >
              + Create Keeper
            </button>
          `}
        </div>

        <input
          type="search"
          class="kp-input"
          placeholder="Keeper, 회사, 런타임 검색…"
          aria-label="Keeper 검색"
          value=${i}
          onInput=${l=>s(l.currentTarget.value)}
        />

        <div class="kp-modes" role="group" aria-label="로스터 정렬 모드">
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${r==="companies"?"true":"false"}
            onClick=${()=>o("companies")}
          >
            Companies
          </button>
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${r==="attention"?"true":"false"}
            onClick=${()=>o("attention")}
          >
            Attention
          </button>
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${r==="wall24h"?"true":"false"}
            onClick=${()=>o("wall24h")}
          >
            24h Wall
          </button>
        </div>
      </div>

      ${e.roster.kind==="loading"?u`<div class="kp-empty">로스터 불러오는 중…</div>`:e.roster.kind==="failed"?u`<div class="ap-error" role="alert">${e.roster.error.message}</div>`:u`
              <${wl}
                className="kp-roster-list"
                items=${k}
                estimateSize=${60}
                height="100%"
                ariaLabel="Keeper 목록"
                getItemKey=${b}
                empty=${u`<div class="kp-empty">일치하는 Keeper 없음</div>`}
                renderItem=${l=>{const g=mi(l,e.turnPreviews?.get(l.name)),v=ps(g),E=Ur(g),I=v.kind==="value"?E.label:os(v,De=>`${De}%`),S=jr(g),M=Gr(g),w=e.selectedKeeper===g.name,D=Mr(g.waiting_summary),re=D&&g.waiting_summary.reason?`${es}: ${g.waiting_summary.reason}`:es,W=Cd(g),z=D?null:W,ce=Fo(c,g.runtime_id),xe=W===null?ce:`${W} · ${ce}`,te=!M&&!S?g.active_turn:null,se=te?.preview??null,ue=te?xd(se):null,Y=M?`⚠ ${g.runtime_blocker_summary??g.last_failure?.cause??g.directory_issue??g.health}`:S?`⏸ 휴식 · ${Fo(c,g.runtime_path_rest?.runtime_id??g.runtime_id)}`:te?`${se?ur(se).phrase:ki} · ${xe}`:xe,de=t&&g.active_turn&&g.active_turn.started_at_unix>0?u`<span class="kp-roster-sub kp-roster-elapsed" data-roster-elapsed><${gi}
                        startedAt=${g.active_turn.started_at_unix*1e3}
                        observedAt=${t.observedAt}
                        live=${t.live}
                      />${" · "}</span>`:null,Me=g.operator_disposition&&g.operator_disposition!=="pass"?g.operator_disposition:null,Ce=r==="wall24h"?g.turns_24h_breakdown&&g.turns_24h_breakdown.failed>0?`${g.turns_24h_breakdown.ok}ok/${g.turns_24h_breakdown.failed}fail`:g.turns_24h!==null?`${g.turns_24h}t/24h`:"없음":r==="attention"&&M?`⚠ ${Me??g.health}`:r==="attention"&&S?"⏸ 휴식":g.company;return u`
                    <button
                      type="button"
                      class="kp-roster-row"
                      data-keeper=${g.name}
                      data-selected=${w?"true":"false"}
                      aria-current=${w?"true":void 0}
                      onClick=${()=>e.onSelectKeeper(g.name)}
                    >
                      <span class="kp-roster-avatar">
                        <${dl}
                          id=${g.name}
                          size="md"
                          variant="sigil"
                          portrait=${!0}
                          beat=${g.active_turn!==null}
                        />
                        <span class="kp-status-dot" data-tone=${wd(g)} />
                      </span>
                      <span class="kp-roster-text">
                        <span class="kp-roster-line">
                          <span class="kp-roster-name">${g.name}</span>
                          <span class="kp-pill" data-ctx="true" data-tone=${Ja(v)} title=${E.tooltip}>
                            Ctx ${I}
                          </span>
                        </span>
                        <span class="kp-roster-line">
                          <span class="kp-roster-state" data-in-turn=${ue!==null?"true":void 0}>
                            ${de}
                            ${ue===null?u`<span class="kp-roster-sub" data-roster-state title=${Y}>${Y}</span>`:u`
                                  <span
                                    class="kp-roster-sub kp-roster-turn"
                                    data-roster-state
                                    data-waiting-unread=${D?"true":void 0}
                                    title=${Y}
                                  >
                                    ${D&&u`<span class="kp-roster-waiting-unread" title=${re}>${`${Ad} · `}</span>`}
                                    ${ue.kind==="words"?u`<span class="kp-roster-words">${ue.words}</span>`:(([De,ke])=>u`
                                          <span
                                            class="kp-roster-tool"
                                            style=${{flexBasis:D?ue.otherCalls>0?"6ch":"0":Id}}
                                          >
                                            <span class="kp-roster-tool-front">${De}</span>
                                            ${ke!==""&&u`<span>${ke}</span>`}
                                          </span>
                                          ${ue.otherCalls>0&&u`<span>${` ${Ya(ue.otherCalls)}`}</span>`}
                                        `)(Od(ue.name))}
                                    ${z!==null&&u`<span class="kp-roster-waiting">${` · ${z}`}</span>`}
                                  </span>
                                `}
                          </span>
                          <span class="kp-roster-sub kp-roster-side" title=${Ce}>${Ce}</span>
                        </span>
                      </span>
                    </button>
                  `}}
              />
            `}

      ${!n&&a&&u`
        <${Nr} fallback=${null}>
          <${Rd}
            onClose=${()=>_(!1)}
            onCreated=${l=>{_(!1),e.onCreatedKeeper(l)}}
          />
        <//>
      `}
    </aside>
  `}function pa(e){const t=new Date(e);return Number.isNaN(t.getTime())?e:t.toLocaleString()}const Kd=["메트릭·결정·상태 전이 로그","Memory OS 스냅샷과 저널","TOML 설정 및 대화 기록","격리 작업 디렉터리 및 토큰"],Nd=new Set(["offline","stopped","crashed"]),Md=new Set(["unbooted","offline","stopped","crashed","dead"]),Ld=new Set(["running","failing","draining","restarting","paused"]);function Dd(e){if(e.keepalive_running||e.paused)return!0;const t=e.phase.trim().toLowerCase(),n=e.status.trim().toLowerCase();return Nd.has(t)||Md.has(n)?!1:Ld.has(t)||n==="running"||n==="active"}function Ud(e){const{keeper:t}=e,n=pl(t.name,96),r=_l(n),[o,i]=F(null),[s,a]=F(null),[_,f]=F(null),[c,k]=F(!1),[b,l]=F(null),[g,v]=F(""),[E,I]=F(null),S=X(null),M=X(null),w=X(!0),D=X(t.name);D.current=t.name,Se(()=>(w.current=!0,()=>{w.current=!1}),[]),xa({containerRef:S,active:c,initialFocus:()=>M.current});const re=()=>{k(!1),l(null),v(""),I(null)};Se(()=>{f(null),re()},[t.name]),Se(()=>{if(!c)return;queueMicrotask(()=>M.current?.focus());const H=Ie=>{if(!(Ie.defaultPrevented||Ie.isComposing||Ie.keyCode===229)&&Ie.key==="Escape"){if(typeof document<"u"&&Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).some(pt=>pt!==S.current))return;Ie.preventDefault(),Ie.stopPropagation(),re()}};return window.addEventListener("keydown",H),()=>window.removeEventListener("keydown",H)},[c]);const W=_e.value,z=Kr(W),ce=z,xe=z&&!An("admin",W),te=Jt.value,se=qt.observe("keepers:tool-approval-modes").value,ue=Pa();Se(()=>{if(!z)return;Ao("mount");const H=sr(je=>{Ra(je).includes("keeper_tool_approval_mode_changed")&&Ao("sse")}),Ie=ss(()=>{Ao("sse")});return()=>{H(),Ie()}},[z,te]);const Y=z&&se.kind==="value"?se.data.overrides[t.name]??se.data.defaultMode:null,de=z&&se.kind==="value"?se.data.restoreError:null,Me=ps(t),Ce=Ur(t),De=Me.kind==="value"?Ce.label:os(Me,H=>`${H}%`),ke=Gr(t),me=Dd(t),Pe=t.paused||t.phase.trim().toLowerCase()==="paused",Ue=jr(t),pe=t.active_turn?.preview??null,Et=pe?ur(pe):null,tt=Mr(t.waiting_summary)?t.waiting_summary:null,Ke=t.waiting_summary&&!Mr(t.waiting_summary)?t.waiting_summary:null,lt=t.runtime_lane_failures??[],ye=t.turns_24h_breakdown,nt=t.operator_disposition&&t.operator_disposition!=="pass"?t.operator_disposition:null,ct=!!(Ue||t.directory_issue||t.runtime_blocker_summary||de||tt||Ke&&Ke.count>0||nt),j=!!(ct||t.last_failure||lt.length>0||ye&&(ye.failed>0||ye.rested>0)),A=[];t.directory_issue&&A.push(`설정 오류: ${t.directory_issue}`),t.runtime_blocker_summary&&A.push(`차단: ${t.runtime_blocker_summary}`),Ue&&A.push(`경로 휴식 (${t.runtime_path_rest?.runtime_id??t.runtime_id})`),de&&A.push("승인 모드 복구 오류"),tt?A.push("대기 목록 읽기 실패"):Ke&&Ke.count>0&&A.push(`대기 ${Ke.count}건`),nt&&A.push(`조치: ${nt}`),lt.length>0&&A.push(`폴백 시도 ${lt.length}건`),ye&&(ye.failed>0||ye.rested>0)&&A.push(`24h 실패 ${ye.failed} · 휴식 ${ye.rested}`),A.length===0&&t.last_failure&&A.push(`최근 실패: ${t.last_failure.cause}`);const V=A.slice(0,2).join(" · ")||"런타임 진단 상세",ne=e.turnStatus==="loading"?"조회 중…":e.turnStatus==="failed"?"조회 실패":t.active_turn?`실행 중 (${t.active_turn.lane})`:"유휴",le=Y==="yolo"?"kp-meta-trigger kp-meta-trigger--bad":e.turnStatus==="failed"?"kp-meta-trigger kp-meta-trigger--warn":"kp-meta-trigger",ae=Y==="yolo"?"상태 · ⚠ YOLO ▾":e.turnStatus==="failed"?"상태 · ⚠ ▾":"상태 ▾",Ne=[...ce&&me&&t.active_turn===null?[{id:"interrupt",label:"Interrupt Turn",description:"유휴 상태에서도 턴 중단 신호 전송",disabled:s!==null,onSelect:()=>{Ve("Interrupt Turn",()=>Co(t.name),"member")}}]:[],...xe?[{id:"delete",label:"Delete",description:"Keeper 및 모든 아티팩트 영구 삭제",danger:!0,separatorBefore:ce&&me&&t.active_turn===null,disabled:s!==null,onSelect:()=>{l(t.phase),k(!0)}}]:[]],Ve=async(H,Ie,je="admin")=>{const pt=_e.peek();if(je==="member"){if(!Kr(pt))return}else if(pt.kind!=="single_user_local"||An("admin",pt))return;const mn=t.name,Kn=Te();a(H),f(null);const Nn=await Ie();if(!(!w.current||D.current!==mn||!ie(Kn))){if(a(null),!Nn.ok){f({tone:"bad",text:`${H} 실패: ${Nn.error?.message??"오류"}`});return}f(null),In(`${H} 요청이 처리되었습니다.`,"success"),e.onLifecycleMutated()}},vt=async()=>{const H=_e.peek();if(H.kind!=="single_user_local"||An("admin",H))return;const Ie=t.name;if(g.trim()!==Ie)return;const je=Te();a("delete"),I(null);const pt=await Zu(Ie);if(!(!w.current||D.current!==Ie||!ie(je))){if(a(null),!pt.ok){const mn=`삭제 실패: ${pt.error.message}`;I(mn),f({tone:"bad",text:mn});return}k(!1),v(""),I(null),e.onDeleted()}};return u`
    <header class="kp-hero">
      <div class="kp-hero-top">
        <div class="kp-hero-id">
          <div class="kp-hero-portrait-ring">
            ${r!==null&&o!==r?u`
                  <img
                    class="kp-hero-portrait-img"
                    src=${r}
                    data-portrait-url=${n}
                    alt=${`${t.name} portrait`}
                    onError=${()=>i(r)}
                  />
                `:u`
                  <span class="kp-hero-portrait-sigil" aria-label=${t.name}>
                    ${qo(t.name)}
                  </span>
                `}
          </div>

          <div class="kp-hero-text">
            <h1 class="kp-hero-name">${t.name}</h1>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone=${ke?"bad":Ue||t.paused?"warn":"ok"}>
                ${ke?`⚠ ${t.health}`:Ue?"⏸ 휴식 중":t.paused?"Paused":t.health}
              </span>
              <span
                class="kp-pill"
                data-ctx="true"
                data-tone=${Ja(Me)}
                title=${Ce.tooltip}
              >
                Ctx ${De}
              </span>
              ${t.active_turn&&u`
                <span class="kp-pill" data-turn-pill data-tone="brass" title=${pe?.status_text||void 0}>
                  ● ${Wa(t.active_turn.lane)}${Et?` · ${Et.phrase}`:""}
                </span>
              `}
              ${Ke&&Ke.count>0&&u`
                <span
                  class="kp-pill"
                  data-tone="warn"
                  title=${Ke.primary_reason??void 0}
                >
                  대기 ${Ke.count}${Ke.primary_reason?` · ${Ke.primary_reason}`:""}
                </span>
              `}
              ${tt&&u`
                <span class="kp-pill" data-tone="bad" title=${tt.reason??void 0}>
                  대기 목록 읽기 실패
                </span>
              `}
              <${Or}
                triggerLabel=${ae}
                triggerClassName=${le}
                triggerTestId="keeper-meta-menu"
                popoverTestId="keeper-meta-popover"
                popoverClassName="kp-meta-popover"
                role="dialog"
                ariaLabel="Keeper 런타임 상태 세부정보"
                triggerTitle=${`Phase: ${t.phase} · Runtime: ${t.runtime_id}`}
              >
                <div class="kp-meta-row">
                  <span class="kp-meta-key">Phase</span>
                  <span class="kp-meta-val">${t.phase}</span>
                </div>
                <div class="kp-meta-row">
                  <span class="kp-meta-key">Runtime</span>
                  <span class="kp-meta-val">${Fo(ue,t.runtime_id)}</span>
                </div>
                <div class="kp-meta-row">
                  <span class="kp-meta-key">턴 상태</span>
                  <span class="kp-meta-val">${ne}</span>
                </div>
                ${Y!==null&&u`
                  <div class="kp-meta-row">
                    <span class="kp-meta-key">도구 승인</span>
                    <span class="kp-meta-val">
                      ${Y==="yolo"?"⚠ YOLO (자동 통과)":Y}
                    </span>
                  </div>
                `}
              <//>
            </div>
          </div>
        </div>

        ${xe?u`
              <div class="kp-lifecycle-bar" role="group" aria-label="Keeper 수명주기 제어">
                ${!me&&u`
                  <button
                    type="button"
                    class="btn-primary"
                    disabled=${s!==null}
                    onClick=${()=>{Ve("Boot",()=>Yu(t.name))}}
                  >
                    Boot
                  </button>
                `}
                ${me&&(Pe?u`
                      <button
                        type="button"
                        class="btn-primary"
                        disabled=${s!==null}
                        onClick=${()=>{Ve("Resume",()=>Xu(t.name))}}
                      >
                        Resume
                      </button>
                    `:u`
                      <button
                        type="button"
                        class="btn-ghost"
                        disabled=${s!==null}
                        onClick=${()=>{Ve("Pause",()=>Ju(t.name))}}
                      >
                        Pause
                      </button>
                    `)}
                ${t.active_turn!==null&&u`
                  <button
                    type="button"
                    class="btn-ghost"
                    disabled=${s!==null}
                    onClick=${()=>{Ve("Interrupt Turn",()=>Co(t.name),"member")}}
                  >
                    Interrupt Turn
                  </button>
                `}
                <${Or}
                  align="right"
                  triggerLabel="⋯"
                  triggerClassName="btn-ghost"
                  triggerTestId="keeper-actions-menu"
                  popoverTestId="keeper-actions-popover"
                  ariaLabel="Keeper 추가 작업"
                  items=${Ne}
                />
              </div>
            `:u`
              <div class="kp-lifecycle-bar" role="group" aria-label="Keeper 수명주기 제어">
                ${ce&&t.active_turn!==null&&u`
                  <button
                    type="button"
                    class="btn-ghost"
                    disabled=${s!==null}
                    onClick=${()=>{Ve("Interrupt Turn",()=>Co(t.name),"member")}}
                  >
                    Interrupt Turn
                  </button>
                `}
                ${ce&&Ne.length>0&&u`
                  <${Or}
                    align="right"
                    triggerLabel="⋯"
                    triggerClassName="btn-ghost"
                    triggerTestId="keeper-actions-menu"
                    popoverTestId="keeper-actions-popover"
                    ariaLabel="Keeper 추가 작업"
                    items=${Ne}
                  />
                `}
                <span class="kp-pill" data-testid="keeper-lifecycle-admin-locked">수명주기 제어: 관리자 전용</span>
              </div>
            `}
      </div>

      ${j&&u`
        <details
          class="kp-diag-banner"
          open=${ct||void 0}
          data-tone=${ke?"bad":Ue||de?"warn":"info"}
          data-blocking=${ct?"true":"false"}
          role="status"
          aria-label="Keeper 런타임 진단"
        >
          <summary class="kp-diag-summary">
            <span class="kp-diag-summary-text">
              ${ct?"런타임 진단":"진단 이력"} · ${V}
            </span>
            <span class="kp-diag-chevron" aria-hidden="true">▸</span>
          </summary>
          <div class="kp-diag-body">
            ${t.directory_issue&&u`
              <div class="kp-diag-row"><strong>설정 오류</strong>: ${t.directory_issue}</div>
            `}
            ${t.runtime_blocker_summary&&u`
              <div class="kp-diag-row">
                <strong>차단 사유</strong>: ${t.runtime_blocker_summary}
                ${t.runtime_blocker_signature&&u` <span class="kp-roster-sub">(${t.runtime_blocker_signature})</span>`}
                ${t.runtime_blocker_class&&u` <span class="kp-roster-sub">[${t.runtime_blocker_class}]</span>`}
              </div>
            `}
            ${Ue&&t.runtime_path_rest&&u`
              <div class="kp-diag-row">
                <strong>경로 휴식</strong>: ${t.runtime_path_rest.runtime_id??t.runtime_id}
                ${t.runtime_path_rest.release_at?` · 해제 ${t.runtime_path_rest.release_at}`:""}
                ${t.runtime_path_rest.release_basis?` (${t.runtime_path_rest.release_basis})`:""}
              </div>
            `}
            ${(t.last_failure||nt||t.next_action&&(ke||Ue||t.next_action!=="direct_message"))&&u`
              <div class="kp-diag-row">
                ${t.last_failure?`최근 실패: ${t.last_failure.cause}`:""}
                ${nt?`${t.last_failure?" · ":""}조치: ${nt}${t.operator_disposition_reason?` (${t.operator_disposition_reason})`:""}`:""}
                ${t.next_action&&(ke||Ue||t.next_action!=="direct_message")?`${t.last_failure||nt?" · ":""}다음 단계: ${t.next_action}`:""}
              </div>
            `}
            ${Ke&&Ke.count>0&&u`
              <div class="kp-diag-row">
                <strong>대기 항목</strong>: ${Ke.count}건
                ${Ke.due_at?` (가장 이른 예정 ${pa(Ke.due_at)})`:""}
                ${Ke.heads.map((H,Ie)=>u`
                  <div
                    class="kp-diag-lane-meta"
                    key=${Ie}
                    title=${H.next_action?`서버 다음 단계: ${H.next_action}`:void 0}
                  >
                    <span>${H.what}</span>
                    ${H.due_at?u`<span>예정 ${pa(H.due_at)}</span>`:null}
                  </div>
                `)}
              </div>
            `}
            ${tt&&u`
              <div class="kp-diag-row">
                <strong>대기 항목</strong>: 대기 목록을 읽지 못했어요. 대기가 없다는 뜻이 아니에요.
                ${tt.reason?` · ${tt.reason}`:""}
              </div>
            `}
            ${lt.length>0&&u`
              <div class="kp-diag-row">
                <strong>폴백 시도</strong>: ${lt.map(H=>`${H.runtime_id??"lane"}${H.fault_kind?`[${H.fault_kind}]`:""}: ${H.summary}`).join(" → ")}
                <div class="kp-diag-lane-detail">
                  ${lt.map((H,Ie)=>u`
                    <div class="kp-diag-lane" key=${`${H.runtime_id??"lane"}:${H.attempt??Ie}:${H.summary}`}>
                      <span>${H.runtime_id??"lane"}${H.dispatch?` · ${H.dispatch}`:""}${H.attempt!=null?` · attempt ${H.attempt}`:""}${H.fault_kind?` · ${H.fault_kind}`:""}</span>
                      ${H.summary?u`<div>${H.summary}</div>`:null}
                      ${H.failure_kind||H.failure_detail||H.provider||H.network_kind?u`<div class="kp-diag-lane-meta">${H.failure_kind?u`<span>kind:${H.failure_kind}</span>`:null}${H.provider?u`<span>provider:${H.provider}</span>`:null}${H.network_kind?u`<span>network:${H.network_kind}</span>`:null}${H.failure_detail?u`<span>${H.failure_detail}</span>`:null}</div>`:null}
                    </div>
                  `)}
                </div>
              </div>
            `}
            ${de&&u`
              <div class="kp-diag-row"><strong>승인 모드 복구 오류</strong>: ${de}</div>
            `}
            ${ye&&(ye.failed>0||ye.rested>0)&&u`
              <div class="kp-diag-row">
                <strong>24h 턴 내역</strong>: 성공 ${ye.ok} · 휴식 ${ye.rested} · 실패 ${ye.failed}
                <div class="kp-diag-lane-meta">시작 계기: 예약 ${ye.causes.scheduled} · 반응 ${ye.causes.reacted} · 채팅 ${ye.causes.chat} · 스스로 ${ye.causes.own} · 모름 ${ye.causes.unknown}</div>
              </div>
            `}
          </div>
        </details>
      `}

      ${_&&u`
        <div
          class="ap-error"
          data-tone=${_.tone}
          role="alert"
        >
          ${_.text}
        </div>
      `}

      <nav class="kp-tabs" role="tablist" aria-label="Keeper 상세 탭" data-mobile-only="true">
        ${Aa.map(H=>u`
          <button
            key=${H}
            type="button"
            role="tab"
            class="kp-tab"
            aria-selected=${e.activeTab===H?"true":"false"}
            onClick=${()=>e.onSelectTab(H)}
          >
            ${Ca[H]}
          </button>
        `)}
      </nav>

      ${c&&u`
        <div
          ref=${S}
          class="kp-modal-backdrop"
          role="dialog"
          aria-modal="true"
          aria-label="Keeper 영구 삭제 확인"
          onClick=${H=>{H.target===H.currentTarget&&re()}}
        >
          <div class="kp-modal">
            <div class="kp-card-head">
              <h3>Keeper 영구 삭제: ${t.name}</h3>
              <button type="button" class="btn-ghost" onClick=${re}>취소</button>
            </div>
            ${E&&u`<div class="ap-error" role="alert">${E}</div>`}
            <p class="ov-sub">다음 아티팩트가 영구 제거됩니다:</p>
            <ul>
              ${Kd.map(H=>u`<li key=${H}>${H}</li>`)}
            </ul>
            <${Pl}
              target=${{workspaceId:nl.value,keeper:t.name,requestId:`purge:${t.name}`,revision:b??t.phase}}
              currentRevision=${t.phase}
              onRefresh=${()=>l(t.phase)}
            >
              <input
                ref=${M}
                type="text"
                class="kp-input"
                placeholder=${`확인하려면 "${t.name}" 입력`}
                aria-label="삭제 확인 Keeper 이름"
                value=${g}
                onInput=${H=>v(H.currentTarget.value)}
                onKeyDown=${H=>{H.isComposing||H.keyCode===229||H.key==="Enter"&&g.trim()===t.name&&s===null&&(H.preventDefault(),vt())}}
              />
              <button
                type="button"
                class="kp-btn-danger"
                disabled=${g.trim()!==t.name||s!==null}
                onClick=${()=>{vt()}}
              >
                영구 삭제 실행
              </button>
            <//>
          </div>
        </div>
      `}
    </header>
  `}class _a extends ol{state={error:null};static getDerivedStateFromError(t){return{error:t}}reset=()=>{this.setState({error:null})};reload=()=>{typeof window<"u"&&window.location.reload()};componentDidCatch(t,n){console.error(`[ErrorBoundary:${this.props.label??"unknown"}]`,t),this.props.onError?.(t,n)}render(){return this.state.error?this.props.fallback?this.props.fallback(this.state.error,this.reset):(this.props.severity??"fatal")==="recoverable"?u`
          <div
            class="error-card my-3 flex items-start gap-4 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/30 bg-[var(--color-status-warn)]/12 px-3.5 py-3 font-mono shadow-[var(--shadow-1)]"
            style="border-left: 3px solid var(--color-status-warn);"
            role="alert"
          >
            <div class="mt-0.5 shrink-0 text-[var(--color-status-warn)]">
              <${Kl} size=${18} />
            </div>
            <div class="min-w-0 flex-1">
              <h3 class="mb-1 text-xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-status-warn)]">
                recoverable · ${this.props.label??"컴포넌트"}
              </h3>
              <pre class="overflow-x-auto whitespace-pre-wrap rounded-[var(--r-1)] bg-[var(--black-20)] p-2 text-xs text-[var(--color-fg-primary)] opacity-80">${this.state.error.message}</pre>
              <button
                type="button"
                class="mt-3 inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-transparent px-3 py-1 text-xs text-[var(--color-status-warn)] transition-colors hover:bg-[var(--color-status-warn)]/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-status-warn)]"
                onClick=${this.reset}
              >
                <${Gs} size=${12} />
                다시 시도
              </button>
            </div>
          </div>
        `:u`
        <div
          class="error-card my-3 flex items-start gap-4 rounded-[var(--r-1)] border border-[var(--color-status-err)]/40 bg-[var(--color-status-err)]/12 px-3.5 py-3 font-mono shadow-[var(--shadow-1)]"
          style="border-left: 3px solid var(--color-status-err);"
          role="alert"
        >
          <div class="mt-0.5 shrink-0 text-[var(--color-status-err)]">
            <${Nl} size=${18} />
          </div>
          <div class="min-w-0 flex-1">
            <h3 class="mb-1 text-xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-status-err)]">${this.props.label??"Component"} 렌더링 오류</h3>
            <pre class="overflow-x-auto whitespace-pre-wrap rounded-[var(--r-1)] bg-[var(--black-20)] p-2 text-xs text-[var(--color-fg-primary)] opacity-80">${this.state.error.message}</pre>
            <div class="mt-3 flex flex-wrap gap-2">
              <button
                type="button"
                class="inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-1 text-xs text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-status-err)]"
                onClick=${this.reset}
              >
                <${Gs} size=${12} />
                다시 시도
              </button>
              <button
                type="button"
                class="inline-flex cursor-pointer items-center justify-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-status-err)] bg-[var(--color-status-err)] px-3 py-1 text-xs font-semibold text-[var(--color-bg-page)] transition-colors hover:opacity-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--color-status-err)]"
                onClick=${this.reload}
              >
                <${Ml} size=${12} />
                세션 리로드
              </button>
            </div>
          </div>
        </div>
      `:this.props.children}}const Bd=50;function qd(e){const t=[],n=new Map;for(const r of e){const o=`${r.source}\0${r.waiting_on}`,i=n.get(o);i?i.push(r):(n.set(o,[r]),t.push(o))}return t.map(r=>{const o=n.get(r),i=o[0],s=o.flatMap(a=>a.since===null?[]:[a.since]);return{key:r,source:i.source,waitingOn:i.waiting_on,sharedWhat:o.every(a=>a.what===i.what)&&i.what!==""?i.what:null,rows:o,earliestSince:s.length>0?Math.min(...s):null,nextActions:[...new Set(o.map(a=>a.next_action).filter(a=>a!==""))]}})}function fa(e){if(e.sharedWhat!==null)return e.sharedWhat;const t=e.rows.find(n=>n.what!=="")?.what;return t?`${t} 외 ${e.rows.length-1}건`:e.waitingOn}function Fd(e){return e.rows.length<2?[]:e.rows.flatMap((t,n)=>{const r=e.sharedWhat===null?t.what||t.waiting_on:null;return r===null&&t.detail_lines.length===0?[]:[{key:`${n}:${t.what}`,label:r,details:t.detail_lines}]})}function Hd(e,t){return e===null?null:`${fn(Math.max(0,t-e))} 전부터`}function jd(e){const{inventory:t,nowUnix:n}=e,r=qd(t.rows),o=Math.max(t.total_row_count,t.rows.length),i=Math.max(0,o-t.rows.length),s=r.slice(0,3).map(a=>a.sharedWhat!==null?`${a.sharedWhat} ${a.rows.length}건`:fa(a)).join(" · ");return u`
    <details class="kp-waiting-strip" data-testid="chat-waiting-strip">
      <summary class="kp-activity-group-summary">
        <span class="kp-pill" data-tone="warn">대기 ${o}건</span>
        ${t.oldest_age_seconds!==null&&u`
          <span class="kp-pill" title="실제로 기다리는 항목 중 가장 오래된 것의 나이예요. 시각이 안 된 예약은 세지 않아요.">
            가장 오래 ${fn(t.oldest_age_seconds)}
          </span>
        `}
        <span class="kp-block-preview">${s}${r.length>3?` 외 ${r.length-3}종`:""}</span>
      </summary>
      <div
        class="kp-waiting-groups"
        data-testid="chat-waiting-groups"
        role="region"
        aria-label="대기 목록"
        tabIndex=${0}
      >
        ${r.map(a=>{const _=Hd(a.earliestSince,n),f=Fd(a),c=f.slice(0,Bd),k=a.rows.length===1?a.rows[0]:null;return u`
            <div
              key=${a.key}
              class="kp-waiting-group"
              data-waiting-source=${a.source}
              title=${a.nextActions.length>0?`서버 다음 단계: ${a.nextActions.join(", ")}`:void 0}
            >
              <div class="kp-waiting-group-head">
                <span class="kp-pill" data-tone="brass">${lu(a.source)}</span>
                ${(a.sharedWhat!==null||a.rows.length===1)&&u`<span class="kp-waiting-what">${fa(a)}</span>`}
                <span class="kp-waiting-count">${a.rows.length}건</span>
                ${_&&u`<span class="kp-waiting-age">${_}</span>`}
              </div>
              ${k&&k.detail_lines.map((b,l)=>u`
                <div class="kp-block-status" key=${`detail:${l}`}>${b}</div>
              `)}
              ${f.length>0&&u`
                <ul class="kp-waiting-members">
                  ${c.map(b=>u`
                    <li key=${b.key}>
                      ${b.label}
                      ${b.details.map((l,g)=>u`
                        <div class="kp-block-status" key=${`detail:${g}`}>${l}</div>
                      `)}
                    </li>
                  `)}
                  ${f.length>c.length&&u`<li>+ ${f.length-c.length}건 더</li>`}
                </ul>
              `}
            </div>
          `})}
        ${i>0&&u`<div class="kp-block-status">+ 목록에 실리지 않은 ${i}건</div>`}
      </div>
    </details>
  `}const Gd=1500,Wd=8;async function Vd(e,t){const n=await globalThis.crypto?.subtle?.digest("SHA-256",new TextEncoder().encode(JSON.stringify([e,t])));return n?Array.from(new Uint8Array(n),r=>r.toString(16).padStart(2,"0")).join(""):null}function zd(e){try{const t=sessionStorage.getItem(e);if(!t)return null;const n=JSON.parse(t);return!n||typeof n!="object"||!("id"in n)||!gl(n.id)||!("fingerprint"in n)||n.fingerprint!==null&&(typeof n.fingerprint!="string"||!/^[0-9a-f]{64}$/.test(n.fingerprint))?null:{id:n.id,fingerprint:n.fingerprint}}catch{return null}}function Ko(e,t){try{t===null?sessionStorage.removeItem(e):sessionStorage.setItem(e,JSON.stringify({id:t.id,fingerprint:t.fingerprint}))}catch{}}function Qd(e){if(e.state==="sending")return"Discord 전송 중…";if(e.state==="delivered")return"Discord 전송 완료";if(e.state==="outcome_unknown")return"Discord 전송 여부를 확인할 수 없습니다.";if(e.state==="refused")switch(e.reason){case"binding_changed":return"이 대화의 Keeper 바인딩이 바뀌어 전송하지 않았습니다.";case"discord_unconfigured":return"Discord 봇이 설정되지 않아 전송하지 않았습니다.";case"discord_rejected":return"Discord에서 답장을 거부했습니다."}return"Discord 전송 상태를 확인할 수 없습니다."}function Yd({target:e,authority:t,onClose:n}){const r=wt(()=>({authority:t,storageKey:"masc.discord-reply."+JSON.stringify([t.actor,t.workspace.base_path,t.workspace.masc_root,e.keeperName,e.chatId,e.origin.channelId,e.origin.messageId])}),[t,e.keeperName,e.chatId,e.origin.channelId,e.origin.messageId]),[o,i]=F(()=>zd(r.storageKey)),[s,a]=F(""),[_,f]=F(null),[c,k]=F(!1),[b,l]=F(!1),g=X(null),v=X(null),E=X(0);Se(()=>()=>v.current?.abort(),[]),Se(()=>{o||g.current?.focus()},[o]);async function I(z,ce,xe,te=!1){if(v.current||!ie(z.authority.epoch))return;const se=new AbortController,ue=()=>!se.signal.aborted&&ie(z.authority.epoch);v.current=se,k(!0),f(null);try{let Y=ce;if(xe==="send"){if(ce.content===void 0)return;const ke=await Vd(ce.id,ce.content);if(!ue())return;if(ce.fingerprint!==null&&ce.fingerprint!==ke){f("처음 입력한 답장과 내용이 다릅니다.");return}Y={...ce,fingerprint:ke},(te||ce.fingerprint===null)&&Ko(z.storageKey,Y),i(Y)}const de=xe==="send"&&Y.content!==void 0?{kind:"send",content:Y.content}:{kind:"status"},Me=await sc(z.authority.workspace,e,Y.id,de,se.signal);if(!ue())return;if(Me.ok){l(!1),i({...Y,receipt:Me.value}),Me.value.state==="delivered"&&a("");return}const{status:Ce,message:De}=Me.error;te&&Ce!==null&&[400,401,403,409,413,429].includes(Ce)&&(Ko(z.storageKey,null),i(null)),xe==="status"&&Ce===404?(l(!0),f("서버에서 이 작업의 전송 기록을 아직 찾지 못했습니다.")):f(De)}catch(Y){ue()&&f(Y instanceof Error?Y.message:"Discord 전송 결과를 확인할 수 없습니다.")}finally{v.current===se&&(v.current=null,ue()&&k(!1))}}Se(()=>{if(!o||c||_||o.receipt&&o.receipt.state!=="sending"||E.current>=Wd)return;const z=window.setTimeout(()=>{E.current++,I(r,o,"status")},o.receipt?Gd:0);return()=>window.clearTimeout(z)},[r,o,c,_]);const S=()=>{c||v.current||(Ko(r.storageKey,null),E.current=0,i(null),l(!1),f(null))},M=b&&o!==null&&!o.receipt&&o.content===void 0,w=o?.receipt,D=w?.state==="delivered"||w?.state==="refused",re=[...s].length>tc,W=s.trim()!==""&&!re&&!c;return u`
    <form class="kp-discord-reply" aria-label="Discord 답장"
      onSubmit=${z=>{z.preventDefault(),W&&(M&&o?I(r,{...o,content:s},"send"):o||I(r,{id:Cn(),fingerprint:null,content:s},"send",!0))}}>
      <div class="kp-msg-head">
        <a href=${Vs(e.origin,e.origin.messageId)} target="_blank" rel="noopener noreferrer">Discord 원본</a>
        <button type="button" class="btn-ghost" onClick=${n}>닫기</button>
      </div>
      ${(o===null||M)&&u`
        <textarea class="kp-textarea" aria-label="Discord 답장 내용" rows="3" ref=${g}
          value=${s} onInput=${z=>a(z.currentTarget.value)} />
        ${re&&u`<p role="alert">Discord 답장은 2,000자까지 보낼 수 있습니다.</p>`}
        <button class="btn-primary" type="submit" disabled=${!W}>${M?"같은 작업으로 다시 보내기":"Discord로 보내기"}</button>
      `}
      ${o&&u`
        <div role="status">${w?Qd(w):c?"Discord 전송 결과 확인 중…":"Discord 전송 결과를 확인할 수 없습니다."}</div>
        ${w?.state==="delivered"&&u`
          <a href=${Vs(e.origin,w.messageId)} target="_blank" rel="noopener noreferrer">전송한 메시지 열기</a>
        `}
        <div class="kp-pill-row">
          ${D&&u`<button type="button" class="btn-ghost" disabled=${c} onClick=${S}>새 답장</button>`}
          ${!D&&u`<button type="button" class="btn-ghost" disabled=${c}
            onClick=${()=>{I(r,o,"status")}}>결과 확인</button>`}
          ${!w&&_&&o.content!==void 0&&u`
            <button type="button" class="btn-ghost" disabled=${c}
              onClick=${()=>{I(r,o,"send")}}>같은 요청 다시 보내기</button>
          `}
        </div>
      `}
      ${_&&u`<div class="ap-error" role="alert">${_}</div>`}
    </form>
  `}function Ar(e){switch(e){case"Queued":return{delivery:"Queued",detail:null};case"Running":return{delivery:"Pending_processing",detail:null};case"Failed":return{delivery:"Failed",detail:"작업이 실패로 끝났어요."};case"Cancelled":return{delivery:"Failed",detail:"작업이 취소됐어요."};default:return{delivery:"Delivered",detail:null}}}function Jd(e){return{runtimeId:e.attempt.runtime_id,attempt:e.retry.attempt,maxRetries:e.retry.max_retries,delayMs:e.retry.retry_delay_ms,errorStatus:e.retry.error_status}}function Xd(e){const t=Math.max(1,Math.round(e.delayMs/1e3));return[`공급자 재시도 ${e.attempt}/${e.maxRetries}`,e.errorStatus===null?"":`HTTP ${e.errorStatus}`,`${t}초 뒤`,e.runtimeId].filter(n=>n!=="").join(" · ")}function ma(e){const t=e.attemptIndex!==null&&e.attemptIndex>1;return e.runtimeId===null?t?`다시 시도 #${e.attemptIndex}`:null:t?`${e.runtimeId} · 다시 시도 #${e.attemptIndex}`:e.runtimeId}function No(e,t){const n=e??[],r=n[n.length-1];return r&&r.kind===t.kind&&r.text===t.text?n:[...n,t]}function Zd(e){switch(e){case"protocol_error":return"스트림 오류";case"checkpoint":return"체크포인트";case"interrupt":return"끼어들기"}}const vi=16384,hi=16,ep=600,tp=14;function Pr(e){return!Number.isFinite(e)||e<0?"0 B":e<1024?`${Math.round(e)} B`:e<1024*1024?`${(e/1024).toFixed(1)} KB`:`${(e/(1024*1024)).toFixed(2)} MB`}function np(e){if(!e||e.status!=="loaded")return null;const t=e.totalBytes??e.recordedBytes;if(t===void 0)return null;if(e.eof===!1){const n=Math.min(t,Math.max(0,e.nextOffset??0));return`${Pr(n)} / ${Pr(t)}`}return Pr(t)}function rp(e){if(!e)return!1;if(e.length>=ep)return!0;let t=1;for(let n=0;n<e.length;n+=1)if(e.charCodeAt(n)===10&&(t+=1,t>=tp))return!0;return!1}function bi(e,t,n){const r=n?.append===!0;if(t.state==="pending")return r&&e?.status==="loaded"?{...e,loadingMore:!1,loadMoreConflict:!1,loadMoreError:"도구 실행 중 — 결과 준비 대기 중입니다."}:{status:"pending"};if(t.state==="unavailable")return r&&e?.status==="loaded"?{...e,loadingMore:!1,loadMoreConflict:!1,loadMoreError:t.reason}:{status:"unavailable",detail:t.reason};const o=t.encoding==="base64";if(r&&e?.status==="loaded"&&!e.isBinary){if(e.sourceId&&t.sourceId&&e.sourceId!==t.sourceId)return{...e,loadingMore:!1,loadMoreConflict:!0,loadMoreError:"원본 결과가 변경되었습니다. 처음부터 다시 불러오세요."};if(e.nextOffset!==void 0&&t.offset!==e.nextOffset)return{...e,loadingMore:!1,loadMoreConflict:!0,loadMoreError:"페이지 오프셋이 일치하지 않습니다. 처음부터 다시 불러오세요."};if(!t.eof&&t.nextOffset<=t.offset)return{...e,loadingMore:!1,loadMoreConflict:!1,loadMoreError:"추가 페이지 진행이 멈췄습니다."};if(o){const f=e.rawContent??"",c=e.displayContent??f,k=c?`${c}

${t.content}`:t.content;return{status:"loaded",rawContent:f,displayContent:k,isError:t.isError,sourceId:t.sourceId??e.sourceId,offset:t.offset,nextOffset:t.nextOffset,recordedBytes:t.recordedBytes,totalBytes:t.totalBytes,eof:t.eof,encoding:t.encoding,isBinary:!0,pagesLoaded:(e.pagesLoaded??1)+1,loadingMore:!1,loadMoreError:null,loadMoreConflict:!1}}const a=(e.rawContent??"")+t.content,_=t.eof?pn(a):a;return{status:"loaded",rawContent:a,displayContent:_,isError:t.isError,sourceId:t.sourceId??e.sourceId,offset:t.offset,nextOffset:t.nextOffset,recordedBytes:t.recordedBytes,totalBytes:t.totalBytes,eof:t.eof,encoding:t.encoding,isBinary:!1,pagesLoaded:(e.pagesLoaded??1)+1,loadingMore:!1,loadMoreError:null,loadMoreConflict:!1}}const i=t.content,s=o?t.content:t.eof?pn(i):i;return{status:"loaded",rawContent:i,displayContent:s,isError:t.isError,sourceId:t.sourceId,offset:t.offset,nextOffset:t.nextOffset,recordedBytes:t.recordedBytes,totalBytes:t.totalBytes,eof:t.eof,encoding:t.encoding,isBinary:o,pagesLoaded:1,loadingMore:!1,loadMoreError:null,loadMoreConflict:!1}}function yi(e,t,n){const r=t.status===409||t.kind==="conflict_cas";return n?.append&&e?.status==="loaded"?{...e,loadingMore:!1,loadMoreConflict:r,loadMoreError:r?"원본 결과가 변경되었습니다. 처음부터 다시 불러오세요.":t.message}:{status:"error",detail:t.message,sourceChanged:r}}async function op(e){if(typeof navigator<"u"&&navigator.clipboard&&typeof navigator.clipboard.writeText=="function")try{return await navigator.clipboard.writeText(e),!0}catch{}if(typeof document>"u"||!document.body||typeof document.execCommand!="function")return!1;const t=document.createElement("textarea");t.value=e,t.setAttribute("readonly",""),t.className="kp-sr-copy-buffer",document.body.appendChild(t);try{return t.select(),document.execCommand("copy")}catch{return!1}finally{t.remove()}}async function sp(e){const{keeperName:t,executionId:n,maxPages:r,signal:o,isCurrent:i,onUpdate:s}=e;let a=e.initialState;if(a.status!=="loaded"||a.eof||a.isBinary)return a;const _=Math.max(1,Math.min(hi,Math.trunc(r)));if(!a.sourceId){const f={...a,loadingMore:!1,loadMoreConflict:!0,loadMoreError:"원본 결과 식별자(source_id)가 없어 이어 읽을 수 없습니다. 처음부터 다시 불러오세요."};return s(f),f}a={...a,loadingMore:!0,loadMoreError:null,loadMoreConflict:!1},s(a);for(let f=0;f<_;f+=1){if(o.aborted||!i())return a;const c=a.nextOffset??0,k=await oi(t,n,vi,o,{offset:c,sourceId:a.sourceId});if(o.aborted||!i())return a;if(!k.ok)return k.error.kind==="aborted"||k.error.kind==="epoch_stale"||(a=yi(a,k.error,{append:!0}),s(a)),a;const b=bi(a,k.value,{append:!0}),l=f+1<_&&b.status==="loaded"&&!b.eof&&!b.isBinary&&!b.loadMoreError&&!b.loadMoreConflict;if(a=l?{...b,loadingMore:!0}:b,s(a),!l)return a}return a.loadingMore&&(a={...a,loadingMore:!1},s(a)),a}const ap=Oa(async()=>({default:(await On(async()=>{const{KeeperDebugCompanion:e}=await import("./keeper-debug-companion.js");return{KeeperDebugCompanion:e}},__vite__mapDeps([9,1,2,10,11,12,13,14,3,4,5,6,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,7,8]))).KeeperDebugCompanion})),Mo=2*Math.PI*8.5,ip=72,ga=120,lp=1e3;function ka({activities:e,live:t}){const n=fs(t),r=(o,i)=>{const s=bu(o),a=Math.max(0,(n-o.since_unix*1e3)/1e3);return u`
      <li class="kp-open-work-row" key=${i} data-tone=${$u(o)}
        data-leaves-masc=${yu(o)?"true":"false"}>
        <span class="kp-open-work-glyph" aria-hidden="true">${o.kind==="tool"?"▪":"✦"}</span>
        <span class="kp-open-work-phrase">${Qa(o)}</span>
        ${s&&u`<span class="kp-open-work-reach">${s}</span>`}
        ${t&&u`<span class="kp-turn-elapsed kp-open-work-elapsed">${fn(a)}</span>`}
      </li>
    `};return u`
    <ul class="kp-open-work" data-testid="chat-open-work" aria-label="진행 중인 일">
      ${gu(e).map((o,i)=>o.kind==="single"?r(o.activity,`s${i}`):u`
          <li class="kp-open-work-batch" key=${`b${i}`}>
            <span class="kp-open-work-batch-head">
              ${o.members.length<o.batchSize?`동시 실행 ${o.members.length}/${o.batchSize}개 진행 중`:`동시 실행 ${o.members.length}개`}
            </span>
            <ul class="kp-open-work">
              ${o.members.map((s,a)=>r(s,`b${i}:${a}`))}
            </ul>
          </li>
        `)}
    </ul>
  `}function Lo(e){if(!Number.isFinite(e)||e<=0)return null;const t=e<1e12?e*1e3:e,n=new Date(t);if(Number.isNaN(n.getTime()))return null;const r=String(n.getHours()).padStart(2,"0"),o=String(n.getMinutes()).padStart(2,"0");return`${r}:${o}`}function cp(e,t,n,r){if(e.role==="user"){const o=e.speakerName??e.speakerId??null;return e.speakerAuthority==="keeper"?`Keeper · ${o??"keeper"}`:e.speakerAuthority==="external"?o?`${o} (외부)`:"외부 발신자":e.speakerAuthority==="owner"?o&&o.toLowerCase()!=="operator"?`Operator (${o})`:"Operator":o??e.speakerLabel??"사용자"}return n!==null?`${t} · Autonomous Turn`:r?`${t} · Memory Recall`:e.toolName?`Tool · ${e.toolName}`:t}function up(e){switch(e){case"Queued":case"Pending_processing":return"warn";case"Sending":case"Confirming_delivery":return"info";case"Streaming":return"brass";case"Delivered":case"Cut_recovered":return"ok";case"Failed":return"bad";default:return}}const dp=50,pp=4096,_p=100,fp=200;function mp(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function Do(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}function Cr(e,t){if(t<=e.evictedSeqWatermark||e.seenSeqs.has(t))return!1;for(e.seenSeqs.add(t);e.seenSeqs.size>pp;){const n=e.seenSeqs.values().next().value;if(n===void 0)break;e.seenSeqs.delete(n),n>e.evictedSeqWatermark&&(e.evictedSeqWatermark=n)}return!0}function gp(e,t,n){for(e.has(t)&&e.delete(t),e.add(t);e.size>n;){const r=e.values().next().value;if(r===void 0)break;e.delete(r)}}function Uo(e,t,n){for(e.set(t,n);e.size>_p;){let r;for(const[o,i]of e)if(o!==t&&(i.terminal||i.shadowed)){r=o;break}if(r===void 0){for(const o of e.keys())if(o!==t){r=o;break}}if(r===void 0)break;e.delete(r)}}function Xn(e,t){return au(e,t)?!0:e.some(n=>n.role==="assistant"&&(n.operationId===t||n.replyOperationId===t)&&(n.deliveryState==="Delivered"||n.deliveryState==="Cut_recovered"))}function kp(e){const t=e.attachments??[],n=(e.retainedImages??[]).map(r=>Hr({t:"image",src:r.path,cap:r.caption})).filter(r=>r!==null);return t.length===0?n:n.length===0?t:Ot([...t,...n])}function va(e){const t=Array.from(e.values()).filter(n=>n.length>0);return t.length>0?t.join(`

`):void 0}function ha(e,t,n){const r={...e};delete r[t],r[t]=n;const o=Object.keys(r);for(;o.length>dp;){const i=o.shift();i&&delete r[i]}return r}function vp(e){const{keeper:t}=e,[n,r]=F(()=>({keeperName:t.name,entries:[]})),o=X(n);o.current=n;const i=n.keeperName!==t.name,s=i?[]:n.entries,[a,_]=F(null),[f,c]=F(!1),[k,b]=F(!0),[l,g]=F(null),[v,E]=F(null),I=v?.keeperName===t.name&&ie(v.epoch)?v:null,S=I?.operations??[],[M,w]=F(""),D=X(""),re=be(p=>{w(m=>{const h=typeof p=="function"?p(m):p;return D.current=h,h})},[]),[W,z]=F(null),ce=X(null),xe=_e.value,te=Jt.value,se=yt(xe),[ue,Y]=F(null),de=s.some(p=>p.discordReplyOrigin),Me=xe.kind==="single_user_local"&&se&&xe.tokenPresent,Ce=Me&&ue?.epoch===te?ue:null;Se(()=>{if(!Me||!de)return;let p=!0;return nc().then(m=>{m&&p&&ie(te)&&Y({...m,epoch:te})}),()=>{p=!1}},[te,Me,de]);const[De,ke]=F([]),me=X([]),Pe=be(p=>{ke(m=>{const h=typeof p=="function"?p(m):p;return me.current=h,h})},[]),Ue=be(()=>{Fs(me.current),me.current=[],ke([])},[]);Se(()=>()=>Fs(me.current),[]);const[pe,Et]=F(!1),[tt,Ke]=F(!1),[lt,ye]=F(!1),[nt,ct]=F(t.chat_control_token),[j,A]=F(!1),[V,ne]=F(()=>zc()),le=be(p=>{const m=Wn.current,h=p(m);Wn.current=h,Qc(h),ne(h),h.tools!==m.tools&&(hn.current.clear(),Ft.current={},Xe.current.clear(),zr({})),h.thinking!==m.thinking&&Qr({})},[]),[ae,Ne]=F({status:"idle",prompt:"",reply:"",error:null}),[Ve,vt]=F(!1),[H,Ie]=F(""),[je,pt]=F(ga),[mn,Kn]=F(!0),[Nn,dr]=F(0),[Vr,gs]=F({}),[ht,zr]=F({}),[Pi,Qr]=F({}),[Ki,ks]=F({}),[Ni,Yr]=F(null),[Jr,Xr]=F(null),[Mi,pr]=F([]),[Li,vs]=F(),[gn,Zr]=F(null),Mn=X(null),hs=X(null),eo=X(null),bs=X(null),ys=X(null),_r=X(null),Ln=X(null),Dn=X(!1),Un=X(!1),kn=X(0),tn=X(null),nn=X(new Map),Bn=X(new Set),Tt=X(()=>{}),to=X(()=>{}),qn=X(!0),Fn=X(!0),fr=X(null),no=X(""),ze=X(!0),Je=X(t.name),rt=e.turnSnapshot,$s=X(rt);$s.current=rt;const Hn=X(null),rn=rt?.kind==="value"?rt.data.get(t.name):void 0;let Pt=Hn.current?.keeper===t.name&&ie(Hn.current.epoch)?Hn.current:null;if(rt?.kind==="value"&&rn?.status==="ok"&&(!rt.stale||!Pt)){const p=Pt?.retiredOwners??new Set,m=Pt?.active?.owner_key,h=rn.active?.owner_key;!rt.stale&&m&&(rn.active===null||h&&h!==m)&&p.add(m),Pt={keeper:t.name,epoch:Te(),active:rn.active,updatedAt:rt.updatedAt,retiredOwners:p},Hn.current=Pt}const ot=rt?Pt?.active??null:t.active_turn,Es=X(ot?.owner_key);Es.current=ot?.owner_key;const jn=be(()=>{vs($s.current),pr(p=>p.some(m=>m.live)?p.map(m=>({...m,live:!1})):p)},[]);Bs(()=>{(rt?.kind==="failed"||rt?.kind==="absent"||rt?.kind==="value"&&rn?.status!=="ok")&&jn()},[rt,rn,jn]);const Gn=X(!1),vn=X(null),ro=X(0),Kt=X(new Set),ut=X(new Map),on=X(Vr);on.current=Vr;const Ft=X(ht);Ft.current=ht;const Wn=X(V);Wn.current=V;const hn=X(new Set),Xe=X(new Map),St=X(null),bn=be((p,m)=>{on.current=ha(on.current,p,m),gs(h=>{const y=ha(h,p,m);return on.current=y,y})},[]),yn=be(()=>{on.current={},gs({})},[]),mr=be(()=>{hn.current.clear(),Xe.current.clear(),Ft.current={},zr({}),Qr({}),ks({}),Yr(null),St.current&&(clearTimeout(St.current),St.current=null)},[]),sn=be((p,m,h)=>{const y=h?.trim()||"",T=y?`exec:${y}`:"",K=Ft.current;if(K[p]!==m||T&&K[T]!==m){const N={...K,[p]:m};T&&(N[T]=m),Ft.current=N}zr(N=>{if(N[p]===m&&(!T||N[T]===m))return N;const $={...N,[p]:m};return T&&($[T]=m),Ft.current=$,$})},[]),Di=be(async(p,m)=>{!await op(m)||!ze.current||(Yr(p),St.current&&clearTimeout(St.current),St.current=setTimeout(()=>{St.current=null,ze.current&&Yr(null)},1500))},[]),$n=be((p="auto")=>{const m=Mn.current;m&&(qn.current=!0,Kn(!0),dr(0),p==="auto"||typeof m.scrollTo!="function"?m.scrollTop=m.scrollHeight:m.scrollTo({top:m.scrollHeight,behavior:p}))},[]);Se(()=>{const p=hs.current;if(!p||typeof ResizeObserver>"u")return;const m=new ResizeObserver(()=>{qn.current&&$n()});return m.observe(p),()=>m.disconnect()},[$n]);const Ui=be(()=>{const p=Mn.current;if(!p)return;const h=p.scrollHeight-p.scrollTop-p.clientHeight<=ip;qn.current=h,Kn(h),h&&dr(0)},[]),Ht=be(()=>{for(const p of ut.current.values())p.abort();ut.current.clear()},[]),xt=be(()=>{ro.current+=1,vn.current?.abort(),vn.current=null},[]);Se(()=>(ze.current=!0,()=>{ze.current=!1,xt(),Ht(),St.current&&(clearTimeout(St.current),St.current=null)}),[Ht,xt]),Se(()=>{const p=Je.current!==t.name;Je.current=t.name,qn.current=!0,Fn.current=!0,fr.current=null,pt(ga),Kn(!0),dr(0),Gn.current=!1,xt(),Ht(),Kt.current.clear(),yn(),mr(),Xr(null),pr([]),vs(void 0),Zr(null),p&&(r({keeperName:t.name,entries:[]}),c(!1),_(null),E(null))},[t.name,Ht,xt,yn,mr]),Se(()=>{let p=Te();return Jt.subscribe(m=>{m!==p&&(p=m,Gn.current=!1,xt(),_r.current?.abort("session_epoch_changed"),Ln.current?.abort("session_epoch_changed"),Ht(),Kt.current.clear(),yn(),mr())})},[Ht,xt,yn,mr]),Se(()=>{se||(Ht(),Kt.current.clear(),yn())},[se,Ht,yn]);const Rt=be(async(p,m=!1)=>{if(!yt(_e.peek()))return;const h=p.trim();if(!h||!m&&(Kt.current.has(h)||ut.current.has(h)))return;m&&(ut.current.get(h)?.abort(),ut.current.delete(h)),Kt.current.add(h);const y=t.name,T=Te(),K=new AbortController;ut.current.set(h,K),bn(h,{status:"loading"});try{const N=await oi(y,h,vi,K.signal);if(!ze.current||Je.current!==y||!ie(T)||!yt(_e.peek())||ut.current.get(h)!==K||K.signal.aborted){ut.current.get(h)===K&&Kt.current.delete(h);return}if(!N.ok){if(Kt.current.delete(h),N.error.kind==="epoch_stale"||N.error.kind==="aborted")return;bn(h,yi(void 0,N.error));return}const $=N.value;$.state==="pending"&&Kt.current.delete(h),bn(h,bi(void 0,$))}finally{ut.current.get(h)===K&&ut.current.delete(h)}},[t.name,bn]),oo=be(async(p,m)=>{if(!yt(_e.peek()))return;const h=p.trim();if(!h||ut.current.has(h))return;const y=on.current[h];if(!y||y.status!=="loaded"||y.eof||y.isBinary)return;const T=t.name,K=Te(),N=new AbortController;ut.current.set(h,N);const $=()=>ze.current&&Je.current===T&&ie(K)&&yt(_e.peek())&&ut.current.get(h)===N&&!N.signal.aborted;try{await sp({keeperName:T,executionId:h,initialState:y,maxPages:m,signal:N.signal,isCurrent:$,onUpdate:L=>{$()&&bn(h,L)}})}finally{ut.current.get(h)===N&&ut.current.delete(h)}},[t.name,bn]);Se(()=>{ct(t.chat_control_token)},[t.chat_control_token]);const Be=be((p,m)=>{const h=t.name;r(y=>y.keeperName!==h||!y.entries.some(T=>T.id===p)?y:{keeperName:y.keeperName,entries:y.entries.map(T=>T.id===p?m(T):T)})},[t.name]),_t=Be,so=be(p=>{gp(Bn.current,p,fp)},[]),Ts=be((p,m)=>{const h=t.name,y=[];for(const T of nn.current.values())T.operationId===m||T.shadowed||(T.operationId===p||T.executionId===p)&&(T.shadowed=!0,T.terminal=!0,T.entryCreated&&y.push(T.assistantId));if(y.length>0){const T=new Set(y);r(K=>K.keeperName!==h||!K.entries.some(N=>T.has(N.id))?K:{keeperName:K.keeperName,entries:K.entries.filter(N=>!T.has(N.id))})}},[t.name]),ao=be(p=>{const{assistantId:m,userId:h,updateAssistant:y,updateExistingAssistant:T}=p;let K=p.initialAcceptedByServer;const N=new Map;let $=[];const L=R=>R==="Failed"||R==="Delivered"?R:"Streaming",Q=()=>{K=!0,p.onServerAccepted?.(),Be(h,R=>R.deliveryState==="Delivered"?R:{...R,deliveryState:"Delivered"})};return{onBatchBound:p.onBatchBound,onAccepted:R=>{K=!0,p.onServerAccepted?.(),R.controlToken&&ct(R.controlToken);const P=Ar(R.state),O=R.interruptProblem;Be(h,B=>({...B,deliveryState:R.state==="Queued"?"Queued":"Delivered"})),T(B=>({...B,deliveryState:P.delivery,errorDetail:P.detail??B.errorDetail,streamNotices:O===null?B.streamNotices:No(B.streamNotices,{kind:"interrupt",text:O})}))},onRunStarted:()=>{Q(),y(R=>({...R,deliveryState:"Pending_processing"}),"Pending_processing")},onAttemptStarted:R=>{Q(),N.clear(),$=[],y(P=>({...P,content:"",thinking:void 0,toolCalls:void 0,attachments:void 0,retainedImages:void 0,providerRetry:void 0,runtimeAttempt:R??P.runtimeAttempt,deliveryState:"Streaming"}),"Streaming")},onProviderRetry:R=>{const P=Jd(R);y(O=>O.content===""?{...O,providerRetry:P,deliveryState:L(O.deliveryState)}:O,"Streaming")},onStreamProtocolError:({message:R,quarantinedStreamKey:P})=>{P!==void 0&&($=$.map(B=>B.streamKey===P?{...B,status:"error"}:B));const O=$;y(B=>({...B,toolCalls:P===void 0?B.toolCalls:O,streamNotices:No(B.streamNotices,{kind:"protocol_error",text:R})}),"Streaming")},onContinuationCheckpoint:R=>{y(P=>({...P,streamNotices:No(P.streamNotices,{kind:"checkpoint",text:R??"턴이 체크포인트에서 멈췄고 이어서 진행해요."})}),"Streaming")},onModelActivity:()=>{Q(),y(R=>({...R,deliveryState:L(R.deliveryState)}),"Streaming")},onTextDelta:R=>{Q(),y(P=>({...P,content:P.content+R,providerRetry:void 0,deliveryState:"Streaming"}),"Streaming")},onThinkingDelta:(R,P="0:0:0")=>{Q(),N.set(P,(N.get(P)??"")+R);const O=va(N);y(B=>({...B,thinking:O,deliveryState:L(B.deliveryState)}),"Streaming")},onAttachment:R=>{if(Q(),R.role==="user"){Be(h,O=>({...O,attachments:Ot([...O.attachments??[],R.attachment])}));return}R.toolCallId&&($=kt($,{toolCallId:R.toolCallId},O=>({...O,attachments:Ot([...O.attachments??[],R.attachment])})));const P=$;y(O=>({...O,attachments:Ot([...O.attachments??[],R.attachment]),toolCalls:R.toolCallId&&P.length>0?P:O.toolCalls,deliveryState:L(O.deliveryState)}),"Streaming")},onRetainedImages:R=>{R.length>0&&Q(),y(P=>({...P,retainedImages:R,deliveryState:R.length>0?L(P.deliveryState):P.deliveryState}),"Streaming")},onThinkingSnapshot:(R,P="0:0:0")=>{Q(),N.set(P,R);const O=va(N);y(B=>({...B,thinking:O,deliveryState:L(B.deliveryState)}),"Streaming")},onToolStart:(R,P,O)=>{$=kt($,{toolCallId:P,streamKey:O},q=>({...q,id:P??q.id,streamKey:q.streamKey??O,name:R||q.name,status:"running"}),()=>({id:P,streamKey:O,name:R,status:"running"}));const B=$;y(q=>({...q,deliveryState:L(q.deliveryState),toolCalls:B}),"Streaming")},onToolAdmitted:(R,P,O)=>{const B=zo($,{toolCallId:P,streamKey:O}),q=B>=0?$[B].streamKey:void 0;if($=kt($,{toolCallId:P,streamKey:O},G=>({...G,id:P??G.id,streamKey:G.streamKey??O,name:R})),B>=0&&!q&&O){const G=`${m}:tool:${B}`,ge=`${m}:tool:${O}`,oe=Ft.current[G];oe!==void 0&&sn(ge,oe)}const J=$;y(G=>({...G,toolCalls:J}),"Streaming")},onToolArgsDelta:(R,P,O)=>{$=kt($,{toolCallId:R,streamKey:O},q=>({...q,args:(q.args??"")+P}));const B=$;y(q=>({...q,deliveryState:L(q.deliveryState),toolCalls:B}),"Streaming")},onToolArgsSnapshot:(R,P,O)=>{$=kt($,{toolCallId:R,streamKey:O},q=>({...q,args:P}));const B=$;y(q=>({...q,deliveryState:L(q.deliveryState),toolCalls:B}),"Streaming")},onToolEnd:(R,P)=>{$=kt($,{toolCallId:R,streamKey:P},B=>({...B,status:B.status==="running"?"awaiting_result":B.status}));const O=$;y(B=>({...B,toolCalls:O}),"Streaming")},onToolResultReady:({executionId:R,toolCallId:P,streamKey:O,isError:B})=>{const q=B===!0?"error":B===!1?"completed":"result_ready";$=kt($,{toolCallId:P,streamKey:O},$e=>({...$e,executionId:R,status:$e.status==="error"?"error":q}),()=>({id:P,streamKey:O,executionId:R,name:"tool",status:q}));const J=zo($,{toolCallId:P,streamKey:O}),G=J>=0?J:Math.max(0,$.length-1),ge=$[G],oe=`${m}:tool:${ge?.streamKey??G}`,U=Ft.current[oe],ee=U!==void 0?U:Wn.current.tools==="full";U!==void 0&&sn(oe,U,R);const Re=$;y($e=>({...$e,toolCalls:Re}),"Streaming"),yt(_e.peek())&&Wn.current.tools!=="hidden"&&ee&&!ge?.result&&Rt(R)},onToolResult:(R,P,O)=>{$=kt($,{toolCallId:R,streamKey:O},q=>({...q,result:P,status:q.status==="error"?"error":"completed"}),()=>({id:R||void 0,streamKey:O,name:"tool",result:P,status:"completed"}));const B=$;y(q=>({...q,toolCalls:B}),"Streaming")},onNativeToolProgress:({toolName:R,toolCallId:P,streamKey:O,progressLabel:B})=>{$=kt($,{toolCallId:P,streamKey:O},J=>({...J,name:R??J.name,progressLabel:B}),()=>({id:P,streamKey:O,name:R??"native_tool",status:"running",progressLabel:B}));const q=$;y(J=>({...J,deliveryState:L(J.deliveryState),toolCalls:q}),"Streaming")},onNativeToolEnd:({toolName:R,toolCallId:P,streamKey:O,status:B,summary:q})=>{$=kt($,{toolCallId:P,streamKey:O},G=>({...G,name:R??G.name,status:B,progressLabel:q??G.progressLabel}),()=>({id:P,streamKey:O,name:R??"native_tool",status:B,progressLabel:q}));const J=$;y(G=>({...G,toolCalls:J}),"Streaming")},onToolApprovalRequested:({toolCallId:R,toolName:P,args:O,question:B,because:q})=>{const J=B??q??"운영자 승인 대기 중",G=R.trim(),ge=G?{toolCallId:G}:{streamKey:`approval:${Cn()}`};$=kt($,ge,U=>({...U,name:P||U.name,args:O??U.args,status:"awaiting_approval",progressLabel:J}),()=>({id:G||void 0,streamKey:ge.streamKey,name:P,args:O,status:"awaiting_approval",progressLabel:J}));const oe=$;y(U=>({...U,deliveryState:L(U.deliveryState),toolCalls:oe}),"Streaming")},onToolApprovalSettled:({toolCallId:R,toolName:P,outcome:O})=>{const B=O.trim().toLowerCase(),q=B==="approve"||B==="remembered_approve",J=R.trim();if(J)$=kt($,{toolCallId:J},ge=>({...ge,status:q?"running":"error",progressLabel:O}));else{const ge=[...$];let oe=-1;for(let U=ge.length-1;U>=0;U-=1){const ee=ge[U];if(ee.status==="awaiting_approval"){if(!P||ee.name===P){oe=U;break}oe<0&&(oe=U)}}oe>=0&&(ge[oe]={...ge[oe],status:q?"running":"error",progressLabel:O},$=ge)}const G=$;y(ge=>({...ge,toolCalls:G.length>0?G:ge.toolCalls}),"Streaming")},onReplyDetails:(R,P,O)=>{Q();const B=O==="external_effect_completed"||O==="no_visible_reply";y(q=>({...q,content:B?q.content:R||q.content,turnRef:P??q.turnRef}),"Streaming")},onError:R=>{const P=B=>B.status==="running"||B.status==="awaiting_result"||B.status==="awaiting_approval"?{...B,status:"error"}:B;$=$.map(P);const O=$.length>0?$:void 0;Be(h,B=>({...B,deliveryState:K?"Delivered":"Failed"})),y(B=>({...B,deliveryState:"Failed",errorDetail:R,toolCalls:O??B.toolCalls?.map(P)}),"Failed")},onFinished:()=>{Q();const R=O=>O.status==="running"||O.status==="awaiting_result"||O.status==="awaiting_approval"?{...O,status:O.executionId||O.result!==void 0?"completed":"interrupted"}:O;$=$.map(R);const P=$.length>0?$:void 0;T(O=>({...O,deliveryState:O.deliveryState==="Failed"?"Failed":"Delivered",toolCalls:P??O.toolCalls?.map(R)}))}}},[Be,sn,Rt]);Se(()=>{let p=!1,m=!1,h=0;const y=new Set,T=new Map;nn.current.clear(),Bn.current.clear();const K=()=>{for(const oe of T.values())oe.abort();T.clear(),y.clear()},N=(...oe)=>{if(!p){for(const U of oe)y.add(U);if(oe.includes("queue")){const U=Te();E(ee=>{const Re=ee?.keeperName===t.name&&ee.epoch===U;return Re&&ee.kind==="ready"?{...ee,refreshing:!0}:{keeperName:t.name,epoch:U,kind:"loading",operations:Re?ee.operations:[]}})}m||(m=!0,queueMicrotask(()=>{if(m=!1,!p)for(const U of y){if(T.has(U))continue;y.delete(U);const ee=new AbortController;T.set(U,ee);const Re=ee.signal,$e=Te(),he=()=>!Re.aborted&&Je.current===t.name&&ie($e);$(U,Re,$e,he).finally(()=>{he()&&(T.delete(U),y.has(U)&&N())})}}))}},$=async(oe,U,ee,Re)=>{switch(oe){case"history":{const $e=++h,he=await aa(t.name,void 0,40,U);if(!Re())return;if(b(!1),g(he.ok?null:he.error.message),he.ok){const bt=he.value.messages.length===0;bt&&(xt(),Gn.current=!1);const Wt=new Set;for(const mt of nn.current.values())mt.terminal&&mt.completedAtHistorySeq!==null&&$e>mt.completedAtHistorySeq&&Wt.add(mt.operationId);r(mt=>({keeperName:t.name,entries:iu(mt.keeperName===t.name?mt.entries:[],he.value.messages,tn.current,Wt.size>0?Wt:void 0)})),(bt||!Gn.current)&&(c(bt?!1:he.value.hasMore),_(bt?null:he.value.nextCursor))}return}case"queue":{const $e=await Io(t.name,U);if(!Re())return;const he=y.has("queue");if($e.ok)E({keeperName:t.name,epoch:ee,kind:"ready",refreshing:he,operations:$e.value});else{const{kind:bt,message:Wt}=$e.error,mt=bt==="unauthorized"||bt==="forbidden"||bt==="epoch_stale";E(ln=>{const Lt=!mt&&ln?.keeperName===t.name&&ln.epoch===ee,Ds=Lt?ln.operations:[],cn={keeperName:t.name,epoch:ee,operations:Ds};return he?Lt&&ln.kind==="ready"?{...cn,kind:"ready",refreshing:!0}:{...cn,kind:"loading"}:{...cn,kind:"error",message:Wt}})}return}case"waiting":{const $e=await od(t.name,U);Re()&&$e.ok&&Xr($e.value);return}}},L=()=>{K(),xt(),jn(),N("history","queue","waiting")};Tt.current=N,to.current=()=>{T.get("queue")?.abort(),T.delete("queue"),N("queue")};const Q=oe=>{if(Bn.current.has(oe))return!0;const U=tn.current;return Dn.current&&U!==null&&(U.operationId===oe||U.executionId===oe)},R=(oe,U)=>{for(const ee of nn.current.values())if(!(ee.operationId===U||ee.shadowed)&&(ee.operationId===oe||ee.executionId===oe))return!0;return!1},P=oe=>{if(p||Je.current!==t.name)return;const{operationId:U,seq:ee,agUiEvent:Re}=oe;if(Q(U))return;const $e=nn.current;let he=$e.get(U);if(he){if(he.shadowed||he.terminal||ee!==null&&!Cr(he,ee))return}else{const Wt=o.current.keeperName===t.name?o.current.entries:[];if(Xn(Wt,U))return;const mt=Do(Re.type),ln=mt==="CUSTOM"?Do(Re.name):null,Lt=mt==="CUSTOM"&&mp(Re.value)?Re.value:null;if(mt==="RUN_FINISHED"||ln==="KEEPER_CHAT_OPERATION_ACCEPTED"&&Lt!==null&&(Lt.state==="Succeeded"||Lt.state==="Failed"||Lt.state==="Cancelled")){const dt={operationId:U,executionId:U,assistantId:`obs-asst-${U}`,dispatcher:null,seenSeqs:new Set,evictedSeqWatermark:-1,entryCreated:!1,terminal:!0,completedAtHistorySeq:h,shadowed:!1};ee!==null&&Cr(dt,ee),Uo($e,U,dt),N("history","queue","waiting");return}if(ln==="KEEPER_CHAT_BATCH_BOUND"&&Lt){const dt=Do(Lt.execution_id);if(dt&&(Q(dt)||R(dt,U)||Xn(Wt,dt))){const At={operationId:U,executionId:dt,assistantId:`obs-asst-${U}`,dispatcher:null,seenSeqs:new Set,evictedSeqWatermark:-1,entryCreated:!1,terminal:!0,completedAtHistorySeq:h,shadowed:!0};ee!==null&&Cr(At,ee),Uo($e,U,At);return}}const cn=t.name,$o=Te(),Dt=`obs-asst-${U}`,Ji=`user-${U}`,Ze={operationId:U,executionId:U,assistantId:Dt,dispatcher:null,seenSeqs:new Set,evictedSeqWatermark:-1,entryCreated:!1,terminal:!1,completedAtHistorySeq:null,shadowed:!1},Xi=ci({operationId:U,startEpoch:$o,callbacks:ao({assistantId:Dt,userId:Ji,initialAcceptedByServer:!0,updateAssistant:(dt,At="Streaming")=>{p||Ze.shadowed||!ie($o)||r(Ge=>{if(Ge.keeperName!==cn)return Ge;if(Ge.entries.some(zn=>zn.id===Dt))return{keeperName:Ge.keeperName,entries:Ge.entries.map(zn=>zn.id===Dt?dt(zn):zn)};if(Ze.entryCreated)return Ge;if(Xn(Ge.entries,U)||Ze.executionId!==U&&Xn(Ge.entries,Ze.executionId))return Ze.terminal=!0,Ge;Ze.entryCreated=!0;const Zi={id:Dt,role:"assistant",content:"",ts:Date.now()/1e3,operationId:U,replyOperationId:Ze.executionId!==U?Ze.executionId:void 0,deliveryState:At};return{keeperName:Ge.keeperName,entries:[...Ge.entries,dt(Zi)]}})},updateExistingAssistant:dt=>{p||Ze.shadowed||!ie($o)||Be(Dt,dt)},onBatchBound:(dt,At)=>{if(!(dt!==U||Ze.shadowed)){if(Q(At)||R(At,U)||Xn(o.current.keeperName===cn?o.current.entries:[],At)){Ze.shadowed=!0,Ze.terminal=!0,Ze.entryCreated&&r(Ge=>Ge.keeperName!==cn||!Ge.entries.some(Tr=>Tr.id===Dt)?Ge:{keeperName:Ge.keeperName,entries:Ge.entries.filter(Tr=>Tr.id!==Dt)});return}Ze.executionId=At,Ze.entryCreated&&Be(Dt,Ge=>({...Ge,replyOperationId:At}))}}})});Ze.dispatcher=Xi,he=Ze,ee!==null&&Cr(he,ee),Uo($e,U,he)}if(!he.dispatcher||he.shadowed||he.terminal)return;he.dispatcher.dispatch(Re).terminal&&!he.shadowed&&(he.terminal=!0,he.completedAtHistorySeq=h,N("history","queue","waiting"))},O=sr(oe=>{const U=ri(oe.event,oe.data,t.name);switch(U?.kind){case"turn_preview":{if(!U.ownerKey)break;const ee={ownerKey:U.ownerKey,preview:U.preview,receivedAt:Date.now(),live:!0},Re=Es.current,$e=Hn.current,he=$e?.keeper===t.name&&ie($e.epoch)?$e.retiredOwners:void 0;pr(bt=>_i(bt,Re,ee,he));break}case"turn_changed":jn();break;case"turn_succeeded":Zr(ee=>ee&&ee.atUnix>=U.atUnix?ee:U);break;case"chat_appended":N("history");break;case"waiting_changed":N("waiting"),U.queueChanged&&N("queue");break;case"chat_operation_event":P(U);break}}),B=as(L);let q=tr.peek();const J=tr.subscribe(oe=>{oe&&!q&&L(),q=oe});let G=Te();const ge=Jt.subscribe(oe=>{oe!==G&&(G=oe,nn.current.clear(),Bn.current.clear(),r({keeperName:t.name,entries:[]}),E(null),c(!1),_(null),Xr(null),Zr(null),pr([]),g(null),b(!0),Ln.current?.abort(),vt(!1),Ne({status:"idle",prompt:"",reply:"",error:null}),L())});return b(!0),g(null),N("history","queue","waiting"),()=>{p=!0,K(),xt(),O(),B(),J(),ge(),nn.current.clear(),Bn.current.clear(),Tt.current=()=>{},to.current=()=>{},kn.current+=1,Dn.current=!1,tn.current=null,Un.current=!1,_r.current?.abort(),Ln.current?.abort()}},[t.name,xt,jn,Be,ao]);const io=async(p,m)=>{if(I?.kind!=="ready"||I.refreshing===!0||!ie(I.epoch)||Je.current!==t.name)return;const h=t.name,y=I.epoch,T=await m(h,p);if(!(!ze.current||Je.current!==h||!ie(y))){if(!T.ok){g(`대기열 작업 실패: ${T.error.message}`);return}Tt.current("queue","waiting")}};Se(()=>{const p=m=>{if(!(m.defaultPrevented||m.isComposing||m.keyCode===229)&&!(typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]'))){if((m.metaKey||m.ctrlKey)&&!m.altKey&&m.key==="."){m.preventDefault(),A(h=>!h);return}m.altKey&&!m.metaKey&&!m.ctrlKey&&!m.shiftKey&&(m.code==="KeyT"||m.key.toLowerCase()==="t")&&(m.preventDefault(),le(h=>({...h,thinking:Js(h.thinking)})))}};return window.addEventListener("keydown",p),()=>window.removeEventListener("keydown",p)},[le]);const Bi=async()=>{if(!a||k)return;const p=t.name,m=Te();vn.current?.abort();const h=new AbortController;vn.current=h;const y=++ro.current;b(!0);const T=await aa(p,a,40,h.signal);if(!ze.current||Je.current!==p||!ie(m)||h.signal.aborted||y!==ro.current)return;if(vn.current===h&&(vn.current=null),b(!1),!T.ok){T.error.kind!=="epoch_stale"&&T.error.kind!=="aborted"&&g(T.error.message);return}const K=Mn.current;K&&(fr.current={prevScrollHeight:K.scrollHeight,prevScrollTop:K.scrollTop}),pt(N=>Math.min(lp,N+T.value.messages.length)),Gn.current=!0,r(N=>{const $=N.keeperName===p?N.entries:[],L=new Set($.map(R=>R.id)),Q=T.value.messages.filter(R=>!L.has(R.id));return{keeperName:p,entries:[...Dr([...Q,...$])]}}),c(T.value.hasMore),_(T.value.nextCursor)},lo=async(p,m,h)=>{if(!h?.unconfirmedAcceptance&&!yt(_e.peek())){_t(p,$=>({...$,cutStream:!1,deliveryState:$.content?"Delivered":"Failed",errorDetail:$.content?void 0:"스트림이 중단되었습니다. 대화 이력을 새로고침했습니다."})),Tt.current("history","queue","waiting");return}const y=t.name,T=Te(),K=()=>ze.current&&Je.current===y&&ie(T);h?.unconfirmedAcceptance&&h.userId&&Be(h.userId,$=>({...$,deliveryState:"Confirming_delivery"})),_t(p,$=>({...$,deliveryState:"Confirming_delivery"}));const N=await Oo(y,m);if(K()){if(h?.unconfirmedAcceptance){if(N.ok&&N.value.eventCount>0){h.userId&&Be(h.userId,Q=>({...Q,deliveryState:"Delivered",errorDetail:void 0})),_t(p,Q=>({...Q,content:N.value.text||Q.content,replyOperationId:N.value.executionId??Q.replyOperationId,deliveryState:N.value.error?"Failed":"Cut_recovered",cutStream:!1,errorDetail:N.value.error??void 0})),Tt.current("history");return}if(!N.ok&&(N.error.kind==="epoch_stale"||N.error.kind==="aborted"))return;const $=await Io(y);if(!K())return;if($.ok){const Q=$.value.find(R=>R.operationId===m);if(Q){const R=Ar(Q.state);h.userId&&Be(h.userId,P=>({...P,deliveryState:Q.state==="Queued"?"Queued":"Delivered",errorDetail:void 0})),_t(p,P=>({...P,deliveryState:R.delivery,cutStream:!1,errorDetail:R.detail??P.errorDetail})),Tt.current("queue","waiting");return}if(N.ok){const R=h.streamError??"전송 실패";h.userId&&Be(h.userId,P=>({...P,deliveryState:"Failed",errorDetail:R})),_t(p,P=>({...P,deliveryState:"Failed",cutStream:!1,errorDetail:R}));return}}else if($.error.kind==="epoch_stale"||$.error.kind==="aborted")return;const L="수락 여부 확인 실패 — 중복 전송 방지를 위해 새로고침 후 확인하세요";h.userId&&Be(h.userId,Q=>({...Q,deliveryState:"Confirming_delivery",errorDetail:L})),_t(p,Q=>({...Q,deliveryState:"Confirming_delivery",errorDetail:L}));return}if(!N.ok){if(N.error.kind==="epoch_stale"||N.error.kind==="aborted")return;_t(p,$=>({...$,deliveryState:"Failed",errorDetail:`저널 복구 실패: ${N.error.message}`}));return}_t(p,$=>({...$,content:N.value.text||$.content,replyOperationId:N.value.executionId??$.replyOperationId,deliveryState:N.value.error?"Failed":"Cut_recovered",cutStream:!1,errorDetail:N.value.error??void 0})),Tt.current("history")}},co=async p=>{const m=p.trim();if(!m)return;const h=t.name,y=Te();Ln.current?.abort();const T=new AbortController;Ln.current=T;const K=()=>ze.current&&Je.current===h&&ie(y)&&!T.signal.aborted;vt(!0),Ne({status:"streaming",prompt:m,reply:"",error:null});const N=`btw-${Cn()}`;so(N);const $=await la({keeper:h,message:m,operationId:N,mode:{kind:"btw"},signal:T.signal,callbacks:{onTextDelta:L=>{K()&&Ne(Q=>({...Q,reply:Q.reply+L}))},onReplyDetails:L=>{K()&&Ne(Q=>({...Q,reply:L||Q.reply}))},onError:L=>{K()&&Ne(Q=>({...Q,status:"error",error:L}))},onFinished:()=>{K()&&Ne(L=>({...L,status:L.status==="error"?"error":"done"}))}}});if(!$.terminal&&K())if($.error)$.error!=="aborted"&&$.error!=="session_epoch_changed"&&Ne(L=>L.status==="error"?L:{...L,status:"error",error:$.error});else if(!yt(_e.peek()))Ne(L=>({...L,status:L.reply?"done":"error",error:L.reply?null:"스트림이 중단되었습니다. 다시 시도하세요."}));else{const L=await Oo(h,N);if(!K())return;L.ok?Ne(Q=>({...Q,status:L.value.error?"error":"done",reply:L.value.text||Q.reply,error:L.value.error})):L.error.kind!=="aborted"&&L.error.kind!=="epoch_stale"&&Ne(Q=>({...Q,status:"error",error:L.error.message}))}},gr=async p=>{if(Un.current)return;if(Eo(me.current)){g("첨부 파일 업로드가 완료된 뒤 전송하세요.");return}if(To(me.current)){g("업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 전송하세요.");return}const m=D.current.trim(),h=vl(me.current);if(!m&&h.length===0)return;if(/^\/btw(?:\s|$)/.test(m)){const G=m.slice(4).trim();if(D.current="",re(""),!G){vt(!0);return}await co(G);return}const y=t.name,T=Te(),K=`op-${Cn()}`,N=Date.now()/1e3,$=`user-${K}`,L={id:$,role:"user",speakerLabel:"Operator",content:m,attachments:h.length>0?h:void 0,ts:N,operationId:K,deliveryState:"Sending"},Q=[...h];if(Dn.current&&p==="queue"){Un.current=!0,Ke(!0),Fn.current=!0,r(G=>({keeperName:y,entries:G.keeperName===y?[...G.entries,L]:[L]})),D.current="",re(""),Ue(),queueMicrotask(()=>eo.current?.focus());try{const G=await gd({keeper:y,message:m,operationId:K,mode:{kind:"queue"},attachments:Q});if(!ze.current||Je.current!==y||!ie(T))return;if(G.controlToken&&ct(G.controlToken),!G.accepted){if(G.error==="session_epoch_changed"||G.error==="aborted")return;if(G.rejected){Be($,ee=>({...ee,deliveryState:"Failed",errorDetail:G.error??"대기열 등록 실패"}));return}Be($,ee=>({...ee,deliveryState:"Confirming_delivery",errorDetail:void 0}));const oe=await Io(y);if(!ze.current||Je.current!==y||!ie(T))return;const U=oe.ok?oe.value.find(ee=>ee.operationId===K):void 0;if(U){const ee=Ar(U.state);Be($,Re=>({...Re,deliveryState:U.state==="Queued"?"Queued":ee.delivery,errorDetail:ee.detail??void 0}))}else{const ee=await Oo(y,K);if(!ze.current||Je.current!==y||!ie(T))return;ee.ok&&ee.value.eventCount>0?Be($,Re=>({...Re,deliveryState:ee.value.error?"Failed":"Delivered",errorDetail:ee.value.error??void 0})):oe.ok&&ee.ok?Be($,Re=>({...Re,deliveryState:"Failed",errorDetail:G.error??"대기열 등록 실패"})):Be($,Re=>({...Re,deliveryState:"Confirming_delivery",errorDetail:"수락 여부 확인 실패 — 중복 전송 방지를 위해 새로고침 후 확인하세요"}))}Tt.current("queue","waiting"),e.onMutated();return}const ge=Ar(G.state??"");Be($,oe=>({...oe,deliveryState:ge.delivery,errorDetail:ge.detail??oe.errorDetail})),Tt.current("queue","waiting"),e.onMutated()}finally{Un.current=!1,ze.current&&Ke(!1)}return}const R=++kn.current,P=`asst-${K}`,O={id:P,role:"assistant",content:"",ts:N,operationId:K,deliveryState:"Sending"};Dn.current=!0,tn.current={operationId:K,executionId:K},so(K),Ts(K),Fn.current=!0,r(G=>({keeperName:y,entries:G.keeperName===y?[...G.entries,L,O]:[L,O]})),D.current="",re(""),Ue(),Et(!0),queueMicrotask(()=>eo.current?.focus());let B=null,q=!1,J={terminal:!1,error:null};try{let G={kind:"queue"};if(p==="steer"){const ge=nt??await zu(y);if(!ze.current||Je.current!==y||!ie(T)||kn.current!==R)return;ge&&(ct(ge),G={kind:"steer",controlToken:ge})}if(!ze.current||Je.current!==y||!ie(T)||kn.current!==R)return;_r.current?.abort("steered"),B=new AbortController,_r.current=B,J=await la({keeper:y,message:m,operationId:K,mode:G,attachments:Q,signal:B.signal,callbacks:ao({assistantId:P,userId:$,initialAcceptedByServer:!1,onServerAccepted:()=>{q=!0},updateAssistant:ge=>_t(P,ge),updateExistingAssistant:ge=>_t(P,ge),onBatchBound:(ge,oe)=>{ge===K&&(tn.current={operationId:K,executionId:oe},so(oe),Ts(oe),_t(P,U=>({...U,replyOperationId:oe})))}})})}finally{kn.current===R&&(Dn.current=!1,tn.current=null,ze.current&&Et(!1))}!ze.current||Je.current!==y||!ie(T)||kn.current!==R||J.error==="session_epoch_changed"||J.error==="aborted"||(!J.terminal&&!B?.signal.aborted&&(q?(Be($,G=>G.deliveryState==="Sending"?{...G,deliveryState:"Delivered"}:G),_t(P,G=>({...G,cutStream:!0,deliveryState:"Confirming_delivery"})),await lo(P,K)):(Be($,G=>({...G,deliveryState:"Confirming_delivery"})),_t(P,G=>({...G,cutStream:!0,deliveryState:"Confirming_delivery"})),await lo(P,K,{userId:$,unconfirmedAcceptance:!0,streamError:J.error}))),!(!ze.current||Je.current!==y||!ie(T))&&(Tt.current("history","queue","waiting"),e.onMutated()))},qi=p=>{p.isComposing||p.keyCode===229||p.key==="Enter"&&(p.shiftKey||(p.preventDefault(),!Un.current&&(p.metaKey||p.ctrlKey?gr("steer"):gr("queue"))))},Fi=async p=>{const m=p.currentTarget;if(!yt(_e.peek())){m.value="";return}const h=m.files?.[0];if(h){ye(!0);try{const y=await h.arrayBuffer(),T=await kd(y,h.type||"audio/webm");T.ok&&T.value.trim()&&re(K=>K.trim()?`${K.trim()} ${T.value.trim()}`:T.value.trim())}finally{ye(!1),m.value=""}}},kr=ps(t),uo=kr.kind==="value"?kr.data:null,Hi=uo!==null?Mo*(1-uo/100):Mo,ji=wa(uo),po=wt(()=>s.slice(-je).map(p=>({msg:p,blocks:ja(p)})),[s,je]),{hiddenInternalCount:Ss,visibleEntries:jt,displayItems:_o}=wt(()=>{let p=0;const m=[];for(let h=0;h<po.length;h++){const y=po[h];y.blocks.isInternalOnly&&V.internal==="hidden"&&(p+=1),eu(y.msg,y.blocks,V)&&m.push(y)}return{hiddenInternalCount:p,visibleEntries:m,displayItems:su(m)}},[po,V]),xs=[],Rs=[];if(V.tools!=="hidden"){const p=(m,h,y,T)=>{const K=m.executionId?.trim();if(!K||m.result)return;const N=`${y}:tool:${m.streamKey??h}`,$=ht[N]??ht[`exec:${K}`];$===!0?xs.push(K):V.tools==="full"&&$!==!1&&T&&Rs.push(K)};for(const m of _o)if(m.kind==="tool_group")if(m.toolBlocks.length===1){const h=m.entries[0];p(h.blocks.toolBlocks[0],0,h.msg.id,!0)}else{const h=ht[m.id]??V.tools==="full";for(const y of m.entries)y.blocks.toolBlocks.forEach((T,K)=>{p(T,K,y.msg.id,h)})}else{const{msg:h,blocks:y}=m.entry;if(y.toolBlocks.length===1)p(y.toolBlocks[0],0,h.id,!0);else if(y.toolBlocks.length>1){const T=`turn-tools:${h.id}`;y.toolBlocks.some($=>$.status==="running"||$.status==="awaiting_result"||$.status==="awaiting_approval")&&hn.current.add(T);const N=ht[T]??(V.tools==="full"||hn.current.has(T));y.toolBlocks.forEach(($,L)=>{p($,L,h.id,N)})}}}const Gi=Rs.slice(-8),fo=Array.from(new Set([...xs,...Gi])).join("\0");Se(()=>{if(!se||!fo)return;const p=fo.split("\0").filter(Boolean);for(const m of p)!on.current[m]&&!Kt.current.has(m)&&Rt(m)},[se,fo,t.name,V.tools,Rt]);const vr=fi(Mi,ot,Pt?.updatedAt,Pt?.retiredOwners),qe=vr?.preview??ot?.preview??null,ft=qe?.open_activities??null,mo=ot!==null||qe!==null,Wi=pe&&s.some(p=>p.role==="assistant"&&p.operationId===tn.current?.operationId&&p.deliveryState==="Queued"),Vi=s.some(p=>p.role==="assistant"&&p.id.startsWith("obs-asst-")&&p.deliveryState==="Streaming"),En=(!pe||Wi)&&!Vi&&mo,go=ds(qe?.activity),Nt=qe?.work_context??null,an=qe?ur(qe):null,As=an?.tone??go.tone,Cs=ot?Wa(ot.lane):"Keeper 턴",Is=qe?Lo(qe.updated_at_unix):null,Os=ot!==null&&rn?.status==="ok"&&rt?.kind==="value"&&!rt.stale&&rt!==Li,hr=tr.value&&(Os||vr?.live===!0),Gt=hr&&As!=="bad",zi=hr?Gt?"Working":an?.phrase??go.label:"마지막 확인",br=Pt?.updatedAt,ws=br===void 0?void 0:Math.max(br,vr?.receivedAt??br),Ps=ot&&br!==void 0&&ot.started_at_unix>0?ot.started_at_unix*1e3:null,Ks=qe?.activity==="tool"?qe.last_tool:null,Vn=Ks??qe?.last_tool??null,Qi=Gt&&Ks!==null&&(Os||vr?.preview.activity==="tool"),Ns=Vn===null?null:ft===null?`${Qi?"실행 중":"최근 도구"} · ${Vn}`:vu(ft,Vn)?null:`최근 도구 · ${Vn}`,ko=qe?.activity==="failed",vo=ft!==null?qe?.last_failure??null:null,ho=vo===null?null:ko?`${go.label} · ${vo}`:`앞선 시도 실패 · ${vo}`,bo=qe&&ft!==null&&!(ko&&ho!==null)?Sd(qe):null,yo=gn?new Date(gn.atUnix*1e3):null,yr=(p,m,h,y)=>{const T=y?.cachedRes,K=y?.executionId,N=np(T),$=Ki[h]===!0,L=rp(m),Q=y&&(T?.status!=="loaded"||T.eof&&!T.isBinary)?Yc(m):null,R=u`<pre class=${$?"kp-block-pre kp-block-pre--expanded":"kp-block-pre"}>${m}</pre>`,P=!!(se&&K&&T?.status==="loaded"&&!T.eof&&!T.isBinary);return u`
      <div class="kp-block-subbar">
        <div class="kp-pill-row">
          <span class="kp-block-sublabel">
            ${p}${T?.status==="loaded"&&T.eof===!1?" · 일부 표시":""}
          </span>
          ${N&&u`
            <span class="kp-pill" data-tone=${T?.eof===!1?"warn":"default"}>
              ${N}
            </span>
          `}
          ${T?.status==="loaded"&&T.isBinary&&u`
            <span class="kp-pill">바이너리 · ${Pr(T.totalBytes??T.recordedBytes??0)}</span>
          `}
        </div>
        <div class="kp-block-subactions">
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            onClick=${()=>{Di(h,m)}}
          >
            ${Ni===h?"복사됨":"복사"}
          </button>
          ${L&&u`
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>ks(O=>({...O,[h]:!O[h]}))}
            >
              ${$?"축소":"전체 높이"}
            </button>
          `}
        </div>
      </div>
      ${Q===null?R:u`
        <${zt} text=${Q} />
        <details open=${$||void 0}>
          <summary>저장 참조</summary>
          ${R}
        </details>
      `}
      ${P&&u`
        <div class="kp-tool-result-pager" data-testid="tool-result-pager">
          <span class="kp-pill" data-tone="warn">
            ${T?.loadingMore?`불러오는 중… (${N??""})`:N??"일부 표시"}
          </span>
          <div class="kp-block-subactions">
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              disabled=${T?.loadingMore===!0}
              onClick=${()=>{oo(K,1)}}
            >
              더 불러오기 (+16KB)
            </button>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              disabled=${T?.loadingMore===!0}
              onClick=${()=>{oo(K,hi)}}
            >
              끝까지 불러오기
            </button>
          </div>
        </div>
      `}
      ${se&&K&&T?.status==="loaded"&&T.loadMoreError&&u`
        <div class="kp-tool-result-error" role="alert" data-testid="tool-result-load-more-error">
          <span>${T.loadMoreError}</span>
          <div class="kp-block-subactions">
            ${T.loadMoreConflict?u`
                  <button
                    type="button"
                    class="btn-ghost kp-toggle-btn"
                    onClick=${()=>{Rt(K,!0)}}
                  >
                    처음부터 다시 불러오기
                  </button>
                `:u`
                  <button
                    type="button"
                    class="btn-ghost kp-toggle-btn"
                    onClick=${()=>{oo(K,1)}}
                  >
                    다시 시도
                  </button>
                  <button
                    type="button"
                    class="btn-ghost kp-toggle-btn"
                    onClick=${()=>{Rt(K,!0)}}
                  >
                    처음부터 다시 불러오기
                  </button>
                `}
          </div>
        </div>
      `}
    `},Ms=(p,m,h,y,T,K,N)=>u`
    ${!y&&m?.status==="loaded"&&u`
      <div class="kp-block-status">(빈 출력 · 0 B)</div>
    `}
    ${!y&&m?.status==="loading"&&u`
      <div class="kp-block-status">${K}</div>
    `}
    ${!y&&m?.status==="pending"&&u`
      <div class="kp-block-status">
        도구 실행 중 — 결과 준비 대기 중…
        ${se&&p.executionId&&u`
          ${" "}
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            onClick=${()=>{Rt(p.executionId,!0)}}
          >
            다시 확인
          </button>
        `}
      </div>
    `}
    ${!y&&m?.status==="unavailable"&&u`
      <div class="kp-block-status">저장된 결과 없음 (${m.detail??"unavailable"})</div>
    `}
    ${!y&&m?.status==="error"&&u`
      <div class="kp-block-status">
        결과 조회 실패 (${m.detail??"error"})
        ${se&&p.executionId&&u`
          ${" "}
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            onClick=${()=>{Rt(p.executionId,!0)}}
          >
            ${m.sourceChanged?"처음부터 다시 불러오기":"다시 시도"}
          </button>
        `}
      </div>
    `}
    ${!y&&!m&&p.executionId&&(se?u`
          <div class="kp-block-status">
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>{Rt(p.executionId,!0)}}
            >
              실행 결과 불러오기
            </button>
          </div>
        `:u`
          <div class="kp-block-status" data-testid="chat-tool-result-admin-locked" role="status">
            도구 실행 상세 결과 조회는 토큰 인증 관리자 전용입니다.
          </div>
        `)}
    ${!N&&!h&&!y&&!m&&!p.executionId&&u`
      <div class="kp-block-status">
        ${p.progressLabel??(T==="running"?"도구 실행 중…":T==="awaiting_result"?"도구 호출 완료 — 결과 대기 중…":T==="awaiting_approval"?"운영자 승인 대기 중…":"기록된 입력·결과가 없습니다.")}
      </div>
    `}
  `,$r=(p,m,h)=>{const y=p.executionId?Vr[p.executionId]:void 0,T=p.args?pn(p.args):void 0,K=p.result??(y?.status==="loaded"?y.displayContent:void 0),N=y?.status==="loaded"?y.isError?"error":"completed":p.status,$=tu(N),L=us({...p,args:T??p.args,result:K??p.result}),Q=`${h}:tool:${p.streamKey??m}`,R=ht[Q]??(p.executionId?ht[`exec:${p.executionId}`]:void 0)??V.tools==="full";Xe.current.set(Q,R);const P=q=>{const J=q.currentTarget;J.open!==Xe.current.get(Q)&&(Xe.current.set(Q,J.open),sn(Q,J.open,p.executionId),J.open&&yt(_e.peek())&&p.executionId&&!K&&(!y||y.status==="pending"||y.status==="error")&&Rt(p.executionId,!0))};if(L){const q=L.kind==="delegate"?"위임":L.kind==="delegate_status"?"위임 조회":"위임 취소",J=L.targetKeepers.length>1?` → @${L.targetKeepers[0]} 외 ${L.targetKeepers.length-1}명`:L.targetKeeper?` → @${L.targetKeeper}`:"",G=L.delegateState??p.progressLabel??$.label,ge=L.prompt??(L.operationCount>1?`대상 ${L.operationCount}건`:null)??L.operationId??G,oe=Yt(typeof ge=="string"&&ge.length>512?ge.slice(0,512):ge,90),U=!!(L.prompt||L.operationId||L.operationCount>0),ee=`${Q}:raw`,Re=ht[ee]===!0;return Xe.current.set(ee,Re),u`
        <div
          key=${Q}
          class="kp-collapsible-shell kp-block-card kp-block-card--delegate"
          data-testid="chat-delegate-card"
        >
          <details
            class="kp-collapsible-details"
            open=${R}
            onToggle=${P}
          >
            <summary class="kp-block-summary">
              <span class="kp-pill" data-tone="brass">
                ${q}${J}
              </span>
              <span class="kp-pill" data-tone=${$.tone}>
                ${G}${p.duration?` · ${p.duration}`:""}
              </span>
              <span class="kp-block-preview">${oe}</span>
            </summary>
            <div class="kp-block-content">
              ${L.prompt&&u`
                <div class="kp-block-sublabel">위임 요청 내용</div>
                <div class="kp-delegate-prompt">${L.prompt}</div>
              `}
              <div class="kp-pill-row">
                ${L.operationCount>1&&u`
                  <span class="kp-pill">조회 대상 ${L.operationCount}건</span>
                `}
                ${L.operationId&&u`
                  <span class="kp-pill">op: ${L.operationId}</span>
                `}
                ${L.artifactCount>0&&u`
                  <span class="kp-pill">아티팩트 ${L.artifactCount}개</span>
                `}
                ${L.targetTurnAgeSec!==null&&u`
                  <span class="kp-pill" data-tone="warn">상대 턴 경과 ${fn(L.targetTurnAgeSec)}</span>
                `}
              </div>
              ${(T||K)&&u`
                <details
                  key=${ee}
                  class="kp-sub-details"
                  open=${Re}
                  onToggle=${$e=>{const he=$e.currentTarget.open;he!==Xe.current.get(ee)&&(Xe.current.set(ee,he),sn(ee,he))}}
                >
                  <summary class="kp-sub-summary">원본 입출력 (JSON)</summary>
                  <div class="kp-block-content">
                    ${T&&yr("입력 (Args)",T,`${Q}:args`)}
                    ${K&&yr("결과 (Result)",K,`${Q}:result`,{cachedRes:y,executionId:p.executionId})}
                  </div>
                </details>
              `}
              ${Ms(p,y,T,K,N,"위임 응답 불러오는 중…",U)}
            </div>
          </details>
          ${L.targetKeepers.length>0&&e.onSelectKeeper&&u`
            <div class="kp-collapsible-actions">
              ${L.targetKeepers.map($e=>u`
                <button
                  key=${$e}
                  type="button"
                  class="btn-ghost kp-toggle-btn kp-delegate-jump"
                  aria-label=${`${$e} Keeper 대화로 이동`}
                  onClick=${()=>e.onSelectKeeper?.($e)}
                >
                  @${$e} ↗
                </button>
              `)}
            </div>
          `}
        </div>
      `}const O=T??K??p.progressLabel??$.label,B=Yt(typeof O=="string"&&O.length>512?O.slice(0,512):O,90);return u`
      <details
        key=${Q}
        class="kp-block-card kp-block-card--tool"
        data-testid="chat-tool-card"
        open=${R}
        onToggle=${P}
      >
        <summary class="kp-block-summary">
          <span class="kp-pill" data-tone=${$.tone}>도구 · ${p.name}</span>
          <span class="kp-pill" data-tone=${$.tone}>
            ${p.progressLabel??$.label}${p.duration?` · ${p.duration}`:""}
          </span>
          <span class="kp-block-preview">${B}</span>
        </summary>
        <div class="kp-block-content">
          ${T&&yr("입력 (Args)",T,`${Q}:args`)}
          ${K&&yr("결과 (Result)",K,`${Q}:result`,{cachedRes:y,executionId:p.executionId})}
          ${p.attachments&&p.attachments.length>0&&u`
            <${Hs}
              attachments=${p.attachments}
              workspaceEpoch=${Te()}
              compact=${!0}
            />
          `}
          ${Ms(p,y,T,K,N,"결과 불러오는 중…",!1)}
        </div>
      </details>
    `},Mt=jt[jt.length-1]?.msg,Ls=En?`live:${qe?.revision??0}:${qe?.text_tail.length??0}:${Vn??""}`:"",Yi=[...Mt?.retainedImages?.map(p=>p.path)??[],...Mt?.attachments?.map(p=>p.attachment_id||p.url)??[]].join(","),Er=Mt?`${jt.length}:${Mt.id}:${Mt.content.length}:${Mt.thinking?.length??0}:${Mt.toolCalls?.length??0}:${Mt.deliveryState??""}:${Mt.errorDetail??""}:${Yi}:${Ls}`:`${jt.length}:empty:${Ls}`;return Bs(()=>{const p=Mn.current;if(!p)return;const m=fr.current;if(m){fr.current=null;const y=p.scrollHeight-m.prevScrollHeight;p.scrollTop=m.prevScrollTop+Math.max(0,y),no.current=Er;return}const h=Er!==no.current;if(no.current=Er,Fn.current){(jt.length>0||!(k||i))&&(Fn.current=!1,$n("auto"));return}h&&(qn.current?$n("auto"):jt.length>0&&dr(y=>y+1))},[Er,k,i,jt.length,$n]),u`
    <div class="kp-chat-shell" data-companion-open=${j?"true":"false"}>
      <div class="kp-chat-main">
        <div class="kp-chat-toolbar">
          <div class="kp-pill-row">
            <span class="kp-pill" data-tone="info">Origin_bare · AG-UI SSE</span>
            <${Or}
              triggerLabel=${"표시 ▾"}
              triggerClassName="btn-ghost kp-toggle-btn"
              triggerTestId="chat-display-menu"
              popoverTestId="chat-display-popover"
              ariaLabel="채팅 블록 표시 설정"
              triggerTitle=${`추론: ${Xs(V.thinking)} · 도구: ${Zs(V.tools)} · 메모리·내부: ${ea(V.internal)}`}
              closeOnSelect=${!1}
              items=${[{id:"thinking",testId:"chat-toggle-thinking",label:`추론: ${Xs(V.thinking)}`,shortcut:"Alt+T",onSelect:()=>le(p=>({...p,thinking:Js(p.thinking)}))},{id:"tools",testId:"chat-toggle-tools",label:`도구: ${Zs(V.tools)}`,onSelect:()=>le(p=>({...p,tools:Wc(p.tools)}))},{id:"internal",testId:"chat-toggle-internal",label:`메모리·내부: ${ea(V.internal)}${Ss>0?` (${Ss})`:""}`,onSelect:()=>le(p=>({...p,internal:Vc(p.internal)}))}]}
            />
            ${f&&u`
              <button type="button" class="btn-ghost" disabled=${k} onClick=${()=>{Bi()}}>
                이전 대화 불러오기
              </button>
            `}
          </div>
          <div class="kp-pill-row">
            <button
              type="button"
              class="btn-ghost"
              aria-pressed=${Ve?"true":"false"}
              onClick=${()=>vt(p=>!p)}
            >
              /btw 사이드 질의
            </button>
            <button
              type="button"
              class="btn-ghost"
              aria-pressed=${j?"true":"false"}
              onClick=${()=>A(p=>!p)}
            >
              ${j?"Debug 닫기 (⌘.)":"Debug 열기 (⌘.)"}
            </button>
          </div>
        </div>

        ${l&&u`<div class="ap-error" role="alert">${l}</div>`}

        <div class="kp-chat-stage">
          <div
            ref=${Mn}
            class="kp-chat-list"
            role="log"
            aria-label="Keeper 대화 기록"
            onScroll=${Ui}
          >
            <div class="kp-chat-feed" ref=${hs}>
            ${(k||i)&&s.length===0?u`<div class="kp-empty">대화 기록 불러오는 중…</div>`:_o.length===0&&!En?u`<div class="kp-empty">${s.length>0?"현재 블록 필터에 표시할 메시지가 없습니다.":`${t.name}과(와) 대화를 시작하세요.`}</div>`:_o.map(p=>{if(p.kind==="tool_group"){if(p.toolBlocks.length===1){const J=p.entries[0];return u`
                          <div key=${p.id} class="kp-activity-single" data-testid="chat-tool-single">
                            ${$r(J.blocks.toolBlocks[0],0,J.msg.id)}
                          </div>
                        `}const q=ht[p.id]??V.tools==="full";return Xe.current.set(p.id,q),u`
                        <div
                          key=${p.id}
                          class="kp-collapsible-shell kp-activity-group"
                          data-testid="chat-tool-group"
                        >
                          <details
                            class="kp-collapsible-details"
                            open=${q}
                            onToggle=${J=>{const G=J.currentTarget.open;G!==Xe.current.get(p.id)&&(Xe.current.set(p.id,G),sn(p.id,G))}}
                          >
                            <summary class="kp-activity-group-summary">
                              <span class="kp-pill" data-tone="info">도구 활동 · ${p.toolBlocks.length}건</span>
                              <span class="kp-block-preview">${p.toolSummary}</span>
                            </summary>
                            <div class="kp-hierarchy-rail">
                              ${p.entries.flatMap(J=>J.blocks.toolBlocks.map((G,ge)=>$r(G,ge,J.msg.id)))}
                            </div>
                          </details>
                          ${p.delegateTargets.length>0&&e.onSelectKeeper&&u`
                            <div class="kp-collapsible-actions">
                              ${p.delegateTargets.map(J=>u`
                                <button
                                  key=${J}
                                  type="button"
                                  class="btn-ghost kp-toggle-btn kp-delegate-jump"
                                  aria-label=${`${J} Keeper 대화로 이동`}
                                  onClick=${()=>e.onSelectKeeper?.(J)}
                                >
                                  @${J} ↗
                                </button>
                              `)}
                            </div>
                          `}
                        </div>
                      `}const{msg:m,blocks:h}=p.entry,y=Lo(m.ts),T=!!(h.thinkingText&&V.thinking!=="hidden"),K=h.toolBlocks.length>0&&V.tools!=="hidden",N=h.memoryItems.length>0&&V.internal==="shown",$=h.autonomousSummary!==null&&V.internal==="shown",L=T||K||N||$,Q=h.toolBlocks.some(q=>q.status==="running"||q.status==="awaiting_result"||q.status==="awaiting_approval"),R=`${m.id}:thinking`,P=Pi[R]??V.thinking==="expanded";Xe.current.set(R,P);const O=`turn-tools:${m.id}`;Q&&hn.current.add(O);const B=ht[O]??(V.tools==="full"||hn.current.has(O));return Xe.current.set(O,B),u`
                      <article key=${m.id} class="kp-msg" data-role=${m.role}>
                        <div class="kp-msg-head">
                          <span>
                            ${cp(m,t.name,h.autonomousSummary,h.memoryItems.length>0&&h.bodyText.length===0)}
                          </span>
                          <div class="kp-pill-row">
                            ${y&&u`<time class="kp-msg-time tnum">${y}</time>`}
                            ${m.surface&&m.surface!=="chat"&&m.surface!=="dashboard"&&u`
                              <span class="kp-pill" data-tone="info">${m.surface}</span>
                            `}
                            ${m.runtimeAttempt&&ma(m.runtimeAttempt)&&u`
                              <span class="kp-pill" data-tone="info" data-testid="chat-runtime-attempt">
                                ${ma(m.runtimeAttempt)}
                              </span>
                            `}
                            ${m.deliveryState&&u`
                              <span class="kp-pill" data-tone=${up(m.deliveryState)}>
                                ${m.deliveryState}
                              </span>
                            `}
                            ${Ce&&m.discordReplyOrigin&&u`
                              <button type="button" class="btn-ghost"
                                aria-expanded=${W===m.id?"true":"false"}
                                onClick=${q=>{ce.current=q.currentTarget,z(J=>J===m.id?null:m.id)}}>
                                Discord 답장
                              </button>
                            `}
                            ${se&&m.cutStream&&m.operationId&&u`
                              <button
                                type="button"
                                class="btn-ghost"
                                onClick=${()=>{lo(m.id,m.operationId)}}
                              >
                                저널 복구
                              </button>
                            `}
                          </div>
                        </div>

                        ${L&&u`
                          <div class="kp-turn-trace" data-testid="chat-turn-trace">
                            ${T&&u`
                              <details
                                key=${R}
                                class="kp-block-card kp-msg-thinking"
                                data-testid="chat-thinking-card"
                                open=${P}
                                onToggle=${q=>{const J=q.currentTarget.open;J!==Xe.current.get(R)&&(Xe.current.set(R,J),Qr(G=>G[R]===J?G:{...G,[R]:J}))}}
                              >
                                <summary class="kp-block-summary">
                                  <span>추론 (Thinking)</span>
                                  <span class="kp-block-preview">${Yt(h.thinkingText,80)}</span>
                                </summary>
                                <${zt} class="kp-block-content" text=${h.thinkingText} streaming=${m.deliveryState==="Streaming"} />
                              </details>
                            `}

                            ${K&&(h.toolBlocks.length===1?u`
                                  <div class="kp-block-stack">
                                    ${$r(h.toolBlocks[0],0,m.id)}
                                  </div>
                                `:u`
                                  <details
                                    key=${O}
                                    class="kp-tool-subgroup"
                                    data-testid="chat-turn-tool-group"
                                    open=${B}
                                    onToggle=${q=>{const J=q.currentTarget.open;J!==Xe.current.get(O)&&(Xe.current.set(O,J),sn(O,J))}}
                                  >
                                    <summary class="kp-block-summary">
                                      <span class="kp-pill" data-tone=${Q?"brass":"info"}>
                                        도구 실행 · ${h.toolBlocks.length}건
                                      </span>
                                      ${Q&&u`
                                        <span class="kp-pill" data-tone="brass">진행 중</span>
                                      `}
                                      <span class="kp-block-preview">${Ga(h.toolBlocks)}</span>
                                    </summary>
                                    <div class="kp-hierarchy-rail">
                                      ${h.toolBlocks.map((q,J)=>$r(q,J,m.id))}
                                    </div>
                                  </details>
                                `)}

                            ${N&&u`
                              <details key=${`${m.id}:memory`} class="kp-block-card kp-block-card--memory" data-testid="chat-memory-card">
                                <summary class="kp-block-summary">
                                  <span class="kp-pill" data-tone="brass">메모리 회상 (${h.memoryItems.length})</span>
                                  <span class="kp-block-preview">${Yt(h.memoryItems[0],90)}</span>
                                </summary>
                                <ul class="kp-block-list">
                                  ${h.memoryItems.map((q,J)=>u`<li key=${J}><${zt} text=${q} /></li>`)}
                                </ul>
                              </details>
                            `}

                            ${$&&u`
                              <details key=${`${m.id}:autonomous`} class="kp-block-card kp-block-card--auto" data-testid="chat-autonomous-card">
                                <summary class="kp-block-summary">
                                  <span class="kp-pill" data-tone="warn">자율 턴 (Autonomous)</span>
                                  <span class="kp-block-preview">${h.autonomousSummary}</span>
                                </summary>
                                ${h.autonomousDetails&&u`
                                  <pre class="kp-block-pre">${h.autonomousDetails}</pre>
                                `}
                              </details>
                            `}
                          </div>
                        `}

                        ${(h.bodyText||m.deliveryState==="Streaming"||m.deliveryState==="Pending_processing")&&u`
                          ${h.bodyText?u`<${zt} class="kp-msg-body" text=${h.bodyText} streaming=${m.deliveryState==="Streaming"} />`:!En&&ft!==null&&ft.length>0?null:u`<div class="kp-msg-body">${m.deliveryState==="Pending_processing"?"요청 처리 준비 중…":"응답 생성 중…"}</div>`}
                          ${!En&&(m.deliveryState==="Streaming"||m.deliveryState==="Pending_processing")&&ft!==null&&ft.length>0&&u`
                            <${ka} activities=${ft} live=${Gt} />
                          `}
                        `}
                        ${(()=>{const q=kp(m);if(q.length===0)return null;const J=m.retainedImages?.[0]?.workspaceEpoch??Te();return u`
                            <${Hs}
                              attachments=${q}
                              workspaceEpoch=${J}
                            />
                          `})()}
                        ${m.providerRetry&&u`
                          <div class="kp-stream-notice" data-kind="retry" role="status">
                            ${Xd(m.providerRetry)}
                          </div>
                        `}
                        ${m.streamNotices?.map((q,J)=>u`
                          <div class="kp-stream-notice" data-kind=${q.kind} key=${`notice:${J}`}
                            role=${q.kind==="protocol_error"?"alert":"status"}>
                            <strong>${Zd(q.kind)}</strong> ${q.text}
                          </div>
                        `)}
                        ${m.errorDetail&&u`<div class="ap-error">${m.errorDetail}</div>`}
                        ${Ce&&m.discordReplyOrigin&&W===m.id&&u`
                          <${Yd}
                            key=${JSON.stringify([Ce,m.id])}
                            target=${{keeperName:t.name,chatId:m.id,origin:m.discordReplyOrigin}}
                            authority=${Ce}
                            onClose=${()=>{z(null),ce.current?.focus()}} />
                        `}
                      </article>
                    `})}

            ${En&&u`
              <section class="kp-live-turn-card" data-testid="chat-live-turn-card">
                <div class="kp-msg-head">
                  <div class="kp-pill-row">
                    <span class="kp-pill" data-tone="brass" title=${qe?.status_text||void 0}>${Cs}</span>
                    ${ot?.turn_ref&&u`<span class="kp-pill">${ot.turn_ref}</span>`}
                  </div>
                  <div class="kp-pill-row">
                    ${Is&&u`<span class="kp-pill">마지막 관측 ${Is}</span>`}
                  </div>
                </div>
                <div class="kp-hierarchy-rail">
                  ${Ns&&u`
                    <div class="kp-pill-row">
                      <span class="kp-pill" data-tone="info">${Ns}</span>
                    </div>
                  `}
                  ${ft===null&&qe?.status_text&&u`
                    <div class="kp-live-turn-status">${qe.status_text}</div>
                  `}
                  ${bo&&u`
                    <div class="kp-live-turn-status" data-testid="chat-turn-doing" data-tone=${bo.tone}>${bo.phrase}</div>
                  `}
                  ${ft!==null&&ft.length>0&&u`
                    <${ka} activities=${ft} live=${Gt} />
                  `}
                  ${ho&&u`
                    <div class="kp-live-turn-status" data-testid="chat-turn-failure" data-tone=${ko?"bad":void 0}>${ho}</div>
                  `}
                  ${Nt&&(Nt.start_reasons.length>0||Nt.task_id)&&u`
                    <div class="kp-live-turn-status" data-testid="chat-turn-work-context">
                      ${Nt.start_reasons.length>0&&`시작 계기: ${Nt.start_reasons.map(Cl).join(" · ")}`}
                      ${Nt.start_reasons.length>0&&Nt.task_id&&" · "}
                      ${Nt.task_id&&`시작 시 Task: ${Nt.task_id}`}
                    </div>
                  `}
                  ${qe?.text_tail&&u`
                    <div class="kp-live-turn-tail">… ${qe.text_tail}</div>
                  `}
                </div>
              </section>
            `}
            </div>
          </div>
          ${!mn&&(jt.length>0||En)&&u`
            <button
              type="button"
              class="kp-scroll-bottom-btn"
              data-testid="chat-scroll-bottom"
              data-has-unseen=${Nn>0?"true":"false"}
              onClick=${()=>$n("smooth")}
            >
              ${Nn>0?"↓ 새 응답 보기":"↓ 맨 아래로"}
            </button>
          `}
        </div>

        ${Jr&&Jr.rows.length>0&&u`
          <${jd} inventory=${Jr} nowUnix=${Date.now()/1e3} />
        `}

        ${(S.length>0||!I||I.kind!=="ready")&&u`
          <div class="kp-queue-strip" aria-label="대기 중인 큐 작업">
            <div class="kp-queue-row">
              <span class="kp-kv-k">
                ${S.length?`대기열 (${S.length})`:"대기열"}${I?.kind==="ready"&&I.refreshing?" · 갱신 중…":""}
              </span>
              <button type="button" class="btn-ghost" aria-label="대기열 새로고침"
                onClick=${()=>to.current()}>새로고침</button>
            </div>
            ${(!I||I.kind==="loading")&&u`<div role="status">대기열 조회 중…</div>`}
            ${I?.kind==="error"&&u`
              <div role="status" title=${I.message}>
                ${S.length>0?"이전에 조회한 대기열입니다.":"대기열을 불러오지 못했습니다."}
              </div>
            `}
            <div class="kp-queue-rows">
              ${S.map(p=>{const m=I?.kind!=="ready"||I.refreshing===!0;return u`
                  <div key=${p.operationId} class="kp-queue-row">
                    <span class="kp-roster-name">${p.message||p.operationId}</span>
                    <div class="kp-pill-row">
                      ${se&&u`
                        <button type="button" class="btn-ghost" disabled=${m}
                          onClick=${()=>{io(p.operationId,cd)}}>
                          지금 실행
                        </button>
                      `}
                      <button type="button" class="btn-ghost" disabled=${m}
                        onClick=${()=>{io(p.operationId,ld)}}>
                        뒤로
                      </button>
                      <button type="button" class="kp-btn-danger" disabled=${m}
                        onClick=${()=>{io(p.operationId,id)}}>
                        취소
                      </button>
                    </div>
                  </div>
                `})}
            </div>
          </div>
        `}

        ${Ve&&u`
          <section class="kp-btw-box" aria-label="/btw 사이드 질의">
            <div class="kp-card-head">
              <h3>/btw Ephemeral Side-Query</h3>
              <button type="button" class="btn-ghost" onClick=${()=>vt(!1)}>닫기</button>
            </div>
            <div class="kp-lifecycle-bar">
              <input
                type="text"
                class="kp-input"
                placeholder="임시 사이드 질문을 입력하세요…"
                value=${H}
                onInput=${p=>Ie(p.currentTarget.value)}
                onKeyDown=${p=>{if(!(p.isComposing||p.keyCode===229)){if(p.key==="Escape"){p.preventDefault(),p.stopPropagation(),vt(!1);return}if(p.key==="Enter"){if(p.preventDefault(),ae.status==="streaming"||!H.trim())return;const m=H;Ie(""),co(m)}}}}
              />
              <button
                type="button"
                class="btn-primary"
                disabled=${ae.status==="streaming"}
                onClick=${()=>{const p=H;Ie(""),co(p)}}
              >
                질의
              </button>
            </div>
            ${ae.status!=="idle"&&u`
              <div class="kp-msg-body">
                <strong>Q:</strong>
                <${zt} text=${ae.prompt} />
                ${ae.reply?u`<${zt} text=${ae.reply} streaming=${ae.status==="streaming"} />`:ae.status==="streaming"&&u`<div>응답 수신 중…</div>`}
                ${ae.error&&u`<div class="ap-error">${ae.error}</div>`}
              </div>
            `}
          </section>
        `}

        <!-- Hermes-style Composer Footer -->
        <${kl}
          className="kp-composer"
          items=${De}
          onChange=${Pe}
          showTrigger=${!1}
          pickerRef=${bs}
          onError=${p=>g(p)}
        >
          ${(mo||gn)&&u`
            <div class="kp-turn-progress">
              ${mo&&u`
                <div class="kp-turn-progress-active" data-tone=${As} data-live=${hr?"true":"false"}>
                  ${Gt&&u`<span class="kp-live-dot" aria-hidden="true"></span>`}
                  <span class="kp-turn-progress-line">
                    <span role="status">
                      <strong>${zi}</strong>
                      ${an&&(!hr||Gt)&&u`<span> · ${an.phrase}</span>`}
                    </span>
                    ${an&&an.sinceUnix!==null&&Gt&&u`
                      <span> · </span><${Ed} sinceUnix=${an.sinceUnix} />
                    `}
                    <span> · ${Cs}</span>
                    ${Ps!==null&&ws!==void 0&&u`
                      <span> </span><${gi} key=${ot?.owner_key??ot?.turn_ref??ot?.started_at_unix} startedAt=${Ps} observedAt=${ws} live=${Gt} />
                    `}
                  </span>
                </div>
              `}
              ${gn&&yo&&u`
                <span class="kp-turn-worked" role="status">
                  <span aria-hidden="true">✓ </span><strong>Worked</strong>
                  ${` · ${fn(gn.elapsedMs/1e3)} · 최근 성공 `}
                  <time datetime=${yo.toISOString()} title=${yo.toLocaleString()}>${Lo(gn.atUnix)}</time>
                </span>
              `}
            </div>
          `}

          <textarea
            ref=${eo}
            class="kp-textarea"
            rows=${3}
            placeholder=${`${t.name}에게 메시지 전송 (Enter: Queue · ⌘↵: Steer · 이미지 붙여넣기/드롭 · /btw <질문>)`}
            aria-label="Keeper 채팅 입력"
            value=${M}
            onInput=${p=>re(p.currentTarget.value)}
            onKeyDown=${qi}
          />

          <input
            ref=${ys}
            type="file"
            accept="audio/*"
            class="kp-hidden-input"
            onChange=${p=>{Fi(p)}}
          />

          <div class="kp-composer-footer">
            <div class="kp-composer-meta">
              <!-- Circular SVG Context Ring % (zero inline HTML style) -->
              <span class="kp-ctx-ring" title=${Ur(t).tooltip}>
                <svg class="kp-ring-svg" viewBox="0 0 22 22" aria-hidden="true">
                  <circle class="kp-ring-track" cx="11" cy="11" r="8.5" />
                  <circle
                    class="kp-ring-fill"
                    data-tone=${ji}
                    cx="11"
                    cy="11"
                    r="8.5"
                    stroke-dasharray=${Mo.toFixed(2)}
                    stroke-dashoffset=${Hi.toFixed(2)}
                  />
                </svg>
                <span>Ctx ${kr.kind==="value"?Ur(t).label:os(kr,p=>`${p}%`)}</span>
              </span>

              <button
                type="button"
                class="btn-ghost"
                onClick=${()=>bs.current?.()}
              >
                첨부
              </button>
              ${se&&u`
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${lt}
                  onClick=${()=>ys.current?.click()}
                >
                  ${lt?"STT 인식 중…":"음성 STT"}
                </button>
              `}
            </div>

            <div class="kp-composer-actions">
              <button
                type="button"
                class="btn-ghost"
                disabled=${tt||Eo(De)||To(De)}
                onClick=${()=>{gr("queue")}}
              >
                Queue ↵
              </button>
              <button
                type="button"
                class="btn-primary"
                disabled=${tt||Eo(De)||To(De)}
                onClick=${()=>{gr("steer")}}
              >
                Steer ⌘↵
              </button>
            </div>
          </div>
        <//>
      </div>

      ${j&&u`
        <${_a} label="Keeper Debug" fallback=${()=>u`
          <aside class="kp-companion" aria-label="Debug Companion (⌘.)">
            <div class="kp-companion-head">
              <span role="alert">Debug 패널을 불러오지 못했습니다.</span>
              <button type="button" class="btn-ghost" onClick=${()=>A(!1)}>닫기</button>
            </div>
          </aside>
        `}>
          <${Nr} fallback=${u`
            <aside class="kp-companion" role="status">
              <div class="kp-companion-head">Debug 불러오는 중…</div>
            </aside>
          `}>
            <${ap}
              keeperName=${t.name}
              onClose=${()=>A(!1)}
              onInspect=${e.onInspect}
              onMutated=${e.onMutated}
            />
          </${Nr}>
        </${_a}>
      `}
    </div>
  `}const Wr="/api/v1/auth/keepers",$i="/api/v1/auth/keepers/assign",Ei="/api/v1/auth/keepers/turn",Pn="/api/v1/auth/keepers/conversation",Ti="/api/v1/auth/provider-accounts",or=4096,ba=128,hp=864e13,bp=/^[A-Za-z0-9._-]+$/,yp=/^[ \t\n\f\r]*$/,$p=["not_signed_in","key_refused","no_quota","silent","not_started","configuration_refused","no_answer"],Ep=["keeper_chat_operation_event","keeper_chat_appended","keeper_turn_preview_changed","keeper_tool_call","keeper_tool_approval_waits_changed","keeper_lifecycle","keeper_compaction","keeper_handoff","keeper_guardrail"],Tp=new Set(Ep);function Si(e){return new TextEncoder().encode(e).length}function Sp(e){const t=e.trim();return t.length===0?{ok:!1,error:"Keeper 이름을 입력하세요."}:t==="."||t===".."?{ok:!1,error:"예약된 경로 이름(. 또는 ..)은 사용할 수 없습니다."}:t.length>ba?{ok:!1,error:`Keeper 이름은 최대 ${ba}자까지 입력할 수 있습니다.`}:bp.test(t)?{ok:!0,value:t}:{ok:!1,error:"Keeper 이름은 영문, 숫자, 마침표(.), 밑줄(_), 하이픈(-)만 사용할 수 있습니다."}}function xp(e){const t=Si(e);return yp.test(e)?{ok:!1,reason:"blank",bytes:t}:t>or?{ok:!1,reason:"too_long",bytes:t}:{ok:!0,bytes:t}}function Le(e,t,n){const r=lr(e,t,n);if(r.trim().length===0)throw new Error(`${n}: "${t}" 필드는 비어 있지 않은 문자열이어야 합니다.`);return r}function ts(e,t,n){if(!(t in e))throw new Error(`${n}: "${t}" 필드가 누락되었습니다 (null 또는 문자열 필요).`);const r=e[t];if(r===null)return null;if(typeof r!="string"||r.trim().length===0)throw new Error(`${n}: "${t}" 필드는 null 또는 비어 있지 않은 문자열이어야 합니다 (${cr(r)} 수신).`);return r}function Rp(e,t,n){if(!(t in e))throw new Error(`${n}: "${t}" 필드가 누락되었습니다 (null 또는 문자열 필요).`);const r=e[t];if(r===null)return null;if(typeof r!="string")throw new Error(`${n}: "${t}" 필드는 null 또는 문자열이어야 합니다 (${cr(r)} 수신).`);return r}function Ir(e,t,n){const r=e[t];if(r===void 0)return null;if(typeof r!="string"||r.trim().length===0)throw new Error(`${n}: "${t}" 필드는 문자열이어야 합니다 (${cr(r)} 수신).`);return r}function ns(e,t,n){const r=e[t];if(typeof r!="boolean")throw new Error(`${n}: "${t}" 필드는 필수 불리언입니다 (${cr(r)} 수신).`);return r}function Br(e,t,n){const r=Ll(e,t,n);if(!Number.isSafeInteger(r)||r<0||r>hp)throw new Error(`${n}: "${t}" 필드는 유효한 epoch 밀리초 정수여야 합니다 (${r} 수신).`);return r}function Ap(e){const t=`GET ${Wr}`,n=Zt(e,t),r=ar(n,"keepers",t),o=ir(r,"keepers",t),i=new Set,s=[];for(let a=0;a<o.length;a+=1){const _=o[a],f=`${t} keepers[${a}]`,c=Le(_,"keeper_id",f),k=ts(_,"runtime_id",f);if(i.has(c))throw new Error(`${t}: 중복된 keeper_id "${c}"가 응답에 포함되었습니다.`);i.add(c),s.push({keeper_id:c,runtime_id:k})}return s}function Cp(e){const t=`GET ${Ti}`,n=Zt(e,t),r=ar(n,"provider_accounts",t),o=ir(r,"provider_accounts",t),i=ar(n,"runtimes",t),s=ir(i,"runtimes",t),a=new Map,_=[];for(let k=0;k<o.length;k+=1){const b=o[k],l=`${t} provider_accounts[${k}]`,g=Le(b,"provider_account_id",l),v=Le(b,"integration_id",l),E=Le(b,"kind",l);if(E!=="login"&&E!=="key")throw new Error(`${l}: "kind" 필드는 "login" 또는 "key"여야 합니다 ("${E}" 수신).`);if(a.has(g))throw new Error(`${t}: 중복된 provider_account_id "${g}"가 응답에 포함되었습니다.`);const I={provider_account_id:g,kind:E,integration_id:v,key:Ir(b,"key",l),removal:Ir(b,"removal",l),replacement:Ir(b,"replacement",l)};a.set(g,I),_.push(I)}const f=new Set,c=[];for(let k=0;k<s.length;k+=1){const b=s[k],l=`${t} runtimes[${k}]`,g=Le(b,"runtime_id",l),v=Le(b,"provider_account_id",l),E=Rp(b,"model",l),I=Ir(b,"unread",l);if(f.has(g))throw new Error(`${t}: 중복된 runtime_id "${g}"가 응답에 포함되었습니다.`);f.add(g);const S=a.get(v);c.push({runtime_id:g,provider_account_id:v,integration_id:S?.integration_id??null,account_kind:S?.kind??null,model:E,unread:I})}return{provider_accounts:_,runtimes:c}}function Ip(e,t){const n=`POST ${Wr}`,r=Zt(e,n),o=Le(r,"keeper_id",n);if(o!==t)throw new Error(`${n}: 응답 keeper_id("${o}")가 요청한 "${t}"와 다릅니다.`);const i=Le(r,"record",n);if(i!=="made"&&i!=="existing")throw new Error(`${n}: "record" 필드는 "made" 또는 "existing"이어야 합니다 ("${i}" 수신).`);return{keeper_id:o,record:i}}function Op(e,t,n){const r=`POST ${$i}`,o=Zt(e,r),i=Le(o,"keeper_id",r),s=Le(o,"runtime_id",r);if(i!==t)throw new Error(`${r}: 응답 keeper_id("${i}")가 요청한 "${t}"와 다릅니다.`);if(s!==n)throw new Error(`${r}: 응답 runtime_id("${s}")가 요청한 "${n}"와 다릅니다.`);const a=Le(o,"record",r);if(a!=="assigned"&&a!=="existing")throw new Error(`${r}: "record" 필드는 "assigned" 또는 "existing"이어야 합니다 ("${a}" 수신).`);return{keeper_id:i,runtime_id:s,record:a}}function wp(e,t){const n=Le(e,"outcome",t);if(n==="answered"){const r=lr(e,"text",t),o=lr(e,"model",t),i=Br(e,"answered_at_ms",t);return{outcome:"answered",text:r,model:o,answered_at_ms:i}}if(n==="failed"){const r=Le(e,"failure",t),o=$p.find(a=>a===r),i=Br(e,"failed_at_ms",t),s=ns(e,"model_may_have_read",t);return{outcome:"failed",failure:o??"unrecognised",raw_failure:r,failed_at_ms:i,model_may_have_read:s}}if(n==="unrecorded")return{outcome:"unrecorded",model_may_have_read:ns(e,"model_may_have_read",t)};throw new Error(`${t}: 알 수 없는 outcome 값 "${n}"입니다.`)}function Pp(e,t,n){const r=`GET ${Pn}`,o=Zt(e,r),i=Le(o,"keeper_id",r);if(i!==t)throw new Error(`${r}: 응답 keeper_id("${i}")가 요청한 "${t}"와 다릅니다.`);const s=ts(o,"current_conversation_id",r),a=ts(o,"conversation_id",r);if(n){if(a!==n)throw new Error(`${r}: 응답 conversation_id("${String(a)}")가 요청한 "${n}"와 다릅니다.`)}else if(a!==s)throw new Error(`${r}: 현재 대화 조회 응답의 conversation_id("${String(a)}")와 current_conversation_id("${String(s)}")가 일치하지 않습니다.`);const _=ar(o,"conversations",r),f=ir(_,"conversations",r),c=new Set,k=[];for(let v=0;v<f.length;v+=1){const E=f[v],I=`${r} conversations[${v}]`,S=Le(E,"conversation_id",I),M=Le(E,"provider_account_id",I),w=Br(E,"started_at_ms",I);let D=null;if("deletion"in E&&E.deletion!==void 0){if(E.deletion!=="failed")throw new Error(`${I}: "deletion" 필드는 생략되거나 "failed"여야 합니다 (${cr(E.deletion)} 수신).`);D="failed"}if(c.has(S))throw new Error(`${r}: 중복된 conversation_id "${S}"가 응답에 포함되었습니다.`);c.add(S),k.push({conversation_id:S,provider_account_id:M,started_at_ms:w,deletion:D})}if(s!==null&&!c.has(s))throw new Error(`${r}: current_conversation_id("${s}")가 conversations 목록에 없습니다.`);if(a!==null&&!c.has(a))throw new Error(`${r}: conversation_id("${a}")가 conversations 목록에 없습니다.`);const b=ar(o,"turns",r),l=ir(b,"turns",r);if(a===null&&l.length>0)throw new Error(`${r}: conversation_id가 null인데 turns가 ${l.length}건 존재합니다.`);const g=[];for(let v=0;v<l.length;v+=1){const E=l[v],I=`${r} turns[${v}]`,S=lr(E,"message",I),M=Br(E,"asked_at_ms",I),w=wp(E,I);g.push({message:S,asked_at_ms:M,outcome:w})}return{keeper_id:i,current_conversation_id:s,conversations:k,conversation_id:a,turns:g}}function Kp(e,t){const n=`POST ${Ei}`,r=Zt(e,n),o=Le(r,"keeper_id",n);if(o!==t)throw new Error(`${n}: 응답 keeper_id("${o}")가 요청한 "${t}"와 다릅니다.`);const i=Le(r,"runtime_id",n),s=Le(r,"model",n),a=lr(r,"text",n),_=r.conversation_id!==void 0,f=r.continued!==void 0;if(_!==f)throw new Error(`${n}: conversation_id와 continued 필드는 함께 있거나 함께 생략되어야 합니다.`);if(_){const c=Le(r,"conversation_id",n),k=ns(r,"continued",n);return{keeper_id:o,runtime_id:i,model:s,text:a,recorded:!0,conversation_id:c,continued:k}}return{keeper_id:o,runtime_id:i,model:s,text:a,recorded:!1,conversation_id:null,continued:null}}function Np(e,t){const n=`POST ${Pn}`,r=Zt(e,n),o=Le(r,"keeper_id",n);if(o!==t)throw new Error(`${n}: 응답 keeper_id("${o}")가 요청한 "${t}"와 다릅니다.`);const i=Le(r,"conversation_id",n);return{keeper_id:o,conversation_id:i}}function Mp(e,t){const n=`DELETE ${Pn}/${t}`,r=Zt(e,n),o=Le(r,"conversation_id",n);if(o!==t)throw new Error(`${n}: 응답 conversation_id("${o}")가 요청한 "${t}"와 다릅니다.`);const i=Le(r,"vendor_copy",n);if(i!=="removed"&&i!=="none"&&i!=="may_remain")throw new Error(`${n}: "vendor_copy" 필드는 "removed", "none", "may_remain" 중 하나여야 합니다 ("${i}" 수신).`);return{conversation_id:o,vendor_copy:i}}function Ye(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}function Lp(e){if(!Tn(e.data))return null;const t=e.data,n=Tn(t.payload)?t.payload:Tn(t.params)?t.params:t,r=Ye(n.type)??Ye(t.type)??Ye(e.event);if(!r||!Tp.has(r))return null;const o=r,i=Ye(n.name)??Ye(n.keeper)??Ye(n.keeper_name)??Ye(t.name)??Ye(t.keeper)??Ye(t.keeper_name),s=Tn(n.observation)?n.observation:null,a=s&&Tn(s.preview)?s.preview:Tn(n.preview)?n.preview:null,_=(a&&Ye(a.status_text))??Ye(n.status_text),f=(a&&Ye(a.activity))??Ye(n.activity),c=(a&&Ye(a.text_tail))??Ye(n.text_tail),k=Ye(n.tool)??Ye(n.tool_name),b=Ye(n.state)??Ye(n.phase),l=[_,f&&_!==f?f:null,k?`tool:${k}`:null,b].filter(v=>v!==null),g=l.length>0?l.join(" · "):o;return{eventType:o,keeper:i,summary:g,textTail:c,activity:f,refreshKeepers:o==="keeper_lifecycle"||o==="keeper_handoff"||o==="keeper_compaction",refreshConversation:o==="keeper_chat_appended"||o==="keeper_chat_operation_event",receivedAtMs:Date.now()}}function en(){return _e.peek().kind!=="multi_account_signed_in"?$t({kind:"forbidden",status:null,code:"multi_account_required",message:"개인 Keeper API(/api/v1/auth/keepers)는 멀티 계정 로그인 세션 전용입니다.",retryable:!1}):{ok:!0,value:!0}}function Dp(e){const t=en();return t.ok?we(Wr,{signal:e,decode:Ap}):Promise.resolve(t)}function Up(e){const t=en();return t.ok?we(Ti,{signal:e,decode:Cp}):Promise.resolve(t)}function Bp(e,t){const n=en();return n.ok?He("POST",Wr,{keeper_id:e},{signal:t,decode:r=>Ip(r,e)}):Promise.resolve(n)}function xi(e,t,n){const r=en();return r.ok?He("POST",$i,{keeper_id:e,runtime_id:t},{signal:n,decode:o=>Op(o,e,t)}):Promise.resolve(r)}function qp(e,t,n){const r=en();if(!r.ok)return Promise.resolve(r);const o=new URLSearchParams;return o.set("keeper_id",e),t&&o.set("conversation_id",t),we(`${Pn}?${o.toString()}`,{signal:n,decode:i=>Pp(i,e,t)})}function Fp(e,t){const n=en();return n.ok?He("POST",Pn,{keeper_id:e},{signal:t,decode:r=>Np(r,e)}):Promise.resolve(n)}function Hp(e,t,n){const r=en();return r.ok?He("POST",Ei,{keeper_id:e,message:t},{signal:n,decode:o=>Kp(o,e)}):Promise.resolve(r)}function jp(e,t){const n=en();return n.ok?He("DELETE",`${Pn}/${encodeURIComponent(e)}`,void 0,{signal:t,decode:r=>Mp(r,e)}):Promise.resolve(n)}function Gp(e,t){switch(e){case"not_signed_in":return"이 런타임의 공급자 계정이 로그인되어 있지 않습니다. Runtime → Quotas에서 다시 로그인하세요.";case"key_refused":return"공급자가 이 런타임의 API 키를 거부했습니다. Runtime → Quotas에서 키를 교체하세요.";case"no_quota":return"이 런타임 계정의 남은 할당량이 없습니다. 할당량이 복구된 뒤 다시 시도하세요.";case"silent":return"클라이언트가 제한 시간 동안 응답을 보내지 않아 턴이 중단되었습니다.";case"not_started":return"모델 클라이언트를 시작하지 못했습니다. 잠시 뒤 다시 시도하세요.";case"configuration_refused":return"클라이언트가 이 런타임의 설정을 거부했습니다. 서버 관리자에게 문의하세요.";case"no_answer":return"Keeper가 응답을 남기지 않고 턴을 종료했습니다. 반복되면 새 대화를 시작하세요.";case"unrecognised":return`알 수 없는 턴 실패 코드 (${t})`}}function Wp(e){switch(e){case"removed":return"대화와 공급자 측 사본을 모두 삭제했습니다.";case"none":return"대화 기록을 삭제했습니다.";case"may_remain":return"로컬 대화 기록은 삭제했지만 공급자 측 사본이 남아 있을 수 있습니다."}}function Bt(e,t){if(e.kind==="decode")return`서버 응답 형식이 계약과 다릅니다: ${e.message}`;if(e.kind==="unauthorized")return"세션이 만료되었거나 인증이 필요합니다. Account에서 다시 로그인하세요.";if(e.kind==="csrf_rejected")return"CSRF 검증이 거부되었습니다. 잠시 뒤 다시 시도하세요.";switch(e.code){case"message_too_long":return`메시지가 최대 ${or}바이트를 초과했습니다.`;case"message_blank":return"비어 있는 메시지는 보낼 수 없습니다.";case"keeper_has_no_runtime":return"이 Keeper에 연결된 런타임이 없습니다. 먼저 개인 런타임을 연결하세요.";case"account_call_running":return"이 런타임 계정에서 다른 호출이 진행 중입니다. 완료된 뒤 다시 시도하세요.";case"conversation_on_other_subscription":return"현재 대화가 다른 공급자 계정에서 시작되었습니다. 새 대화를 시작해 이어가세요.";case"runtime_reassigned":return"요청 도중 Keeper의 런타임이 변경되었습니다. 다시 시도하세요.";case"runtime_not_supported":return"이 런타임에서는 개인 Keeper 대화를 실행할 수 없습니다. 다른 런타임을 선택하세요.";case"native_tools_refused":return"멀티 계정 정책상 네이티브 도구가 필요한 이 런타임은 실행할 수 없습니다. 다른 런타임을 선택하세요.";case"account_runtime_invalid":return`런타임 설정이 유효하지 않습니다: ${e.message}`;case"turn_refused":return`턴 실행이 거부되었습니다: ${e.message}`;case"deletion_refused":return"계정이 비활성 상태여서 대화를 삭제할 수 없습니다.";case"unknown_keeper":return"소유한 Keeper 목록에서 대상을 찾을 수 없습니다. 목록을 새로고침하세요.";case"unknown_conversation":return"해당 대화를 찾을 수 없습니다. 이미 삭제되었을 수 있습니다.";case"unknown_account":return"런타임에 연결된 공급자 계정을 찾을 수 없습니다. Runtime → Quotas를 확인하세요.";case"not_signed_in":return"이 런타임의 공급자 계정이 로그인되어 있지 않습니다. Runtime → Quotas에서 연결하세요.";case"key_missing":return"이 런타임의 API 키가 서버에 없습니다. Runtime → Quotas에서 키를 등록하세요.";case"key_unreadable":return"서버가 이 런타임의 API 키를 읽을 수 없습니다. Runtime → Quotas에서 키를 교체하세요.";case"key_refused":return"공급자가 이 런타임의 API 키를 거부했습니다. Runtime → Quotas에서 키를 교체하세요.";case"no_quota":return"이 런타임 계정의 남은 할당량이 없습니다.";case"silent":return"클라이언트가 제한 시간 동안 응답하지 않아 중단되었습니다.";case"not_started":return"클라이언트를 시작하지 못했습니다. 잠시 뒤 다시 시도하세요.";case"configuration_refused":return"클라이언트가 이 런타임의 설정을 거부했습니다.";case"no_answer":return"Keeper가 답을 남기지 않고 종료했습니다. 계속 반복되면 새 대화를 시작하세요.";case"answer_unrecorded":return"Keeper가 응답했지만 서버가 대화 기록에 저장하지 못했습니다.";case"conversation_row_half_written":return"이전 중단으로 대화 기록 마지막 줄이 불완전합니다. 새 대화를 시작하면 정리됩니다.";case"conversation_row_not_understood":return"대화 기록에 해석할 수 없는 줄이 있습니다. 서버 관리자에게 문의하세요.";case"conversation_record_unavailable":return"대화 기록을 읽거나 쓸 수 없습니다. 잠시 뒤 다시 시도하세요.";case"conversation_not_deleted":return"대화 파일을 완전히 삭제하지 못해 삭제 실패 상태로 표시되었습니다. 다시 삭제를 시도하세요.";case"invalid_request":return`요청 형식이 올바르지 않습니다: ${e.message}`;case"server_unavailable":case"internal_error":return e.message;default:return e.kind==="forbidden"?t==="read"?"대화 기록 조회 권한(manage_own_keeper + read_state)이 부족하거나 계정이 비활성 상태입니다.":`요청 권한이 거부되었습니다 (403): ${e.message}`:e.message}}function xn(e){const t=new Date(e);return Number.isNaN(t.getTime())?String(e):t.toLocaleString([],{month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit"})}function ya(e){return e.length>12?`${e.slice(0,10)}…`:e}function Vp(e){const{keeper:t,assignedRuntime:n,observerSignal:r,externalRefreshTick:o}=e,[i,s]=F(null),[a,_]=F(null),[f,c]=F(!0),[k,b]=F(null),[l,g]=F(""),[v,E]=F(null),[I,S]=F(!1),[M,w]=F(null),[D,re]=F(null),[W,z]=F(null),[ce,xe]=F(null),te=X(!0),se=X(t.keeper_id),ue=X(null),Y=X(null),de=X(!1),Me=X(!1),Ce=X(o),De=X(o),ke=X(i);se.current=t.keeper_id,Me.current=de.current||v!==null||I||D!==null,Ce.current=o,ke.current=i,Se(()=>(te.current=!0,()=>{te.current=!1,ue.current?.abort("unmount"),Y.current?.abort("unmount")}),[]);const me=be(async j=>{if(_e.peek().kind!=="multi_account_signed_in")return;ue.current?.abort("superseded");const A=new AbortController;ue.current=A;const V=t.keeper_id,ne=Te();c(!0),b(null);const le=await qp(V,j,A.signal);if(!(!te.current||se.current!==V||!ie(ne)||A.signal.aborted||_e.peek().kind!=="multi_account_signed_in")){if(c(!1),!le.ok){if(le.error.kind==="aborted"||le.error.kind==="epoch_stale")return;_(null),b(Bt(le.error,"read"));return}_(le.value),b(null)}},[t.keeper_id]);Se(()=>(De.current=Ce.current,ke.current=null,s(null),_(null),b(null),z(null),w(null),re(null),S(!1),E(null),xe(null),de.current=!1,Y.current?.abort("keeper_changed"),me(null),()=>{de.current=!1,ue.current?.abort("effect_cleanup"),Y.current?.abort("effect_cleanup")}),[t.keeper_id,me]),Se(()=>{o!==De.current&&(De.current=o,!Me.current&&me(ke.current))},[o,me]);const Pe=v!==null||I||D!==null,Ue=i!==null&&(a===null||i!==a.current_conversation_id),pe=j=>{if(Pe||j.deletion==="failed")return;const A=a&&j.conversation_id===a.current_conversation_id?null:j.conversation_id;ke.current=A,s(A),z(null),xe(null),me(A)},Et=async()=>{if(de.current||Pe||_e.peek().kind!=="multi_account_signed_in")return;if(t.runtime_id===null){z("먼저 상단에서 개인 런타임을 연결한 뒤 새 대화를 시작하세요.");return}de.current=!0,Y.current?.abort("superseded");const j=new AbortController;Y.current=j;const A=t.keeper_id,V=Te();S(!0),z(null),w(null);try{const ne=await Fp(A,j.signal);if(!te.current||se.current!==A||!ie(V)||j.signal.aborted||_e.peek().kind!=="multi_account_signed_in")return;if(Y.current===j&&(de.current=!1),S(!1),!ne.ok){if(ne.error.kind==="aborted"||ne.error.kind==="epoch_stale")return;z(Bt(ne.error,"start")),ne.error.kind!=="unauthorized"&&ne.error.kind!=="csrf_rejected"&&await me(ke.current);return}ke.current=null,s(null),xe(null),In("새 대화를 시작했습니다.","success"),await me(null)}finally{Y.current===j&&(de.current=!1,te.current&&S(!1))}},tt=async j=>{if(de.current||Pe||_e.peek().kind!=="multi_account_signed_in")return;de.current=!0,Y.current?.abort("superseded");const A=new AbortController;Y.current=A;const V=t.keeper_id,ne=Te();re(j),z(null);try{const le=await jp(j,A.signal);if(!te.current||se.current!==V||!ie(ne)||A.signal.aborted||_e.peek().kind!=="multi_account_signed_in")return;if(Y.current===A&&(de.current=!1),re(null),w(null),!le.ok){if(le.error.kind==="aborted"||le.error.kind==="epoch_stale"||(z(Bt(le.error,"delete")),le.error.kind==="unauthorized"||le.error.kind==="csrf_rejected"))return;const Ne=ke.current===j,Ve=le.error.code==="conversation_not_deleted"||le.error.code==="unknown_conversation"||le.error.kind==="server"||le.error.kind==="network"||le.error.kind==="decode";Ne&&Ve?(ke.current=null,s(null),await me(null)):await me(ke.current);return}const ae=ke.current===j?null:ke.current;ae!==ke.current&&(ke.current=ae,s(ae)),In(Wp(le.value.vendor_copy),le.value.vendor_copy==="may_remain"?"info":"success"),await me(ae)}finally{Y.current===A&&(de.current=!1,te.current&&re(null))}},Ke=async()=>{if(de.current||Pe||Ue||_e.peek().kind!=="multi_account_signed_in")return;if(t.runtime_id===null){z("먼저 상단에서 개인 런타임을 연결하세요.");return}const j=xp(l);if(!j.ok){z(j.reason==="blank"?"보낼 메시지를 입력하세요 (공백만으로는 전송할 수 없습니다).":`메시지가 ${or}바이트를 초과했습니다 (현재 ${j.bytes}B).`);return}de.current=!0,Y.current?.abort("superseded");const A=new AbortController;Y.current=A;const V=t.keeper_id,ne=Te(),le=l;E(le),z(null),w(null);try{const ae=await Hp(V,le,A.signal);if(!te.current||se.current!==V||!ie(ne)||A.signal.aborted||_e.peek().kind!=="multi_account_signed_in")return;if(Y.current===A&&(de.current=!1),E(null),!ae.ok){if(ae.error.kind==="aborted"||ae.error.kind==="epoch_stale")return;z(Bt(ae.error,"turn")),ae.error.kind!=="unauthorized"&&ae.error.kind!=="csrf_rejected"&&await me(null);return}g(""),ke.current=null,s(null),ae.value.recorded?xe(null):xe({message:le,text:ae.value.text,model:ae.value.model,runtimeId:ae.value.runtime_id,atMs:Date.now()}),await me(null)}finally{Y.current===A&&(de.current=!1,te.current&&E(null))}},lt=Si(l),ye=lt>or,nt=a?.conversations??[],ct=a?.turns??[];return u`
    <div class="kp-chat-shell" data-keeper-tab="chat" data-testid="ma-keeper-chat">
      <div class="kp-chat-main">
        <!-- Conversation Toolbar -->
        <div class="kp-chat-toolbar">
          <div class="kp-pill-row">
            <span class="kp-pill" data-tone=${a?.conversation_id?"info":"default"}>
              ${a?.conversation_id?`대화 ${ya(a.conversation_id)}${Ue?" (이전 기록)":" (현재)"}`:"진행 중인 대화 없음"}
            </span>
            <span class="kp-pill">전체 대화 ${nt.length}건</span>
            ${n?.model&&u`
              <span class="kp-pill" data-tone="brass">${n.model}</span>
            `}
          </div>
          <div class="kp-pill-row">
            <button
              type="button"
              class="btn-ghost"
              disabled=${Pe}
              onClick=${()=>{me(i)}}
            >
              새로고침
            </button>
            <button
              type="button"
              class="btn-primary"
              data-testid="ma-new-conversation-btn"
              disabled=${Pe||t.runtime_id===null}
              onClick=${()=>{Et()}}
            >
              ${I?u`<${nr} size="xs" /> 시작 중…`:"+ 새 대화"}
            </button>
          </div>
        </div>

        ${r&&u`
          <div
            class="kp-ma-observer-strip"
            data-testid="ma-keeper-observer-signal"
            role="status"
          >
            <span class="kp-pill" data-tone="brass">LIVE /auth/events</span>
            <span class="kp-roster-sub">
              ${r.eventType}${r.keeper?` · ${r.keeper}`:""} · ${r.summary}
            </span>
            ${r.textTail&&u`
              <span class="kp-live-turn-tail">${r.textTail}</span>
            `}
          </div>
        `}

        ${nt.length>0&&u`
          <div class="kp-ma-conv-bar" role="region" aria-label="개인 Keeper 대화 목록">
            ${nt.map(j=>{const A=j.conversation_id===a?.current_conversation_id,V=j.conversation_id===a?.conversation_id,ne=j.deletion==="failed",le=M===j.conversation_id,ae=D===j.conversation_id;return u`
                <div
                  key=${j.conversation_id}
                  class="kp-ma-conv-item"
                  data-active=${V?"true":"false"}
                  data-failed=${ne?"true":"false"}
                  data-conversation-id=${j.conversation_id}
                >
                  <button
                    type="button"
                    class="kp-ma-conv-select"
                    disabled=${Pe||ne}
                    aria-pressed=${V?"true":"false"}
                    title=${`${j.conversation_id} (${j.provider_account_id})`}
                    onClick=${()=>pe(j)}
                  >
                    <span class="kp-roster-name">
                      ${ya(j.conversation_id)}
                    </span>
                    <span class="kp-roster-sub">
                      ${xn(j.started_at_ms)}
                      ${A?" · 현재":""}
                      ${ne?" · 삭제 실패":""}
                    </span>
                  </button>
                  ${le?u`
                        <div class="kp-pill-row">
                          <button
                            type="button"
                            class="kp-btn-danger"
                            data-testid=${`ma-confirm-delete-${j.conversation_id}`}
                            disabled=${Pe}
                            onClick=${()=>{tt(j.conversation_id)}}
                          >
                            ${ae?"삭제 중…":"삭제 확인"}
                          </button>
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${Pe}
                            onClick=${()=>w(null)}
                          >
                            취소
                          </button>
                        </div>
                      `:u`
                        <button
                          type="button"
                          class="btn-ghost kp-toggle-btn"
                          data-testid=${`ma-delete-conv-${j.conversation_id}`}
                          disabled=${Pe}
                          onClick=${()=>w(j.conversation_id)}
                        >
                          ${ne?"삭제 재시도":"삭제"}
                        </button>
                      `}
                </div>
              `})}
          </div>
        `}

        ${Ue&&u`
          <div class="kp-notice" data-tone="info" role="status" data-testid="ma-historical-banner">
            이전 대화 기록을 읽기 전용으로 보고 있습니다. 새 메시지를 보내려면 현재 대화로 이동하세요.
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>{ke.current=null,s(null),me(null)}}
            >
              현재 대화로 이동
            </button>
          </div>
        `}

        <!-- Transcript Stage -->
        <div class="kp-chat-stage">
          <div class="kp-chat-list" aria-label="대화 기록">
            <div class="kp-chat-feed">
              ${f&&!a&&u`
                <div class="kp-empty" role="status">
                  <${nr} size="xs" /> 대화 기록을 불러오는 중…
                </div>
              `}

              ${k&&u`
                <div class="kp-card" role="alert" data-testid="ma-conversation-error">
                  <div class="ap-error">${k}</div>
                  <div class="kp-lifecycle-bar">
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${()=>{me(i)}}
                    >
                      대화 다시 불러오기
                    </button>
                    ${i!==null&&u`
                      <button
                        type="button"
                        class="btn-ghost"
                        onClick=${()=>{ke.current=null,s(null),me(null)}}
                      >
                        현재 대화로 이동
                      </button>
                    `}
                    ${t.runtime_id!==null&&u`
                      <button
                        type="button"
                        class="btn-primary"
                        disabled=${Pe}
                        onClick=${()=>{Et()}}
                      >
                        새 대화로 복구
                      </button>
                    `}
                  </div>
                </div>
              `}

              ${!f&&!k&&ct.length===0&&!ce&&!v&&u`
                <div class="kp-empty" data-testid="ma-conversation-empty">
                  ${t.runtime_id===null?"이 개인 Keeper에 아직 런타임이 연결되지 않았습니다. 상단에서 개인 런타임을 연결한 뒤 대화를 시작하세요.":a?.conversation_id?"이 대화에 아직 기록된 턴이 없습니다. 아래에서 첫 메시지를 보내세요.":"아직 시작된 대화가 없습니다. 아래에서 메시지를 보내면 자동으로 대화가 시작됩니다."}
                </div>
              `}

              ${ct.map((j,A)=>u`
                <div key=${`${j.asked_at_ms}-${A}`} class="kp-ma-turn-pair" data-testid="ma-turn-pair">
                  <article class="kp-msg" data-role="user">
                    <div class="kp-msg-head">
                      <strong>나</strong>
                      <span class="kp-msg-time">${xn(j.asked_at_ms)}</span>
                    </div>
                    <div class="kp-msg-body kp-delegate-prompt">${j.message}</div>
                  </article>

                  ${j.outcome.outcome==="answered"&&u`
                    <article class="kp-msg" data-role="assistant">
                      <div class="kp-msg-head">
                        <span>
                          <strong>${t.keeper_id}</strong>
                          <span class="kp-pill">${j.outcome.model}</span>
                        </span>
                        <span class="kp-msg-time">${xn(j.outcome.answered_at_ms)}</span>
                      </div>
                      <div class="kp-msg-body">
                        <${zt} text=${j.outcome.text} />
                      </div>
                    </article>
                  `}

                  ${j.outcome.outcome==="failed"&&u`
                    <article class="kp-msg" data-role="request_failure" data-testid="ma-turn-failed">
                      <div class="kp-msg-head">
                        <strong>응답 실패 (${j.outcome.raw_failure})</strong>
                        <span class="kp-msg-time">${xn(j.outcome.failed_at_ms)}</span>
                      </div>
                      <div class="kp-msg-body">
                        ${Gp(j.outcome.failure,j.outcome.raw_failure)}
                      </div>
                      ${j.outcome.model_may_have_read&&u`
                        <div class="kp-roster-sub kp-wrap-text">
                          클라이언트가 요청을 시작했으므로 모델이 이 메시지를 읽었을 수 있습니다.
                        </div>
                      `}
                    </article>
                  `}

                  ${j.outcome.outcome==="unrecorded"&&u`
                    <article class="kp-msg" data-role="request_failure" data-testid="ma-turn-unrecorded">
                      <div class="kp-msg-head">
                        <strong>결과 미기록 (unrecorded)</strong>
                      </div>
                      <div class="kp-msg-body">
                        질문은 기록되었지만 응답 결과가 기록되지 않았습니다.
                        ${j.outcome.model_may_have_read?" 모델이 이 메시지를 읽었을 수 있습니다.":""}
                      </div>
                    </article>
                  `}
                </div>
              `)}

              ${ce&&u`
                <div class="kp-ma-turn-pair" data-testid="ma-ephemeral-reply">
                  <article class="kp-msg" data-role="user">
                    <div class="kp-msg-head">
                      <strong>나</strong>
                      <span class="kp-msg-time">${xn(ce.atMs)}</span>
                    </div>
                    <div class="kp-msg-body kp-delegate-prompt">${ce.message}</div>
                  </article>
                  <article class="kp-msg" data-role="assistant">
                    <div class="kp-msg-head">
                      <span>
                        <strong>${t.keeper_id}</strong>
                        <span class="kp-pill">${ce.model}</span>
                        <span class="kp-pill" data-tone="warn">일회성 응답 (미저장)</span>
                      </span>
                      <span class="kp-msg-time">${xn(ce.atMs)}</span>
                    </div>
                    <div class="kp-msg-body">
                      <${zt} text=${ce.text} />
                    </div>
                    <div class="kp-roster-sub kp-wrap-text">
                      이 런타임(${ce.runtimeId})의 응답은 서버 대화 기록에 저장되지 않습니다.
                    </div>
                  </article>
                </div>
              `}

              ${v!==null&&u`
                <div class="kp-ma-turn-pair" data-testid="ma-turn-pending">
                  <article class="kp-msg" data-role="user">
                    <div class="kp-msg-head">
                      <strong>나</strong>
                      <span class="kp-pill" data-tone="info">전송 중</span>
                    </div>
                    <div class="kp-msg-body kp-delegate-prompt">${v}</div>
                  </article>
                  <div class="kp-live-turn-card" role="status">
                    <div class="kp-turn-progress">
                      <span class="kp-live-dot" aria-hidden="true" />
                      <strong>${t.keeper_id} 응답 대기 중…</strong>
                      <span class="kp-roster-sub">동기 HTTP 요청 (최대 120초)</span>
                    </div>
                  </div>
                </div>
              `}
            </div>
          </div>
        </div>

        <!-- Composer -->
        <div class="kp-ma-composer">
          ${W&&u`
            <div class="ap-error" role="alert" data-testid="ma-turn-action-error">
              ${W}
            </div>
          `}
          <textarea
            class="kp-textarea"
            rows=${3}
            aria-label="개인 Keeper 메시지 입력"
            placeholder=${t.runtime_id===null?"먼저 상단에서 개인 런타임을 연결하세요…":Ue?"이전 대화는 읽기 전용입니다. 현재 대화로 이동해 메시지를 보내세요.":"개인 Keeper에게 보낼 메시지를 입력하세요… (⌘↵ / Ctrl+Enter 전송)"}
            disabled=${Pe||t.runtime_id===null||Ue}
            value=${l}
            onInput=${j=>{g(j.currentTarget.value),W&&z(null)}}
            onKeyDown=${j=>{j.isComposing||j.keyCode===229||(j.metaKey||j.ctrlKey)&&j.key==="Enter"&&!Pe&&!Ue&&(j.preventDefault(),Ke())}}
          />
          <div class="kp-ma-composer-foot">
            <div class="kp-pill-row">
              <span
                class="kp-pill"
                data-tone=${ye?"bad":lt>3600?"warn":"default"}
                data-testid="ma-composer-bytes"
              >
                ${lt} / ${or} B
              </span>
              ${t.runtime_id===null&&u`
                <button
                  type="button"
                  class="btn-ghost kp-toggle-btn"
                  onClick=${()=>e.onNavigate("/runtime/quotas")}
                >
                  Runtime → Quotas 열기
                </button>
              `}
            </div>
            <button
              type="button"
              class="btn-primary"
              data-testid="ma-send-turn-btn"
              disabled=${Pe||t.runtime_id===null||Ue||ye}
              onClick=${()=>{Ke()}}
            >
              ${v!==null?u`<${nr} size="xs" /> 대기 중…`:"메시지 보내기"}
            </button>
          </div>
        </div>
      </div>
    </div>
  `}function Ri(e){const t=[e.model??(e.unread?`모델 미확인: ${e.unread}`:"모델 미지정"),e.integration_id,e.account_kind==="key"?"API key":e.account_kind==="login"?"로그인":null].filter(Boolean);return`${e.runtime_id} (${t.join(" · ")})`}function zp(e){const{session:t}=e,n=is(e.entityTab),[r,o]=F([]),[i,s]=F(!0),[a,_]=F(null),[f,c]=F(null),[k,b]=F(null),[l,g]=F(""),[v,E]=F(e.entityId??null),[I,S]=F(!1),[M,w]=F(""),[D,re]=F(!1),[W,z]=F(null),[ce,xe]=F(null),[te,se]=F(0),ue=X(!0),Y=X(null),de=X(null),Me=X(null);Se(()=>(ue.current=!0,()=>{ue.current=!1,Y.current?.abort("unmount"),de.current?.abort("unmount"),Me.current?.abort("unmount")}),[]),Se(()=>{e.entityId&&E(e.entityId)},[e.entityId]);const Ce=be(async()=>{if(_e.peek().kind!=="multi_account_signed_in")return;Y.current?.abort("superseded");const A=new AbortController;Y.current=A;const V=Te();s(!0);const ne=await Dp(A.signal);if(!(!ue.current||!ie(V)||A.signal.aborted||_e.peek().kind!=="multi_account_signed_in")){if(s(!1),!ne.ok){if(ne.error.kind==="aborted"||ne.error.kind==="epoch_stale")return;o([]),_(Bt(ne.error,"list"));return}o(ne.value),_(null),Ia()}},[]),De=be(async()=>{if(_e.peek().kind!=="multi_account_signed_in")return;de.current?.abort("superseded");const A=new AbortController;de.current=A;const V=Te(),ne=await Up(A.signal);if(!(!ue.current||!ie(V)||A.signal.aborted||_e.peek().kind!=="multi_account_signed_in")){if(!ne.ok){if(ne.error.kind==="aborted"||ne.error.kind==="epoch_stale")return;c(null),b(Bt(ne.error,"list"));return}c(ne.value),b(null)}},[]),ke=be(async()=>{await Promise.all([Ce(),De()])},[Ce,De]);Se(()=>{ke()},[ke]),Se(()=>{let A=null,V=!1,ne=!1,le=!1;const ae=()=>{if(A=null,V||_e.peek().kind!=="multi_account_signed_in")return;const Ie=ne,je=le;ne=!1,le=!1,Ie&&Ce(),je&&se(pt=>pt+1)},Ne=(Ie,je)=>{V||(Ie&&(ne=!0),je&&(le=!0),A===null&&(A=setTimeout(ae,450)))},Ve=sr(Ie=>{if(V||_e.peek().kind!=="multi_account_signed_in")return;const je=Lp(Ie);je&&(xe(je),(je.refreshKeepers||je.refreshConversation)&&Ne(je.refreshKeepers,je.refreshConversation))}),vt=as(()=>Ne(!0,!0)),H=ss(()=>Ne(!0,!0));return()=>{V=!0,Ve(),vt(),H(),A!==null&&clearTimeout(A)}},[Ce]);const me=f?.runtimes??[],Pe=wt(()=>{const A=new Map;for(const V of me)A.set(V.runtime_id,V);return A},[me]),Ue=wt(()=>{const A=l.trim().toLowerCase();return A?r.filter(V=>{const ne=V.runtime_id?Pe.get(V.runtime_id):null;return V.keeper_id.toLowerCase().includes(A)||(V.runtime_id?.toLowerCase().includes(A)??!1)||(ne?.model?.toLowerCase().includes(A)??!1)||(ne?.integration_id?.toLowerCase().includes(A)??!1)}):r},[r,l,Pe]),pe=wt(()=>{if(r.length===0)return null;const A=e.entityId??v;if(A){const V=r.find(ne=>ne.keeper_id===A);if(V)return V;if(e.entityId)return null}return r[0]??null},[r,e.entityId,v]);Se(()=>{w(pe?.runtime_id??""),z(null)},[pe?.keeper_id,pe?.runtime_id]);const Et=be(A=>{E(A),e.onNavigate(`/keepers/${encodeURIComponent(A)}/${n}`)},[e,n]),tt=be(A=>{pe&&e.onNavigate(`/keepers/${encodeURIComponent(pe.keeper_id)}/${A}`)},[e,pe]),Ke=be(A=>{S(!1),E(A),Ce(),e.onNavigate(`/keepers/${encodeURIComponent(A)}/chat`)},[e,Ce]),lt=async(A,V)=>{if(D||!V||_e.peek().kind!=="multi_account_signed_in")return;Me.current?.abort("superseded");const ne=new AbortController;Me.current=ne;const le=Te();re(!0),z(null);const ae=await xi(A,V,ne.signal);if(!(!ue.current||!ie(le)||ne.signal.aborted||_e.peek().kind!=="multi_account_signed_in")){if(re(!1),!ae.ok){if(ae.error.kind==="aborted"||ae.error.kind==="epoch_stale")return;z({keeperId:A,message:Bt(ae.error,"assign")}),(ae.error.kind==="server"||ae.error.kind==="network"||ae.error.kind==="decode")&&Ce();return}o(Ne=>Ne.map(Ve=>Ve.keeper_id===ae.value.keeper_id?{...Ve,runtime_id:ae.value.runtime_id}:Ve)),z(null),In(ae.value.record==="existing"?`${ae.value.keeper_id}는 이미 ${ae.value.runtime_id}에 연결되어 있습니다.`:`${ae.value.keeper_id}에 런타임 ${ae.value.runtime_id}을(를) 연결했습니다.`,"success")}},ye=pe?.runtime_id?Pe.get(pe.runtime_id)??null:null,nt=pe?.runtime_id!==null&&pe!==null&&f!==null&&k===null&&ye===null,ct=W!==null&&pe!==null&&W.keeperId===pe.keeper_id?W.message:null,j=(A,V)=>u`
    <div class="kp-ma-runtime-bar" data-testid=${`${V}-runtime-bar`}>
      <select
        class="kp-input kp-ma-runtime-select"
        aria-label="개인 Keeper 런타임 선택"
        data-testid=${`${V}-runtime-select`}
        disabled=${D||me.length===0}
        value=${M}
        onChange=${ne=>{w(ne.currentTarget.value),W&&z(null)}}
      >
        <option value="">
          ${me.length===0?"연결 가능한 개인 런타임 없음":"런타임 선택…"}
        </option>
        ${me.map(ne=>u`
          <option key=${ne.runtime_id} value=${ne.runtime_id}>
            ${Ri(ne)}
          </option>
        `)}
      </select>
      <button
        type="button"
        class="btn-primary"
        data-testid=${`${V}-assign-btn`}
        disabled=${D||!M||M===(A.runtime_id??"")}
        onClick=${()=>{lt(A.keeper_id,M)}}
      >
        ${D?u`<${nr} size="xs" /> 연결 중…`:A.runtime_id?"런타임 변경":"런타임 연결"}
      </button>
      ${me.length===0&&u`
        <button
          type="button"
          class="btn-ghost"
          onClick=${()=>e.onNavigate("/runtime/quotas")}
        >
          Runtime → Quotas에서 계정 연결
        </button>
      `}
    </div>
  `;return u`
    <div
      class="kp-root"
      data-workspace="keepers"
      data-keepers-mode="multi_account"
      data-testid="ma-personal-keepers-workspace"
    >
      <!-- Left 260px Personal Keeper Roster -->
      <aside class="kp-roster" aria-label="개인 Keeper 목록">
        <div class="kp-roster-head">
          <div class="kp-roster-top">
            <h2 class="kp-roster-title">
              <span class="kp-roster-title-text" title=${`Personal Keepers (${r.length})`}>
                Personal (<span class="tnum">${r.length}</span>)
              </span>
              <span class="kp-pill" data-tone="info">${t.role}</span>
            </h2>
            <button
              type="button"
              class="btn-primary"
              data-testid="ma-create-keeper-btn"
              onClick=${()=>S(!0)}
            >
              + Create Keeper
            </button>
          </div>

          <input
            type="search"
            class="kp-input"
            placeholder="개인 Keeper, 런타임 검색…"
            aria-label="개인 Keeper 검색"
            value=${l}
            onInput=${A=>g(A.currentTarget.value)}
          />
        </div>

        ${i&&r.length===0?u`<div class="kp-empty" role="status">개인 Keeper 목록 불러오는 중…</div>`:a?u`
                <div class="kp-scroll-pane">
                  <div class="ap-error" role="alert" data-testid="ma-keepers-list-error">
                    ${a}
                  </div>
                  <button type="button" class="btn-ghost" onClick=${()=>{ke()}}>
                    목록 다시 불러오기
                  </button>
                </div>
              `:Ue.length===0?u`
                  <div class="kp-empty" data-testid="ma-keepers-empty">
                    ${r.length===0?'소유한 개인 Keeper가 없습니다. "+ Create Keeper"로 새 Keeper를 만드세요.':"검색 조건에 일치하는 개인 Keeper가 없습니다."}
                  </div>
                `:u`
                  <div class="kp-roster-list" role="list" aria-label="개인 Keeper 목록">
                    ${Ue.map(A=>{const V=pe?.keeper_id===A.keeper_id,ne=A.runtime_id?Pe.get(A.runtime_id)??null:null,le=A.runtime_id!==null&&f!==null&&k===null&&ne===null,ae=A.runtime_id?le?`${A.runtime_id} · 재연결 필요`:ne?.model?`${A.runtime_id} · ${ne.model}`:A.runtime_id:"런타임 미지정",Ne=A.runtime_id&&!le?"ok":"warn",Ve=A.runtime_id?le?"재연결 필요":"연결됨":"미지정";return u`
                        <button
                          key=${A.keeper_id}
                          type="button"
                          role="listitem"
                          class="kp-roster-row"
                          data-keeper=${A.keeper_id}
                          data-selected=${V?"true":"false"}
                          aria-current=${V?"true":void 0}
                          onClick=${()=>Et(A.keeper_id)}
                        >
                          <span class="kp-roster-avatar">
                            <span class="kp-hero-portrait-sigil kp-ma-roster-sigil" aria-hidden="true">
                              ${qo(A.keeper_id)}
                            </span>
                            <span
                              class="kp-status-dot"
                              data-tone=${Ne}
                            />
                          </span>
                          <span class="kp-roster-info">
                            <span class="kp-roster-name">${A.keeper_id}</span>
                            <span class="kp-roster-sub" title=${ae}>${ae}</span>
                          </span>
                          <span class="kp-roster-right">
                            <span class="kp-pill" data-tone=${Ne}>
                              ${Ve}
                            </span>
                          </span>
                        </button>
                      `})}
                  </div>
                `}

        ${I&&u`
          <${Yp}
            existingIds=${r.map(A=>A.keeper_id)}
            runtimes=${me}
            onClose=${()=>S(!1)}
            onCreated=${Ke}
            onUncertainCreate=${()=>{Ce()}}
            onNavigate=${e.onNavigate}
          />
        `}
      </aside>

      <!-- Right Stage -->
      <section class="kp-stage" aria-label="개인 Keeper 워크스페이스">
        ${pe?u`
              <header class="kp-hero" data-testid="ma-keeper-header">
                <div class="kp-hero-top">
                  <div class="kp-hero-id">
                    <div class="kp-hero-portrait-ring">
                      <span class="kp-hero-portrait-sigil" aria-label=${pe.keeper_id}>
                        ${qo(pe.keeper_id)}
                      </span>
                    </div>

                    <div class="kp-hero-text">
                      <h1 class="kp-hero-name">${pe.keeper_id}</h1>
                      <div class="kp-pill-row">
                        <span class="kp-pill" data-tone="info">Personal Keeper</span>
                        <span
                          class="kp-pill"
                          data-tone=${pe.runtime_id&&!nt?"ok":"warn"}
                          data-testid="ma-keeper-runtime-pill"
                        >
                          ${pe.runtime_id?nt?`Runtime: ${pe.runtime_id} (재연결 필요)`:`Runtime: ${pe.runtime_id}`:"런타임 미지정"}
                        </span>
                        ${ye?.model&&u`
                          <span class="kp-pill" data-tone="brass">${ye.model}</span>
                        `}
                        ${ye?.unread&&u`
                          <span class="kp-pill" data-tone="warn">
                            런타임 주의: ${ye.unread}
                          </span>
                        `}
                      </div>
                    </div>
                  </div>

                  ${j(pe,"ma-header")}
                </div>

                ${ct&&u`
                  <div class="ap-error" role="alert" data-testid="ma-assign-error">${ct}</div>
                `}
                ${k&&u`
                  <div class="ap-error" role="alert" data-testid="ma-provider-accounts-error">
                    개인 런타임 목록 조회 실패: ${k}
                  </div>
                `}

                <nav class="kp-tabs" role="tablist" aria-label="Keeper 상세 탭" data-mobile-only="true">
                  ${Aa.map(A=>u`
                    <button
                      key=${A}
                      type="button"
                      role="tab"
                      class="kp-tab"
                      aria-selected=${n===A?"true":"false"}
                      onClick=${()=>tt(A)}
                    >
                      ${Ca[A]}
                    </button>
                  `)}
                </nav>
              </header>

              <div class="kp-body">
                ${n==="chat"&&u`
                  <${Vp}
                    key=${`ma-chat:${pe.keeper_id}`}
                    keeper=${pe}
                    assignedRuntime=${ye}
                    observerSignal=${ce}
                    externalRefreshTick=${te}
                    onNavigate=${e.onNavigate}
                  />
                `}

                ${n==="config"&&u`
                  <div class="kp-scroll-pane" data-keeper-tab="config">
                    <section class="kp-card" aria-label="개인 Keeper 런타임 연결">
                      <div class="kp-card-head">
                        <h3>Personal Runtime Assignment</h3>
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${()=>e.onNavigate("/runtime/quotas")}
                        >
                          Runtime → Quotas →
                        </button>
                      </div>
                      <p class="kp-roster-sub kp-wrap-text">
                        개인 Keeper는 본인 소유의 런타임(<code>/api/v1/auth/provider-accounts</code>)을 연결해 실행합니다.
                      </p>
                      ${j(pe,"ma-config")}
                    </section>

                    <section
                      class="kp-card"
                      data-testid="ma-keeper-su-only-tab"
                      data-tab="config"
                      role="status"
                    >
                      <div class="kp-card-head">
                        <h3>TOML Config, Secrets & OAuth Tools (싱글유저 로컬 전용)</h3>
                      </div>
                      <p class="kp-roster-sub kp-wrap-text">
                        Keeper TOML 설정 스키마 CAS, 쓰기 전용 시크릿 환경변수(<code>/api/v1/keepers/:k/secrets</code>),
                        OAuth 연결 도구(<code>/api/v1/keepers/oauth/attached-tools</code>)는 싱글유저 로컬 세션 전용이며
                        멀티 계정 서버에 마운트되어 있지 않습니다. 개인 모델 자격 증명은 <strong>Runtime → Quotas</strong>에서 관리하세요.
                      </p>
                      <div class="kp-lifecycle-bar">
                        <button
                          type="button"
                          class="btn-primary"
                          onClick=${()=>tt("chat")}
                        >
                          Chat으로 돌아가기
                        </button>
                      </div>
                    </section>
                  </div>
                `}

                ${(n==="memory"||n==="portrait-candle"||n==="work-sandbox")&&u`
                  <${Qp}
                    keeperId=${pe.keeper_id}
                    tab=${n}
                    onBackToChat=${()=>tt("chat")}
                    onNavigate=${e.onNavigate}
                  />
                `}
              </div>
            `:u`
              <div class="kp-scroll-pane">
                ${e.entityId&&!i&&!a?u`
                      <div class="kp-card" data-testid="ma-keeper-not-found" role="status">
                        <h3>개인 Keeper를 찾을 수 없습니다: ${e.entityId}</h3>
                        <p class="kp-roster-sub kp-wrap-text">
                          현재 계정(<code class="mono">${t.accountId}</code>)이 소유한 <code>/api/v1/auth/keepers</code> 목록에 해당 Keeper가 없습니다.
                        </p>
                        <div class="kp-lifecycle-bar">
                          <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/keepers")}>
                            목록으로 돌아가기
                          </button>
                          <button type="button" class="btn-primary" onClick=${()=>S(!0)}>
                            + Create Keeper
                          </button>
                        </div>
                      </div>
                    `:u`
                      <div class="kp-empty">
                        ${i?"개인 Keeper 목록 불러오는 중…":'표시할 개인 Keeper를 선택하거나 "+ Create Keeper"로 새로 만드세요.'}
                      </div>
                    `}
              </div>
            `}
      </section>
    </div>
  `}function Qp(e){const t=e.tab==="memory"?{title:`Memory OS · ${e.keeperId}`,description:"Keeper Memory OS Facts·Journal·Internals 조회 및 복구/철회(/api/v1/keepers/:k/memory-*)는 싱글유저 로컬 세션 전용입니다. 멀티 계정 서버에서는 마운트되지 않아 요청을 전송하지 않습니다.",secondaryLabel:"World Memory →",secondaryPath:"/knowledge/memory"}:e.tab==="portrait-candle"?{title:`Portrait & Candle · ${e.keeperId}`,description:"Keeper 초상화 렌더링(/api/v1/keepers/:k/portrait.png)과 장신구 상점(/api/v1/keepers/:k/items)은 싱글유저 로컬 세션 전용입니다. 워크스페이스 전체 Candle 원장은 Work → Candle에서 볼 수 있습니다.",secondaryLabel:"Work → Candle →",secondaryPath:"/work/candle"}:{title:`Work & Sandbox · ${e.keeperId}`,description:"Keeper 운영자 노트(/operator-note), 도구 호출 통계/상세(/tool-stats, /tool-calls), 원시 트레이스, 개별 샌드박스 텔레메트리는 싱글유저 로컬 세션 전용입니다. 워크스페이스 작업은 Work → Tasks에서 확인할 수 있습니다.",secondaryLabel:"Work → Tasks →",secondaryPath:"/work/tasks"};return u`
    <div class="kp-scroll-pane" data-keeper-tab=${e.tab}>
      <section
        class="kp-card"
        data-testid="ma-keeper-su-only-tab"
        data-tab=${e.tab}
        role="status"
      >
        <div class="kp-card-head">
          <h3>${t.title}</h3>
          <span class="kp-pill" data-tone="info">싱글유저 로컬 전용</span>
        </div>
        <p class="kp-roster-sub kp-wrap-text">${t.description}</p>
        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-primary" onClick=${e.onBackToChat}>
            Chat으로 돌아가기
          </button>
          <button
            type="button"
            class="btn-ghost"
            onClick=${()=>e.onNavigate(t.secondaryPath)}
          >
            ${t.secondaryLabel}
          </button>
        </div>
      </section>
    </div>
  `}function Yp(e){const[t,n]=F(""),[r,o]=F(""),[i,s]=F(!1),[a,_]=F(null),f=X(null),c=X(null),k=X(null),b=X(!0),l=X(e.onClose);l.current=e.onClose,xa({containerRef:f,active:!0,initialFocus:()=>c.current}),Se(()=>{b.current=!0,queueMicrotask(()=>c.current?.focus());const v=E=>{E.defaultPrevented||E.isComposing||E.keyCode===229||E.key==="Escape"&&(E.preventDefault(),E.stopPropagation(),l.current())};return window.addEventListener("keydown",v),()=>{b.current=!1,k.current?.abort("modal_unmount"),window.removeEventListener("keydown",v)}},[]);const g=async v=>{if(v.preventDefault(),i||_e.peek().kind!=="multi_account_signed_in")return;const E=Sp(t);if(!E.ok){_(E.error);return}if(e.existingIds.includes(E.value)){_(`이미 "${E.value}" 이름의 개인 Keeper가 있습니다.`);return}k.current?.abort("superseded");const I=new AbortController;k.current=I;const S=Te();s(!0),_(null);const M=await Bp(E.value,I.signal);if(!b.current||!ie(S)||I.signal.aborted||_e.peek().kind!=="multi_account_signed_in")return;if(!M.ok){s(!1),M.error.kind!=="aborted"&&M.error.kind!=="epoch_stale"&&(_(Bt(M.error,"create")),(M.error.kind==="server"||M.error.kind==="network"||M.error.kind==="decode")&&e.onUncertainCreate());return}let w=null;if(M.value.record==="made"&&r){const D=await xi(M.value.keeper_id,r,I.signal);if(!b.current||!ie(S)||I.signal.aborted||_e.peek().kind!=="multi_account_signed_in")return;!D.ok&&D.error.kind!=="aborted"&&D.error.kind!=="epoch_stale"&&(w=Bt(D.error,"assign"))}s(!1),w!==null?In(`개인 Keeper "${M.value.keeper_id}"를 생성했지만 런타임 연결에 실패했습니다: ${w}`,"info"):In(M.value.record==="existing"?`기존 개인 Keeper "${M.value.keeper_id}"를 열었습니다.`:`개인 Keeper "${M.value.keeper_id}"를 생성했습니다.`,"success"),e.onCreated(M.value.keeper_id)};return u`
    <div
      ref=${f}
      class="kp-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="새 개인 Keeper 생성"
      data-testid="ma-create-keeper-modal"
      onClick=${v=>{v.target===v.currentTarget&&e.onClose()}}
    >
      <form class="kp-modal" onSubmit=${v=>{g(v)}}>
        <div class="kp-card-head">
          <h3>+ Create Personal Keeper</h3>
          <button type="button" class="btn-ghost" onClick=${e.onClose}>닫기</button>
        </div>

        <p class="kp-roster-sub kp-wrap-text">
          본인 계정 소유의 개인 Keeper를 생성합니다 (<code>POST /api/v1/auth/keepers</code>).
        </p>

        ${a&&u`<div class="ap-error" role="alert" data-testid="ma-create-keeper-error">${a}</div>`}

        <label class="kp-kv-box">
          <span class="kp-kv-k">Keeper ID (필수 · 영문/숫자/._-)</span>
          <input
            ref=${c}
            type="text"
            class="kp-input"
            aria-label="개인 Keeper 이름"
            placeholder="e.g. my-code-reviewer"
            disabled=${i}
            value=${t}
            onInput=${v=>{n(v.currentTarget.value),a&&_(null)}}
          />
        </label>

        <label class="kp-kv-box">
          <span class="kp-kv-k">초기 연결 런타임 (선택)</span>
          <select
            class="kp-input"
            aria-label="초기 연결 런타임"
            disabled=${i||e.runtimes.length===0}
            value=${r}
            onChange=${v=>o(v.currentTarget.value)}
          >
            <option value="">지정 안 함 (생성 후 연결)</option>
            ${e.runtimes.map(v=>u`
              <option key=${v.runtime_id} value=${v.runtime_id}>
                ${Ri(v)}
              </option>
            `)}
          </select>
        </label>

        ${e.runtimes.length===0&&u`
          <div class="kp-notice" data-tone="info" role="note">
            아직 연결된 개인 런타임이 없습니다. 생성 후 <strong>Runtime → Quotas</strong>에서 계정을 연결할 수 있습니다.
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>{e.onClose(),e.onNavigate("/runtime/quotas")}}
            >
              Runtime → Quotas 이동
            </button>
          </div>
        `}

        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-ghost" disabled=${i} onClick=${e.onClose}>
            취소
          </button>
          <button
            type="submit"
            class="btn-primary"
            data-testid="ma-create-keeper-submit"
            disabled=${i}
          >
            ${i?u`<${nr} size="xs" /> 생성 중…`:"개인 Keeper 생성"}
          </button>
        </div>
      </form>
    </div>
  `}const Ai=Fr(async()=>(await On(async()=>{const{KeeperMemoryTab:e}=await import("./keeper-memory-tab.js");return{KeeperMemoryTab:e}},__vite__mapDeps([35,1,34,3,2,4,36,31,32,30,12,13,37,18,6,38,17,15,16,19,20,21,22,23,24,25,26,27,28,29,33,7,8]))).KeeperMemoryTab),Ci=Fr(async()=>(await On(async()=>{const{KeeperPortraitCandleTab:e}=await import("./keeper-portrait-candle-tab.js");return{KeeperPortraitCandleTab:e}},__vite__mapDeps([39,1,2,18,6,36,31,32,30,12,15,16,17,19,20,21,22,23,24,3,4,25,26,27,28,29,13,33,34,7,8]))).KeeperPortraitCandleTab),Ii=Fr(async()=>(await On(async()=>{const{KeeperWorkSandboxTab:e}=await import("./keeper-work-sandbox-tab.js");return{KeeperWorkSandboxTab:e}},__vite__mapDeps([40,1,34,36,31,32,2,30,37,18,6,14,3,4,15,16,17,19,20,21,22,23,24,25,26,27,28,29,13,33,7,8]))).KeeperWorkSandboxTab),Oi=Fr(async()=>(await On(async()=>{const{KeeperConfigTab:e}=await import("./keeper-config-tab.js");return{KeeperConfigTab:e}},__vite__mapDeps([41,1,25,26,3,2,4,10,12,42,21,6,5,15,16,17,18,19,20,22,23,24,27,28,29,30,31,32,13,33,34,7,8]))).KeeperConfigTab);function wi(e){switch(is(e)){case"memory":return Ai.preload();case"portrait-candle":return Ci.preload();case"work-sandbox":return Ii.preload();case"config":return Oi.preload();default:return Promise.resolve()}}rl("keepers",e=>{wi(e).catch(()=>{})});function Jp({turnPreviews:e,...t}){return u`<${Pd} ...${t} turnPreviews=${e.value} />`}function Xp({turnPreviews:e,keeper:t,...n}){const r=t.name,o=wt(()=>al(()=>e.value.get(r)),[e,r]);return u`<${Ud} ...${n} keeper=${mi(t,o.value)} />`}function $a(e){const t=_e.value,n=Kr(t),r=Jt.value,{roster:o,turns:i}=Wu(),s=wt(()=>o.kind!=="value"||i.kind!=="value"?o:{...o,data:o.data.map(w=>{const D=i.data.get(w.name);return D?{...w,active_turn:D.active,chat_control_token:D.chat_control_token,waiting_summary:D.waiting}:w})},[o,i]),a=i.kind==="value"?{observedAt:i.updatedAt,live:!i.stale}:null,[_,f]=F(e.entityId??null),c=X(null),k=is(e.entityTab);Se(()=>{e.entityId&&f(e.entityId)},[e.entityId]);const b=be(async w=>{if(!Kr(_e.peek()))return;const D=Te();if(w==="sse"&&c.current&&await c.current,Te()!==D)return;const re=Vu(w);c.current=re,await re,c.current===re&&(c.current=null),Te()===D&&Ia()},[]);Se(()=>{n&&(b("mount"),fl("mount"))},[r,n,b]),Se(()=>{if(!n)return;let w=null,D=!1,re=!1,W=!1;const z=()=>{W||(D=!0,!(re||w!==null)&&(w=setTimeout(()=>{w=null,D=!1,re=!0,b("sse").finally(()=>{re=!1,D&&z()})},450)))},ce=sr(Y=>{Ra(Y).some(de=>Gu.includes(de))&&z()}),xe=as(z),te=ss(z);let se=tr.peek();const ue=tr.subscribe(Y=>{Y&&!se&&z(),se=Y});return()=>{W=!0,ce(),xe(),te(),ue(),w&&clearTimeout(w)}},[n,b]);const l=sl(ca);Se(()=>(l.value=ca,sr(w=>{const D=sd(w.event,w.data);D&&(l.value=$d(l.peek(),D.keeperName,{ownerKey:D.ownerKey,preview:D.preview,receivedAt:Date.now(),live:!0}))})),[r,l]);const g=s.kind==="value"?s.data:[],v=wt(()=>{if(g.length===0)return null;const w=e.entityId??_;if(w){const D=g.find(re=>re.name===w);if(D)return D;if(e.entityId)return null}return g[0]??null},[g,e.entityId,_]),E=be(w=>{f(w),e.onNavigate(`/keepers/${encodeURIComponent(w)}/${k}`)},[e,k]),I=be(w=>{v&&e.onNavigate(`/keepers/${encodeURIComponent(v.name)}/${w}`)},[e,v]),S=be(w=>{f(w),b("manual"),e.onNavigate(`/keepers/${encodeURIComponent(w)}/chat`)},[e,b]),M=be(()=>{f(null),b("manual"),e.onNavigate("/keepers")},[e,b]);return t.kind==="multi_account_signed_in"?u`
      <${zp}
        key=${`ma:${r}:${t.accountId}`}
        session=${t}
        subroute=${e.subroute}
        entityId=${e.entityId}
        entityTab=${e.entityTab}
        onNavigate=${e.onNavigate}
        onInspect=${e.onInspect}
      />
    `:n?u`
    <div class="kp-root" data-workspace="keepers">
      <${Jp}
        turnPreviews=${l}
        roster=${s}
        turnsObservation=${a}
        selectedKeeper=${v?.name??null}
        onSelectKeeper=${E}
        onCreatedKeeper=${S}
      />

      <section class="kp-stage" aria-label="Keeper 워크스페이스">
        ${v?u`
              <${Xp}
                key=${`hdr:${r}:${v.name}`}
                turnPreviews=${l}
                keeper=${v}
                turnStatus=${i.kind}
                activeTab=${k}
                onSelectTab=${I}
                onLifecycleMutated=${()=>{b("manual")}}
                onDeleted=${M}
              />

              <div class="kp-body">
                ${k==="chat"&&u`
                  <${vp}
                    key=${`chat:${r}:${v.name}`}
                    keeper=${v}
                    turnSnapshot=${i}
                    onInspect=${e.onInspect}
                    onSelectKeeper=${E}
                    onMutated=${()=>{b("manual")}}
                  />
                `}
                ${k!=="chat"&&u`
                  <${Nr} fallback=${null}>
                    ${k==="memory"&&u`
                      <${Ai.Component}
                        key=${`mem:${r}:${v.name}`}
                        keeperName=${v.name}
                      />
                    `}
                    ${k==="portrait-candle"&&u`
                      <${Ci.Component}
                        key=${`pc:${r}:${v.name}`}
                        keeper=${v}
                        onMutated=${()=>{b("manual")}}
                      />
                    `}
                    ${k==="work-sandbox"&&u`
                      <${Ii.Component}
                        key=${`ws:${r}:${v.name}`}
                        keeperName=${v.name}
                        onNavigate=${e.onNavigate}
                        onInspect=${e.onInspect}
                      />
                    `}
                    ${k==="config"&&u`
                      <${Oi.Component}
                        key=${`cfg:${r}:${v.name}`}
                        keeperName=${v.name}
                        onMutated=${()=>{b("manual")}}
                      />
                    `}
                  <//>
                `}
              </div>
            `:u`
              <div class="kp-scroll-pane">
                <div class="kp-empty">
                  ${s.kind==="loading"?"Keeper 목록 불러오는 중…":'표시할 Keeper를 선택하거나 "+ Create Keeper"로 새로 만드세요.'}
                </div>
              </div>
            `}
      </section>
    </div>
  `:u`
      <div class="kp-root" data-workspace="keepers">
        <section class="kp-stage" aria-label="Keeper 워크스페이스">
          <div class="kp-scroll-pane">
            <div class="kp-card" data-testid="keepers-mode-notice" role="status">
              <h3>Keepers Workspace</h3>
              <p class="kp-roster-sub">
                현재 세션 상태에서는 Keeper 목록을 조회할 수 없습니다. 싱글유저 로컬 세션 또는 멀티 계정 로그인 후 이용하세요.
              </p>
            </div>
          </div>
        </section>
      </div>
    `}const z_=Object.freeze(Object.defineProperty({__proto__:null,KeepersWorkspace:$a,default:$a,preloadKeeperEntityTab:wi},Symbol.toStringTag,{value:"Module"}));export{P_ as A,K_ as B,N_ as C,M_ as D,Qn as E,L_ as F,S_ as G,I_ as H,A_ as I,w_ as J,C_ as K,O_ as L,E_ as M,T_ as N,z_ as O,vi as T,U_ as a,$_ as b,y_ as c,B_ as d,H_ as e,D_ as f,q_ as g,R_ as h,x_ as i,op as j,oi as k,yi as l,bi as m,sp as n,np as o,Pr as p,rp as q,b_ as r,F_ as s,Yc as t,hi as u,pn as v,j_ as w,G_ as x,W_ as y,V_ as z};
