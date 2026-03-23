import{G as Q,al as ha,am as cs,o as pe,an as ps,a6 as xe,ao as _a,ap as xt,a5 as F,aq as D,m as s,ar as us,as as wa,at as K,au as ie,av as Le,aw as vs,ax as ms,ay as $s,az as gs,aA as xs,aB as Gt,aC as bs,r as j,aD as qe,aE as Ut,aF as mt,aG as ya,aH as Jt,aI as Zt,aJ as ka,aK as Ca,aL as fs,aM as O,a0 as T,d as bt,aN as hs,E as M,aO as Qt,aP as _e,aQ as _s,y as Sa,aR as ct,e as ws,aS as ys,aT as ea,A as z,aU as te,q as ee,aV as ks,aW as Cs,aX as ta,aY as Ss,ac as ne,aZ as ke,b as Ma,a_ as Pa,a$ as aa,l as Ms,b0 as ye,b1 as et,f as Ps,b2 as sa,b3 as js,b4 as Rs,b5 as na,b6 as Ts,b7 as ft,b8 as Is,b9 as ra,ba as Es,bb as Ls,bc as As,bd as Ns,be as Bs,bf as Ys,bg as Fs,bh as De,bi as Os,bj as Ve,bk as Ws,bl as oa,bm as ia,bn as la,bo as qs}from"./index-BB0zaaHQ.js";import{c as N,A as Ie,y as H,d as ht}from"./vendor-Chwn_OlE.js";import{f as zs,R as ja,P as Ra}from"./shared-ajMFPXbw.js";import{L as Xs}from"./feedback-state-DiW1_ueY.js";import{c as Ds,C as Vs,a as ze,r as ve,f as je,b as _t,s as Ks,g as Hs,d as Gs,i as Us,l as Js,e as Zs,h as Qs,j as pt,k as be,m as lt,n as Ta,o as en,u as tn,p as an,q as sn,t as Ia,v as nn,w as rn,x as V,y as de,z as on,A as ln,B as da,D as dn,E as cn,F as pn,G as un}from"./helpers-Bd2DyH_v.js";import{S as g}from"./status-chip-B-Vgmq3f.js";import{t as h,s as le,a as Ea,c as ce,e as vn}from"./input-DWPrIiMN.js";import{Governance as mn}from"./governance-QqcN6gK6.js";import"./filter-chips-Cu5kYIK3.js";const La="masc_dashboard_agent_name";function $n(){var t,a,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((a=e.get("agent_name"))==null?void 0:a.trim())||((n=localStorage.getItem(La))==null?void 0:n.trim())||"dashboard"}const Xe=N($n()),Se=N(""),st=N("운영 점검"),Me=N(""),Ae=N(""),Ne=N("2"),$e=N(""),Z=N("note"),Be=N(""),Ye=N(""),Fe=N(""),Oe=N("2"),We=N(""),nt=N("운영자 중지 요청"),$t=N(""),gn=N(""),Ke=N(null);function xn(e){const t=e.trim()||"dashboard";Xe.value=t,localStorage.setItem(La,t)}function wt(e){switch((e??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(e==null?void 0:e.trim())||"안내"}}function rt(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function dt(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function Aa(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function yt(e){return e!=null&&e.fresh_until?e.fresh_until:"갱신 기준 없음"}function ca(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function fe(e){return typeof e=="string"?e.trim().toLowerCase():""}function tt(e){const t=fe(e.status);return t==="done"||t==="completed"||t==="ended"||t==="cancelled"||t==="stopped"||t==="failed"||t==="error"||t==="interrupted"}function Na(e){return e.find(t=>!tt(t))??e[0]??null}function Ba(e){var t;return $e.value&&e.some(a=>a.session_id===$e.value)?$e.value:((t=Na(e))==null?void 0:t.session_id)??""}function pa(e){var a;const t=fe((a=e.team_health)==null?void 0:a.status);return t?cs(t):"상태 확인 필요"}function bn(e){return`${e.done_delta_total??0}건 완료`}function fn(e){var n;const t=fe(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const a=fe((n=e.team_health)==null?void 0:n.status);return a&&a!=="ok"&&a!=="healthy"&&a!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function hn(e){const t=fe(e.status);if(t==="offline"||t==="inactive"||t==="error")return["offline"];const a=[];return(t===""||t==="unknown")&&a.push("unknown_status"),(e.context_ratio??0)>=.8&&a.push("high_context"),e.context_ratio==null&&a.push("missing_context"),e.last_turn_ago_s==null&&a.push("missing_turns"),(e.last_turn_ago_s??0)>=3600&&a.push("stale_turns"),a}function _n(e){switch(e){case"offline":return"오프라인";case"unknown_status":return"상태 미수집";case"high_context":return"컨텍스트 80%+";case"missing_context":return"컨텍스트 텔레메트리 없음";case"missing_turns":return"최근 턴 기록 없음";case"stale_turns":return"1시간 이상 비활성"}}function Ya(e){const t=hn(e),a=t.includes("offline")?"bad":t.length>0?"warn":"ok",n=t.length===0?"점검 필요 신호 없음":t.map(_n).join(" · ");return{tone:a,summary:n}}function Ee(e){return Ya(e).tone}function ot(e){return Ya(e).summary}function ua(e){return e.some(t=>fe(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function wn(e){return e.target_type==="team_session"}function yn(e){return e.target_type==="keeper"}function ge(e){switch(e){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";default:return(e==null?void 0:e.trim())||"액션"}}function Pe(e){switch(e){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(e==null?void 0:e.trim())||"대상"}}function gt(e){return e?"확인 후 실행":"즉시 실행"}function kn(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return e}}function U(e,t){if(!e)return null;const a=e[t];return typeof a=="string"&&a.trim()!==""?a.trim():typeof a=="number"&&Number.isFinite(a)?String(a):null}function Cn(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function Sn(e){if(!e)return"";const t=e.spawn_batch;return t!==void 0?xe(t):xe(e)}function Fa(e){const t=Cn(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){Se.value=U(t,"message")??e.summary;return}if(e.action_type==="task_inject"){Me.value=U(t,"title")??"운영자 주입 작업",Ae.value=U(t,"description")??e.summary,Ne.value=U(t,"priority")??Ne.value;return}e.action_type==="room_pause"&&(st.value=U(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&($e.value=e.target_id),e.action_type==="team_stop"){nt.value=U(t,"reason")??e.summary;return}Z.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const a=U(t,"message");if(a&&(Be.value=a),Z.value==="worker_spawn_batch"){We.value=Sn(t);return}Z.value==="task"&&(Ye.value=U(t,"task_title")??U(t,"title")??"운영자 주입 작업",Fe.value=U(t,"task_description")??U(t,"description")??e.summary,Oe.value=U(t,"task_priority")??U(t,"priority")??Oe.value);return}e.target_type==="keeper"&&(e.target_id&&($t.value=e.target_id),gn.value=U(t,"message")??e.summary)}function Mn(e){Fa({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function Pn(e){Fa({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),Q("추천 액션 payload를 폼에 채웠습니다","success")}function jn(e,t,a){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(n=>n.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&a.some(n=>n.name===e.target_id):!0}async function he(e){const t=Xe.value.trim()||"dashboard";try{const a=await ps({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return a.confirm_required?Q("확인 대기열에 올렸습니다","warning"):Q(e.successMessage,"success"),a}catch(a){const n=a instanceof Error?a.message:"개입 실행에 실패했습니다";return Q(n,"error"),null}}async function va(){const e=Se.value.trim();if(!e)return;await he({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(Se.value="")}async function Rn(){await he({action_type:"room_pause",target_type:"room",payload:{reason:st.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function Oa(){await he({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Tn(){const e=Me.value.trim();if(!e)return;await he({action_type:"task_inject",target_type:"room",payload:{title:e,description:Ae.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Ne.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Me.value="",Ae.value="")}async function In(){const e=pe.value,t=Ba((e==null?void 0:e.sessions)??[]);if(!t){Q("먼저 세션을 고르세요","warning");return}const a={};if(Z.value==="worker_spawn_batch"){const i=We.value.trim();if(!i){Q("spawn_batch JSON을 먼저 채우세요","warning");return}try{const l=JSON.parse(i);if(Array.isArray(l))a.spawn_batch=l;else if(l&&typeof l=="object"&&Array.isArray(l.spawn_batch))a.spawn_batch=l.spawn_batch;else{Q("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(l){const p=l instanceof Error?l.message:"spawn_batch JSON 파싱에 실패했습니다";Q(p,"error");return}await he({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:a,successMessage:"작업자 교체 요청을 적용했습니다"})&&(We.value="");return}const n=Be.value.trim();n&&(a.message=n);let r="team_note";Z.value==="broadcast"?r="team_broadcast":Z.value==="task"&&(r="team_task_inject"),Z.value==="task"&&(a.task_title=Ye.value.trim()||"운영자 주입 작업",a.task_description=Fe.value.trim()||"개입 화면에서 주입",a.task_priority=Number.parseInt(Oe.value,10)||2),await he({action_type:r,target_type:"team_session",target_id:t,payload:a,successMessage:"세션 액션을 적용했습니다"})&&(Be.value="",Z.value==="task"&&(Ye.value="",Fe.value=""))}async function En(){const e=pe.value,t=Ba((e==null?void 0:e.sessions)??[]);if(!t){Q("먼저 세션을 고르세요","warning");return}await he({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:nt.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function ma(e,t="confirm"){const a=Xe.value.trim()||"dashboard";try{await ha(a,e,t),Q(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(n){const r=n instanceof Error?n.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";Q(r,"error")}}function Wa(e){return e?e.replace(/\[team-session:ts-\d+-\w+\.\.\./g,"[session ").replace(/\[team-session:([^\]]{0,20})[^\]]*\]/g,"[session $1]").replace(/ts-\d{13,}-[a-f0-9]{4,8}/g,t=>{const a=t.match(/ts-(\d{13,})/),n=a==null?void 0:a[1];return n?new Date(parseInt(n,10)).toLocaleTimeString("ko-KR",{hour:"2-digit",minute:"2-digit"}):t}):""}function it(e){switch(e){case"preview":return"border-[rgba(251,191,36,0.26)]";case"confirmed":case"executed":return"border-[rgba(74,222,128,0.26)]";case"error":return"border-[rgba(239,68,68,0.26)]";default:return""}}function Ln(){var C;const e=Ie(null),t=pe.value,a=_a.value,n=(t==null?void 0:t.room)??{},r=xt(t),o=r.items,i=r.confirm_required_actions,d=r.actor_filter,l=r.hidden_count,p=r.hidden_actors,x=(t==null?void 0:t.recent_messages)??[],m=(a==null?void 0:a.recommended_actions)??[],_=(C=a==null?void 0:a.active_recommended_actions)!=null&&C.length?a.active_recommended_actions:m,f=a==null?void 0:a.active_summary,y=(a==null?void 0:a.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),v=(a==null?void 0:a.active_guidance_layer)??"fallback",b=x.slice(0,5),$=()=>{const u=e.current;u&&(u.open=!0,u.scrollIntoView({behavior:"smooth",block:"start"}))};return s`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="${F} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">추천 개입</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-2 ${rt(v)}">
          <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
            <strong>${wt(v)}</strong>
            <span>${(y==null?void 0:y.keeper_name)??(a==null?void 0:a.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="text-[var(--text-strong)] leading-[1.5]">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
            <span>authoritative ${a!=null&&a.authoritative_judgment_available?"yes":"no"}</span>
            <span>${yt(f)}</span>
            ${y!=null&&y.model_used?s`<span>${y.model_used}</span>`:null}
          </div>
        </article>
        ${us.value&&!a?s`
          <${Xs}>개입 추천을 불러오는 중입니다...<//>
        `:_.length>0?s`
          <div class="flex flex-col gap-2">
            ${_.map(u=>s`
              <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"room"}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] ${it(u.severity)}">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${ge(u.action_type)}</strong>
                  <span>${Pe(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                  <span>${gt(u.confirm_required)}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${u.reason}</div>
                ${u.suggested_payload?s`
                  <div class="flex justify-between items-center gap-3 mt-3 max-[880px]:flex-col max-[880px]:items-start">
                    <button class="control-btn ghost" onClick=${()=>{Pn(u),$()}} disabled=${D.value}>
                      폼에 채우기
                    </button>
                  </div>
                `:null}
              </article>
            `)}
          </div>
        `:s`
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">지금 떠 있는 추천 개입은 없습니다.</div>
        `}
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0 ops-pending-section">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">승인 대기</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
          ${d?`현재 actor ${d} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${i.length>0?s`
          <div class="flex flex-col gap-2">
            ${i.map(u=>s`
              <article key=${`${u.action_type}:${u.target_type}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)]">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${ge(u.action_type)}</strong>
                  <span>${Pe(u.target_type)}</span>
                  <span>${gt(u.confirm_required)}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${u.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${o.length>0?s`
          <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
            ${o.map(u=>s`
              <article key=${u.confirm_token} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)]">
                <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
                  <strong>${ge(u.action_type)}</strong>
                  <span>${Pe(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                  <span>${u.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${u.preview?s`<pre class="mt-2 py-[10px] px-3 rounded-xl bg-[rgba(8,15,29,0.82)] border border-solid border-[var(--white-8)] text-[#b9d6ff] text-[11px] leading-[1.45] overflow-x-auto whitespace-pre-wrap break-words max-h-[180px]">${xe(u.preview)}</pre>`:null}
                <div class="flex justify-between items-center gap-3 mt-3 max-[880px]:flex-col max-[880px]:items-start">
                  <button class="control-btn" onClick=${()=>{ma(u.confirm_token)}} disabled=${D.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{ma(u.confirm_token,"deny")}} disabled=${D.value}>
                    거부
                  </button>
                  <span class="text-[var(--text-muted)] text-[var(--fs-xs)] font-mono break-all">${u.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:s`
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">
            ${l>0&&d?`현재 선택한 actor(${d}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${l}건${p.length>0?` · ${p.join(", ")}`:""}`:"지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다."}
          </div>
        `}
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Room 상태</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">평소에는 추천 개입만 보면 됩니다. room 전체를 건드릴 때만 아래 고급 제어를 여세요.</p>

        <div class="grid grid-cols-2 gap-3 max-[880px]:grid-cols-1">
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1">
            <span>Room</span>
            <strong>${n.current_room??n.room_id??"default"}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1">
            <span>프로젝트</span>
            <strong>${n.project??"확인 없음"}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1">
            <span>클러스터</span>
            <strong>${n.cluster??"확인 없음"}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1 ${n.paused?"warn":"ok"}">
            <span>상태</span>
            <strong>${n.paused?"일시정지":"진행 중"}</strong>
          </div>
          <div class="ops-stat p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-1 ${Aa(y)}">
            <span>Resident Judge</span>
            <strong>${dt(y)}</strong>
          </div>
        </div>

        <details
          ref=${e}
          class="ops-control-disclosure mt-0.5 border border-[var(--white-8)] rounded-xl bg-[var(--white-2)]"
          open=${n.paused?!0:void 0}
        >
          <summary class="ops-control-summary list-none cursor-pointer grid gap-1 p-3 px-3.5">
            <span class="text-[#9fe6b5] text-[var(--fs-2xs)] tracking-[0.08em] uppercase">고급 room 제어</span>
            <strong>${n.paused?"지금은 room이 멈춰 있어 재개 동선이 열려 있습니다.":"방송 · 일시정지/재개 · 작업 주입"}</strong>
            <span>${n.paused?"운영 점검 후 재개하거나 공지를 보내세요.":"room 전체에 영향 주는 액션만 이 안에 넣었습니다."}</span>
          </summary>

          <div class="grid gap-3 px-3.5 pb-3.5 border-t border-[var(--white-8)]">
            <label class="control-label" for="ops-broadcast">Room 방송</label>
            <div class="control-row">
              <input
                id="ops-broadcast"
                class="control-input"
                type="text"
                placeholder="@agent 또는 room 전체 공지"
                value=${Se.value}
                onInput=${u=>{Se.value=u.target.value}}
                onKeyDown=${u=>{u.key==="Enter"&&va()}}
                disabled=${D.value}
              />
              <button class="control-btn" onClick=${()=>{va()}} disabled=${D.value||Se.value.trim()===""}>
                보내기
              </button>
            </div>

            <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
            <div class="control-row items-stretch">
              <input
                id="ops-pause-reason"
                class="control-input"
                type="text"
                value=${st.value}
                onInput=${u=>{st.value=u.target.value}}
                disabled=${D.value}
              />
              <button class="control-btn ghost" onClick=${()=>{Rn()}} disabled=${D.value}>
                일시정지
              </button>
              <button class="control-btn ghost" onClick=${()=>{Oa()}} disabled=${D.value}>
                재개
              </button>
            </div>

            <div class="mt-0.5 text-[var(--text-muted)] text-[var(--fs-xs)] tracking-[0.05em] uppercase">작업 주입</div>
            <input
              class="control-input"
              type="text"
              placeholder="작업 제목"
              value=${Me.value}
              onInput=${u=>{Me.value=u.target.value}}
              disabled=${D.value}
            />
            <textarea
              class="control-textarea"
              rows=${3}
              placeholder="작업 설명"
              value=${Ae.value}
              onInput=${u=>{Ae.value=u.target.value}}
              disabled=${D.value}
            ></textarea>
            <div class="control-row items-stretch">
              <select
                class="control-input min-w-[92px]"
                value=${Ne.value}
                onChange=${u=>{Ne.value=u.target.value}}
                disabled=${D.value}
              >
                <option value="1">P1</option>
                <option value="2">P2</option>
                <option value="3">P3</option>
                <option value="4">P4</option>
                <option value="5">P5</option>
              </select>
              <button class="control-btn" onClick=${()=>{Tn()}} disabled=${D.value||Me.value.trim()===""}>
                주입
              </button>
            </div>
          </div>
        </details>
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">최근 Room 메시지</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${b.length>0?s`
          <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
            ${b.map(u=>s`
              <article key=${u.seq??u.id??u.timestamp} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)]">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${u.from}</strong>
                  <span>${u.timestamp}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${Wa(u.content)}</div>
              </article>
            `)}
          </div>
        `:s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}const we=N(""),ut=N(!1),He=N(null);function An(){var E;const e=pe.value,t=wa.value,a=(e==null?void 0:e.sessions)??[],n=a.filter(c=>!tt(c)),r=a.filter(tt),o=((e==null?void 0:e.available_actions)??[]).filter(c=>c.target_type==="team_session"),i=a.find(c=>c.session_id===$e.value)??Na(a),d=i?!tt(i):!1,l=t==null?void 0:t.active_summary,p=(t==null?void 0:t.active_guidance_layer)??"fallback",x=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),m=d?(i==null?void 0:i.linked_autoresearch)??null:null,_=D.value||ut.value,f=(E=t==null?void 0:t.active_recommended_actions)!=null&&E.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[],y=async()=>{await ie(),i!=null&&i.session_id&&await Le(i.session_id)},v=async c=>{ut.value=!0,He.value=null;try{await c(),await y()}catch(S){He.value=S instanceof Error?S.message:"Autoresearch action failed"}finally{ut.value=!1}},b=async()=>{m!=null&&m.loop_id&&await v(()=>vs(m.loop_id))},$=async()=>{if(!(m!=null&&m.loop_id)||!we.value.trim())return;const c=we.value.trim();await v(()=>ms(m.loop_id,c)),we.value=""},C=async()=>{m!=null&&m.loop_id&&await v(()=>$s(m.loop_id))},u=async()=>{m!=null&&m.loop_id&&await v(()=>gs(m.loop_id,"dashboard stop request"))},L=(c,S=!1)=>s`
    <button
      key=${c.session_id}
      class="ops-entity-card p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] text-inherit text-left cursor-pointer ${(i==null?void 0:i.session_id)===c.session_id?"active":""}"
      onClick=${()=>{$e.value=c.session_id}}
    >
      <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
        <strong>${c.session_id}</strong>
        <span class="border border-solid border-[var(--card-border)] ${c.status??"idle"} ${c.status==="offline"?"text-[#8da4cc]":""}">${K(c.status)}</span>
      </div>
      <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
        <span>${Math.round(c.progress_pct??0)}%</span>
        <span>${bn(c)}</span>
        <span>${S?"종료 세션":`팀 상태 ${pa(c)}`}</span>
      </div>
    </button>
  `;return s`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="${F} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Session 개입</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">지금 개입 가능한 세션만 위에 두고, 종료된 세션은 아래에 접어 둡니다.</p>

        <div class="flex flex-col gap-2">
          <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
            <strong>${"개입 가능한 세션"}</strong>
            <span>${n.length}</span>
          </div>
          <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
            ${n.length===0?s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">지금 바로 개입할 live team session이 없습니다.</div>`:n.map(c=>L(c))}
          </div>
        </div>

        ${r.length>0?s`
          <details class="ops-archive-panel">
            <summary class="cursor-pointer text-[var(--text-muted)] text-[var(--fs-sm)] list-none">최근 종료 세션 ${r.length}</summary>
            <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">완료/중단된 세션은 읽기 전용 참고용입니다. 새 노트, 작업, 중지는 위 live 세션에만 적용하세요.</p>
            <div class="flex items-center justify-between gap-3 text-[var(--fs-sm)] text-[var(--text-muted)]">
              ${r.slice(0,8).map(c=>L(c,!0))}
            </div>
          </details>
        `:null}
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">선택한 Session 요약</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${i&&t?s`
          <article class="ops-guidance-card p-3 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] flex flex-col gap-2 ${rt(p)}">
            <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
              <strong>${wt(p)}</strong>
              <span>${dt(x)}</span>
            </div>
            <div class="text-[var(--text-strong)] leading-[1.5]">
              ${(l==null?void 0:l.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="flex flex-wrap gap-2 text-[var(--text-muted)] text-[var(--fs-xs)]">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${yt(l)}</span>
              ${x!=null&&x.model_used?s`<span>${x.model_used}</span>`:null}
            </div>
          </article>
          ${f.length>0?s`
            <div class="flex flex-col gap-2">
              ${f.map(c=>s`
                <article key=${`${c.action_type}:${c.target_type}:${c.target_id??"session"}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] ${it(c.severity)}">
                  <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                    <strong>${ge(c.action_type)}</strong>
                    <span>${Pe(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  </div>
                  <div class="mt-1.5 whitespace-pre-wrap break-words">${c.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="flex flex-col gap-2">
            ${t.attention_items.length>0?t.attention_items.map(c=>s`
              <article key=${`${c.kind}:${c.target_id??"session"}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)] ${it(c.severity)}">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${c.kind}</strong>
                  <span>${Pe(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${c.summary}</div>
              </article>
            `):s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(c=>s`
              <article key=${`${c.actor??c.spawn_role??"worker"}:${c.spawn_agent??c.runtime_pool??"runtime"}`} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)]">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${c.actor??c.spawn_role??"worker"}</strong>
                  <span>${K(c.status)}</span>
                  <span>${c.spawn_agent??c.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">
                  ${c.worker_class??"worker"}${c.lane_id?` · ${c.lane_id}`:""}${c.routing_reason?` · ${c.routing_reason}`:""}
                </div>
              </article>
            `):null}
          </div>
        `:s`
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">세션을 고르면 세부 요약을 불러옵니다.</div>
        `}
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <div class="pb-2 border-b border-[var(--card-border)] mb-1">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">선택한 Session 액션</h3>
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">
          ${d?"선택한 live 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.":"종료된 세션은 여기서 읽기만 하고, 실제 개입은 위 live 세션을 다시 골라서 진행합니다."}
        </p>
        ${o.length>0?s`
          <div class="flex flex-col gap-2">
            ${o.map(c=>s`
              <article key=${c.action_type} class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-8)]">
                <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                  <strong>${ge(c.action_type)}</strong>
                  <span>${gt(c.confirm_required)}</span>
                </div>
                <div class="mt-1.5 whitespace-pre-wrap break-words">${c.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${i?s`
          <div class="flex flex-col gap-2">
            <div class="mt-1.5 whitespace-pre-wrap break-words">${i.session_id}</div>
            <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
              <span>상태: ${K(i.status)}</span>
              <span>경과: ${i.elapsed_sec??0}초</span>
              <span>남은 시간: ${i.remaining_sec??0}초</span>
              <span>${d?`팀 상태: ${pa(i)}`:"종료 세션"}</span>
            </div>
            ${i.linked_autoresearch?s`
              <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                <span>Autoresearch: ${String(i.linked_autoresearch.status??"unknown")}</span>
                <span>Loop: ${String(i.linked_autoresearch.loop_id??"n/a")}</span>
                <span>Cycle: ${String(i.linked_autoresearch.current_cycle??0)}</span>
                <span>Best: ${String(i.linked_autoresearch.best_score??"n/a")}</span>
              </div>
              <div class="text-[var(--fs-xs)] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis">
                <span>파일: ${i.linked_autoresearch.target_file??"n/a"}</span>
                <span>최근 결정: ${i.linked_autoresearch.last_decision??"n/a"}</span>
                <span>세션 연결: ${i.linked_autoresearch.session_id??i.session_id}</span>
                ${i.linked_autoresearch.operation_id?s`<span>작전: ${i.linked_autoresearch.operation_id}</span>`:null}
              </div>
              ${i.linked_autoresearch.program_note?s`<div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">Program note: ${i.linked_autoresearch.program_note}</div>`:null}
              ${i.linked_autoresearch.queued_hypothesis?s`<div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">Queued hypothesis: ${i.linked_autoresearch.queued_hypothesis}</div>`:null}
              ${i.linked_autoresearch.warnings&&i.linked_autoresearch.warnings.length>0?s`<div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">Warnings: ${i.linked_autoresearch.warnings.join(", ")}</div>`:null}
              ${i.linked_autoresearch.error?s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">${i.linked_autoresearch.error}</div>`:null}
            `:null}
            ${i.recent_events&&i.recent_events.length>0?s`
              <pre class="mt-2 py-[10px] px-3 rounded-xl bg-[rgba(8,15,29,0.82)] border border-solid border-[var(--white-8)] text-[#b9d6ff] text-[11px] leading-[1.45] overflow-x-auto whitespace-pre-wrap break-words max-h-[180px]">${xe(i.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">먼저 세션을 하나 고르세요.</div>`}

        ${i&&!d?s`
          <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">이 세션은 이미 종료돼서 새 노트, 작업, 중지를 보내지 않습니다. 위의 live 세션을 선택하세요.</div>
        `:null}

        ${m!=null&&m.loop_id?s`
          <label class="control-label" for="ops-autoresearch-hypothesis">Autoresearch 제어</label>
          <div class="control-row items-stretch">
            <button class="control-btn ghost" onClick=${()=>{b()}} disabled=${_}>
              상태 새로고침
            </button>
            <button class="control-btn" onClick=${()=>{C()}} disabled=${_}>
              1 cycle 실행
            </button>
            <button class="control-btn ghost" onClick=${()=>{u()}} disabled=${_}>
              loop 중지
            </button>
          </div>
          <textarea
            id="ops-autoresearch-hypothesis"
            class="control-textarea"
            rows=${2}
            placeholder="다음 cycle에 넣을 hypothesis"
            value=${we.value}
            onInput=${c=>{we.value=c.target.value}}
            disabled=${_}
          ></textarea>
          <div class="control-row items-stretch">
            <button class="control-btn" onClick=${()=>{$()}} disabled=${_||!we.value.trim()}>
              hypothesis 주입
            </button>
            <span class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">canonical control은 MCP tool이고, 이 화면은 그 상태를 읽고 이어서 제어합니다.</span>
          </div>
          ${He.value?s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">${He.value}</div>`:null}
        `:null}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row items-stretch">
          <select
            id="ops-turn-kind"
            class="control-input min-w-[92px]"
            value=${Z.value}
            onChange=${c=>{Z.value=c.target.value}}
            disabled=${_||!d}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{In()}} disabled=${_||!d}>
            적용
          </button>
        </div>
        <div class="-mt-0.5 text-[var(--text-muted)] text-[var(--fs-sm)] leading-[1.45]">현재 선택: ${kn(Z.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Be.value}
          onInput=${c=>{Be.value=c.target.value}}
          disabled=${_||!d}
        ></textarea>

        ${Z.value==="task"?s`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Ye.value}
            onInput=${c=>{Ye.value=c.target.value}}
            disabled=${_||!d}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Fe.value}
            onInput=${c=>{Fe.value=c.target.value}}
            disabled=${_||!d}
          ></textarea>
          <select
            class="control-input min-w-[92px]"
            value=${Oe.value}
            onChange=${c=>{Oe.value=c.target.value}}
            disabled=${_||!d}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:Z.value==="worker_spawn_batch"?s`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${We.value}
            onInput=${c=>{We.value=c.target.value}}
            disabled=${_||!d}
          ></textarea>
        `:null}

        <div class="control-row items-stretch">
          <input
            class="control-input"
            type="text"
            value=${nt.value}
            onInput=${c=>{nt.value=c.target.value}}
            disabled=${_||!d}
          />
          <button class="control-btn ghost" onClick=${()=>{En()}} disabled=${_||!d}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Nn(e,t=60){return e.length>t?e.slice(0,t)+"...":e}function Bn(e){const a=zs(e.name)??{name:e.name,agent_name:e.agent_name??e.name,status:e.status??"unknown",context_ratio:e.context_ratio,model:e.model};bs(a)}function Yn(){var o;const e=pe.value,t=(e==null?void 0:e.keepers)??[],a=(e==null?void 0:e.persistent_agents)??[],n=(e==null?void 0:e.available_actions)??[],r=t.find(i=>i.name===$t.value)??t[0]??null;return s`
    <div class="flex flex-col gap-4 min-w-0">
      <section class="${F} flex flex-col gap-3 min-h-0 ops-lane-panel ops-keeper-section">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">Keeper 개입</h3>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="flex flex-col gap-2">
          ${t.length===0?s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">지금 보이는 keeper가 없습니다.</div>`:t.map(i=>s`
            ${(()=>{const d=Ee(i),l=ot(i);return s`
            <button
              key=${i.name}
              class="ops-entity-card p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] text-inherit text-left cursor-pointer w-full ${(r==null?void 0:r.name)===i.name?"active":""}"
              onClick=${()=>{$t.value=i.name}}
            >
              <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
                <strong class="text-[13px] font-semibold">${i.name}</strong>
                <div class="flex items-center gap-2 ml-auto">
                  <span class="inline-flex items-center gap-1.5 text-[11px]">
                    <span class="w-2 h-2 rounded-full ${i.status==="offline"?"bg-[var(--text-muted)]":i.status==="active"||i.status==="running"?"bg-[var(--ok)]":"bg-[var(--warn)]"}"></span>
                    ${K(i.status)}
                  </span>
                  <span
                    class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] cursor-pointer transition-colors"
                    title="키퍼 상세 보기"
                    onClick=${p=>{p.stopPropagation(),Bn(i)}}
                  >상세</span>
                </div>
              </div>
              <div class="text-[11px] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                <span>${i.last_model_used??i.model??"model 확인 필요"}</span>
                <span>${typeof i.context_ratio=="number"?`${Math.round(i.context_ratio*100)}% ctx`:typeof i.context_tokens=="number"?`${Math.round(i.context_tokens/1e3)}k tok`:"ctx 확인 필요"}</span>
                <span>${ca(i.last_turn_ago_s)}</span>
              </div>
              ${i.short_goal||i.goal?s`
                <div class="text-[11px] text-[var(--text-muted)] mt-1.5 p-1 px-1.5 bg-[var(--white-3)] rounded" title=${i.goal??""}>${Nn(i.short_goal??i.goal??"")}</div>
              `:null}
              ${d!=="ok"?s`<div class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-1.5">점검 이유: ${l}</div>`:null}
              <div class="flex gap-2 text-[10px] text-[var(--text-muted)] mt-1">
                ${typeof i.turn_count=="number"?s`<span>turns: ${i.turn_count}</span>`:null}
                ${typeof i.autonomous_action_count=="number"?s`<span>actions: ${i.autonomous_action_count}</span>`:null}
                ${i.keepalive_running?s`<span class="text-[var(--ok)]">keepalive</span>`:null}
              </div>
            </button>
              `})()}
          `)}
        </div>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-3">Persistent agent는 resident keeper와 분리해서 참고용으로만 보여줍니다.</p>
        <div class="flex flex-col gap-2">
          ${a.length===0?s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">분리된 persistent agent는 없습니다.</div>`:a.map(i=>s`
                <article key=${i.name} class="p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
                  <div class="flex justify-between items-center gap-3 max-[880px]:flex-col max-[880px]:items-start">
                    <strong class="text-[13px] font-semibold">${i.name}</strong>
                    <span class="inline-flex items-center gap-1.5 text-[11px]">
                      <span class="w-2 h-2 rounded-full ${i.status==="offline"?"bg-[var(--text-muted)]":"bg-[var(--warn)]"}"></span>
                      ${K(i.status)}
                    </span>
                  </div>
                  <div class="text-[11px] text-[var(--text-muted)] mt-1 whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                    <span>persistent</span>
                    <span>${i.model??"model 확인 필요"}</span>
                    <span>${ca(i.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0 ops-lane-panel">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">선택한 Keeper 액션</h3>
        <p class="text-[12px] text-[var(--text-muted)] leading-[1.45]">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${r?s`
          <div class="flex flex-col gap-2">
            <div class="text-[13px] font-semibold text-[var(--text-strong)]">${r.name}</div>
            <div class="text-[11px] text-[var(--text-muted)] flex flex-wrap gap-2">
              <span>자율성: ${r.autonomy_level??"확인 없음"}</span>
              <span>세대: ${r.generation??0}</span>
              <span>활성 목표: ${((o=r.active_goal_ids)==null?void 0:o.length)??0}</span>
              ${typeof r.turn_count=="number"?s`<span>턴: ${r.turn_count}</span>`:null}
              ${r.last_model_used?s`<span>모델: ${r.last_model_used}</span>`:null}
            </div>
            ${Ee(r)!=="ok"?s`<div class="text-[12px] text-[var(--text-muted)] leading-[1.45] mt-1">현재 점검 이유: ${ot(r)}</div>`:null}
            ${r.goal?s`<div class="whitespace-normal mt-1.5 py-1 px-1.5 bg-[var(--white-3)] rounded text-[11px] text-[var(--text-muted)]">${r.goal}</div>`:null}
          </div>
          <${xs}
            keeperName=${r.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        `:s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0">
        <div class="flex items-center justify-between pb-2 border-b border-[var(--card-border)]">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">액션</h3>
          <span class="text-[12px] text-[var(--text-muted)]">${n.length}개</span>
        </div>
        ${n.length?s`<div class="flex flex-col gap-2">
              ${["room","keeper","team_session"].map(i=>{const d=n.filter(l=>l.target_type===i);return d.length===0?null:s`
                  <div key=${i}>
                    <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider mb-1">${Pe(i)}</div>
                    <div class="flex flex-wrap gap-1">
                      ${d.map(l=>s`
                        <span key=${l.action_type}
                          title=${l.description??""}
                          class="text-[12px] px-2 py-0.5 rounded cursor-default ${l.confirm_required?"bg-[var(--warn-12)] border border-[var(--warn-28)] text-[var(--warn)]":"bg-[var(--accent-8)] border border-[var(--accent-12)] text-[var(--accent)]"}">
                          ${ge(l.action_type)}
                        </span>
                      `)}
                    </div>
                  </div>
                `})}
            </div>`:s`<div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">액션 없음</div>`}
      </section>

      <section class="${F} flex flex-col gap-3 min-h-0">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)]">최근 개입 로그</h3>
        <div class="flex flex-col gap-2">
          ${Gt.value.length===0?s`
            <div class="p-3 rounded-xl border border-dashed border-[var(--card-border)] text-[var(--text-muted)] text-[13px]">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Gt.value.map(i=>s`
            <article key=${i.id} class="py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded ${it(i.outcome)}">
              <div class="text-[11px] text-[var(--text-muted)] whitespace-nowrap overflow-hidden text-ellipsis flex gap-2">
                <strong class="font-semibold">${ge(i.action_type)}</strong>
                <span>${i.target_label}</span>
                <span>${i.at}</span>
              </div>
              <div class="mt-1 text-[13px] whitespace-pre-wrap break-words text-[var(--text-body)]">${i.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function Fn(){var L,E;const e=pe.value,t=j.value.tab==="command"?qe(j.value):null,a=_a.value,n=(e==null?void 0:e.room)??{},r=(e==null?void 0:e.sessions)??[],o=(e==null?void 0:e.keepers)??[],i=xt(e),d=i.visible_count,l=i.total_count,p=i.hidden_count,x=i.actor_filter,m=r.find(c=>c.session_id===$e.value)??r[0]??null,_=(a==null?void 0:a.attention_items)??[],f=_.filter(wn),y=_.filter(yn),v=r.filter(c=>fn(c)!=="ok"),b=o.filter(c=>Ee(c)!=="ok"),$=b[0]??null,C=jn(t,r,o);H(()=>{Ut()},[]),H(()=>{if(j.value.tab!=="command"||j.value.params.section!=="intervene"){Ke.value=null;return}if(!t){Ke.value=null;return}Ke.value!==t.id&&(Ke.value=t.id,Mn(t))},[j.value.tab,j.value.params.source,j.value.params.action_type,j.value.params.target_type,j.value.params.target_id,j.value.params.focus_kind,t==null?void 0:t.id]),H(()=>{const c=(m==null?void 0:m.session_id)??null;Le(c)},[m==null?void 0:m.session_id]);const u=[{key:"room",label:"방 게이트",value:n.paused?"일시정지":"열림",detail:n.paused?`재개 전환 대기 중${n.pause_reason?` · ${n.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:n.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:p>0?`${d}/${l}`:d,detail:d>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":p>0&&x?`현재 개입 ID(${x}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${p}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:l>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:f.length>0?f.length:r.length,detail:f.length>0?((L=f[0])==null?void 0:L.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":r.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:f.length>0?ua(f):r.length===0?"warn":v.some(c=>fe(c.status)==="paused")?"bad":v.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:y.length>0?y.length:b.length,detail:y.length>0?((E=y[0])==null?void 0:E.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":b.length>0?`${($==null?void 0:$.name)??"키퍼"} · ${$?ot($):"점검 필요"}`:"지금은 키퍼 쪽이 비교적 안정적입니다",tone:y.length>0?ua(y):b.some(c=>Ee(c)==="bad")?"bad":b.length>0?"warn":"ok"}];return s`
    <section class="flex flex-col gap-4">
      <div class="${F} flex justify-between items-start gap-4 max-[880px]:flex-col">
        <div>
          <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-1">개입</h2>
          <p class="text-[13px] text-[var(--text-muted)] max-w-[62ch] leading-relaxed">
            방, 세션, 키퍼를 나눠 보고 바로 개입합니다.
          </p>
        </div>
        <div class="flex items-end gap-3 flex-wrap max-[880px]:w-full">
          <label class="text-[11px] text-[var(--text-muted)] uppercase tracking-[0.06em] font-medium" for="ops-actor">개입 ID</label>
          <input
            id="ops-actor"
            class="w-full px-3 py-2 rounded-lg bg-[var(--white-3)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] focus:border-[var(--accent)]/50 outline-none ops-actor-input min-w-[180px]"
            type="text"
            value=${Xe.value}
            onInput=${c=>xn(c.target.value)}
          />
          <button
            class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
            onClick=${()=>{ya(),ie(),Ut(),Le((m==null?void 0:m.session_id)??null)}}
            disabled=${mt.value||D.value}
          >
            ${mt.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Jt.value?s`<section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error">${Jt.value}</section>`:null}
      ${Zt.value?s`<section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] error">${Zt.value}</section>`:null}
      <${ja} />
      ${t?s`
        <section class="ops-banner rounded-xl py-3 px-3.5 border border-[var(--card-border)] ${C?"info":"warn"} grid gap-2">
          <div class="flex gap-2 flex-wrap items-center text-[var(--text-body)]">
            <strong class="font-semibold">${t.source_label}</strong>
            <span>${ka(t.action_type)}</span>
            <span>${Ca(t)}</span>
          </div>
          <div class="text-[var(--text-strong)] leading-relaxed">${t.summary}</div>
          ${t.payload_preview?s`<div class="mt-1 p-2 rounded-lg bg-[var(--white-3)] text-[12px] font-mono">${t.payload_preview}</div>`:null}
          <div class="text-[var(--text-muted)] text-[12px]">
            ${C?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const c=[];if((d>0||p>0)&&c.push({label:p>0?`확인 대기 ${d}/${l}건 확인`:`확인 대기 ${d}건 처리`,desc:p>0&&x?`현재 개입 ID(${x}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:d>0?"bad":"warn",onClick:()=>{const S=document.querySelector(".ops-pending-section");S==null||S.scrollIntoView({behavior:"smooth"})}}),n.paused&&c.push({label:"방 재개",desc:`현재 일시정지 상태${n.pause_reason?` (${n.pause_reason})`:""}`,tone:"warn",onClick:()=>void Oa()}),b.length>0){const S=b.filter(B=>Ee(B)==="bad");c.push({label:S.length>0?`오프라인 키퍼 ${S.length}개`:`점검이 필요한 키퍼 ${b.length}개`,desc:S.length>0?"메시지를 보내거나 상태를 확인하세요":`${($==null?void 0:$.name)??"일부 키퍼"} · ${$?ot($):"점검 필요"}`,tone:S.length>0?"bad":"warn",onClick:()=>{const B=document.querySelector(".ops-keeper-section");B==null||B.scrollIntoView({behavior:"smooth"})}})}return c.length===0?null:s`
          <section class="${F}">
            <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">지금 할 수 있는 것</h3>
            <div class="flex flex-col gap-2">
              ${c.slice(0,3).map(S=>s`
                <button class="ops-action-guide-item rounded-lg ${S.tone}" onClick=${S.onClick}>
                  <strong class="font-semibold">${S.label}</strong>
                  <span>${S.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="${F}">
        <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-1">개입 우선순위</h2>
        <p class="text-[12px] text-[var(--text-muted)] mb-4">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        <div class="ops-priority-grid grid grid-cols-4 gap-3 max-[1200px]:grid-cols-2 max-[880px]:grid-cols-1">
          ${u.map(c=>s`
            <div key=${c.key} class="ops-priority-card p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-1.5 ${c.tone}">
              <span class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.06em] font-medium">${c.label}</span>
              <strong>${c.value}</strong>
              <div class="text-[var(--text-muted)] text-[12px] leading-[1.45]">${c.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench grid gap-4 max-[1200px]:grid-cols-1">
        <${Ln} />
        <${An} />
        <${Yn} />
      </div>
    </section>
  `}function Y({label:e,value:t,detail:a,tone:n,highlight:r}){return s`
    <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl p-4 flex flex-col gap-2 cmd-stat-card ${n??""} ${r?"highlight":""}">
      <span>${e}</span>
      <strong>${t}</strong>
      ${a!=null?s`<small>${a}</small>`:null}
    </div>
  `}function On(){const e=qe(j.value);return e?s`
    <section class="rounded-xl border border-[rgba(34,211,238,0.26)] bg-[linear-gradient(180deg,rgba(34,211,238,0.1),var(--white-3))] p-4 grid gap-3">
      <div class="flex gap-3 flex-wrap items-center">
        <strong>${e.source_label}</strong>
        <${g} label=${ka(e.action_type)} />
        <${g} label=${Ca(e)} />
        <${g} label=${fs(j.value.params.surface??"warroom")} />
      </div>
      <div class="text-[rgba(255,255,255,0.84)] leading-normal">${e.summary}</div>
      ${e.payload_preview?s`<div class="py-3 px-3 border border-[var(--white-8)] bg-[var(--white-5)] text-[var(--text-strong)] leading-snug rounded-xl">${e.payload_preview}</div>`:null}
    </section>
  `:null}function Wn(){const e=O.value,t=Vs[e],a=Ds(e);return s`
    <section class="grid grid-cols-2 gap-3">
      <article class="p-4 rounded-xl border border-[var(--border-slate-16)] bg-[var(--white-3h)] grid gap-2">
        <span class="text-[rgba(148,163,184,0.92)] text-[11px] uppercase tracking-[0.08em]">현재 표면</span>
        <strong class="text-[var(--text-near-white)] text-lg leading-[1.2] break-words">${t.title}</strong>
        <p class="m-0 text-[var(--frost-72)] leading-normal">${t.description}</p>
      </article>
      <article class="p-4 rounded-xl border border-[var(--border-slate-16)] bg-[var(--white-3h)] grid gap-2">
        <span class="text-[rgba(148,163,184,0.92)] text-[11px] uppercase tracking-[0.08em]">다음 추천</span>
        <strong class="text-[var(--text-near-white)] text-lg leading-[1.2] break-words">${a.tool}</strong>
        <p class="m-0 text-[var(--frost-72)] leading-normal">${a.reason}</p>
      </article>
    </section>
  `}function Ge({label:e,value:t,subtext:a,percent:n,color:r}){return s`
    <article class="grid grid-cols-[88px_minmax(0,1fr)] gap-3 items-center p-3 rounded-2xl bg-[rgba(255,255,255,0.045)] border border-solid border-[var(--white-8)] min-w-0">
      <div class="cmd-gauge-ring" style=${Hs(n,r)}>
        <div class="w-full h-full rounded-full bg-[rgba(8,14,28,0.92)] border border-solid border-[var(--white-6)] grid place-items-center content-center text-center">
          <strong>${t}</strong>
          <span>${Math.round(_t(n))}%</span>
        </div>
      </div>
      <div class="grid gap-1 min-w-0">
        <span>${e}</span>
        <small>${a}</small>
      </div>
    </article>
  `}function Ue({label:e,value:t,detail:a,percent:n,tone:r}){return s`
    <article class="p-4 rounded-[14px] bg-[var(--white-3h)] border border-[var(--white-8)] grid gap-3 cmd-signal-rail ${h(r)}">
      <div class="flex items-baseline justify-between gap-3">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="relative h-2 overflow-hidden bg-[var(--white-6)] rounded-full cmd-signal-bar">
        <span class="${h(r)}" style=${`width: ${Math.max(8,Math.round(_t(n)))}%`}></span>
      </div>
      <small>${a}</small>
    </article>
  `}function qn(){var W,q,X,w;const e=ze(),t=e==null?void 0:e.topology.summary,a=e==null?void 0:e.operations.summary,n=e==null?void 0:e.detachments.summary,r=e==null?void 0:e.decisions.summary,o=e==null?void 0:e.alerts.summary,i=(W=e==null?void 0:e.swarm_status)==null?void 0:W.overview,d=e==null?void 0:e.swarm_proof,l=e==null?void 0:e.operations.microarch,p=(t==null?void 0:t.managed_unit_count)??0,x=(t==null?void 0:t.total_units)??0,m=(a==null?void 0:a.active)??0,_=(n==null?void 0:n.active)??0,f=(i==null?void 0:i.moving_lanes)??0,y=(i==null?void 0:i.active_lanes)??0,v=(d==null?void 0:d.workers.done)??0,b=(d==null?void 0:d.workers.expected)??0,$=(o==null?void 0:o.bad)??0,C=(o==null?void 0:o.warn)??0,u=(r==null?void 0:r.pending)??0,L=(r==null?void 0:r.total)??0,E=m+_,c=((q=l==null?void 0:l.cache)==null?void 0:q.l1_hit_rate)??((w=(X=l==null?void 0:l.signals)==null?void 0:X.cache_contention)==null?void 0:w.l1_hit_rate)??0,S=m>0||_>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",B=m>0||f>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return s`
    <section class="relative overflow-hidden border border-[rgba(103,232,249,0.16)] rounded-[18px] p-[18px] mb-4 shadow-[inset_0_1px_0_var(--white-4)] cmd-hero grid grid-cols-[minmax(0,1.1fr)_minmax(300px,0.9fr)] gap-[18px] items-center">
      <div class="relative z-[1] grid gap-3">
        <span class="inline-flex w-fit items-center gap-2 py-[5px] px-[10px] rounded-full text-[#7dd3fc] bg-[rgba(14,116,144,0.22)] border border-solid border-[rgba(125,211,252,0.18)] text-[11px] tracking-[0.08em] uppercase">현재 지휘 상태</span>
        <h3>${S}</h3>
        <p>${B}</p>
        <div class="flex flex-wrap gap-2">
        <${g} label=${`활성 작전 ${m}`} tone=${h(m>0?"ok":"warn")} />
          <${g} label=${`이동 레인 ${f}/${Math.max(y,f)}`} tone=${h(f>0?"ok":(y>0,"warn"))} />
          <${g} label=${`치명 알림 ${$}`} tone=${h($>0?"bad":C>0?"warn":"ok")} />
          <${g} label=${`승인 대기 ${u}`} tone=${h(u>0?"warn":"ok")} />
        </div>
      </div>

      <div class="relative z-[1] grid grid-cols-2 gap-3">
        <${Ge}
          label="관리 단위 범위"
          value=${`${p}/${Math.max(x,p)}`}
          subtext=${x>0?`${x-p}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${ve(p,Math.max(x,p))}
          color="#67e8f9"
        />
        <${Ge}
          label="실행 열도"
          value=${String(E)}
          subtext=${`${m}개 작전 + ${_}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${ve(E,Math.max(p,E||1))}
          color="#4ade80"
        />
        <${Ge}
          label="스웜 이동감"
          value=${`${f}/${Math.max(y,f)}`}
          subtext=${i!=null&&i.last_movement_at?`마지막 이동 ${T(i.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${ve(f,Math.max(y,f||1))}
          color="#fbbf24"
        />
        <${Ge}
          label="증거 수집률"
          value=${`${v}/${Math.max(b,v)}`}
          subtext=${d!=null&&d.status?`증거 소스 ${d.source} · ${d.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${ve(v,Math.max(b,v||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="grid grid-cols-[repeat(auto-fit,minmax(210px,1fr))] gap-3 mb-4">
      <${Ue}
        label="승인 대기열"
        value=${`${u}건 대기`}
        detail=${`현재 정책 창에서 ${L}개 결정을 추적 중입니다`}
        percent=${ve(u,Math.max(L,u||1))}
        tone=${u>0?"warn":"ok"}
      />
      <${Ue}
        label="알림 압력"
        value=${`치명 ${$} / 주의 ${C}`}
        detail=${$>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${ve($*2+C,Math.max(($+C)*2,1))}
        tone=${$>0?"bad":C>0?"warn":"ok"}
      />
      <${Ue}
        label="디스패치 점유"
          value=${`${_}개 가동`}
        detail=${p>0?`${p}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${ve(_,Math.max(p,_||1))}
        tone=${_>0?"ok":"warn"}
      />
      <${Ue}
        label="캐시 신뢰도"
        value=${c?je(c):"정보 없음"}
        detail=${c?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${_t((c??0)*100)}
        tone=${c>=.75?"ok":c>=.4?"warn":"bad"}
      />
    </div>
  `}function zn(){var _,f,y,v,b;const e=ze(),t=bt.value,a=qe(j.value),n=Ks(a),r=e==null?void 0:e.topology.summary,o=e==null?void 0:e.operations.summary,i=(_=e==null?void 0:e.swarm_status)==null?void 0:_.overview,d=e==null?void 0:e.operations.microarch,l=e==null?void 0:e.decisions.summary,p=e==null?void 0:e.alerts.summary,x=(f=d==null?void 0:d.signals)==null?void 0:f.issue_pressure,m=d==null?void 0:d.cache;return s`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
      <${Y} label="유닛" value=${(r==null?void 0:r.total_units)??0} detail=${`${(r==null?void 0:r.managed_unit_count)??0}개 관리 중`} />
      <${Y} label="작전" value=${(o==null?void 0:o.active)??0} detail=${`${((y=e==null?void 0:e.detachments.summary)==null?void 0:y.active)??0}개 실행체`} />
      <${Y} label="승인" value=${(l==null?void 0:l.pending)??0} detail=${`${(l==null?void 0:l.total)??0}개 추적 중`} />
      <${Y} label="알림" value=${(p==null?void 0:p.bad)??0} detail=${`${(p==null?void 0:p.warn)??0}건 주의`} highlight=${n==="alerts"} />
      <${Y} label="체인" value=${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0} detail=${`${((b=t==null?void 0:t.summary)==null?void 0:b.linked_operations)??0}개 연결`} />
      <${Y} label="스웜" value=${(i==null?void 0:i.active_lanes)??0} detail=${i?`${i.stalled_lanes??0}개 정체 · ${T(i.last_movement_at)}`:"lane snapshot 없음"} highlight=${n==="swarm"} />
      <${Y} label="마이크로아크" value=${(x==null?void 0:x.pending_ops)??0} detail=${`${(m==null?void 0:m.l1_hit_rate)!=null?`${je(m.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(x==null?void 0:x.tone)??"정보 없음"}`} highlight=${n==="microarch"} />
    </div>
  `}function Xn(){var W,q,X,w,k,A,R,G,se;const e=ze(),t=_e.value,a=_s.value,n=Gs(),r=n?Sa.value.find(P=>P.name===n)??null:null,o=n?ct.value.filter(P=>P.assignee===n&&Us(P)):[],i=((W=e==null?void 0:e.operations.summary)==null?void 0:W.active)??0,d=((q=e==null?void 0:e.detachments.summary)==null?void 0:q.total)??0,l=((X=e==null?void 0:e.decisions.summary)==null?void 0:X.pending)??0,p=t==null?void 0:t.detachments.detachments.find(P=>{const J=P.detachment.heartbeat_deadline,re=J?Date.parse(J):Number.NaN;return P.detachment.status==="stalled"||!Number.isNaN(re)&&re<=Date.now()}),x=t==null?void 0:t.alerts.alerts.find(P=>P.severity==="bad"),m=!!(a!=null&&a.room||a!=null&&a.project),_=(r==null?void 0:r.current_task)??null,f=Js(r==null?void 0:r.last_seen),y=f!=null?f<=120:null,v=[m?{title:"Room 준비도",tone:"ok",detail:`${(a==null?void 0:a.room)??(a==null?void 0:a.project)??"unknown"} · base ${(a==null?void 0:a.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},n?r?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${n} 에게 배정된 claimed task가 없습니다. backlog에 task가 있으면 masc_transition(action=claim)으로 집고, 없으면 새 task를 만들어야 합니다.`,tool:ct.value.length>0?"masc_transition":"masc_add_task"}:_?y===!1?{title:"Task 준비도",tone:"warn",detail:`${n} current_task=${_} 이지만 heartbeat가 stale 합니다 (${f}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${n} current_task=${_}${f!=null?` · 마지막 활동 ${f}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${n} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${n} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((w=e.topology.summary)==null?void 0:w.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:i===0?{title:"작전 준비도",tone:"warn",detail:`${((k=e.topology.summary)==null?void 0:k.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((A=e.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위 위에서 ${i}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},l>0?{title:"디스패치 준비도",tone:"warn",detail:`${l}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:i>0&&d===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:p||x?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${p?` · detachment ${p.detachment.detachment_id} 가 stalled 상태입니다`:""}${x?` · alert ${x.title??x.alert_id}`:""}${!t&&!p&&!x?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:l>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${d}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],b=m?!n||!r?"masc_join":o.length===0?ct.value.length>0?"masc_transition":"masc_add_task":_?y===!1?"masc_heartbeat":!e||(((R=e.topology.summary)==null?void 0:R.managed_unit_count)??0)===0?"masc_unit_define":i===0?"masc_operation_start":l>0?"masc_policy_approve":i>0&&d===0||p||x?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",$=Zs(b),u=Qs(b==="masc_set_room"?["repo-root-room"]:b==="masc_plan_set_task"?["claimed-not-current"]:b==="masc_heartbeat"?["heartbeat-stale"]:b==="masc_dispatch_tick"?["no-detachments"]:b==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),L=pt("room_task_hygiene"),E=pt("cpv2_benchmark"),c=pt("supervisor_session"),S=((G=ws.value)==null?void 0:G.docs)??[],B=[L,E,c].filter(P=>P!==null);return s`
    <div class="grid grid-cols-[minmax(0,1.06fr)_minmax(0,0.94fr)] gap-4">
      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">즉시 조치</div>
        </div>
        <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card highlight mb-3">
          <div class="flex justify-between gap-3 items-start">
            <strong>${($==null?void 0:$.title)??b}</strong>
            <${g} label=${b} tone="ok" />
          </div>
          <p>${($==null?void 0:$.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(se=$==null?void 0:$.success_signals)!=null&&se.length?s`<div class="cmd-tag rounded-full-row">
                ${$.success_signals.map(P=>s`<span class="cmd-tag rounded-full ok">${P}</span>`)}
              </div>`:null}
        </div>

        <div class="flex flex-col gap-3">
          ${v.map(P=>s`
            <article class="flex flex-col gap-3 p-4 border border-[var(--white-8)] bg-[var(--white-3)] rounded-xl cmd-readiness-row ${h(P.tone)}">
              <div>
                <div class="flex justify-between gap-3 items-start">
                  <strong>${P.title}</strong>
                  <${g} label=${P.tone} tone=${h(P.tone)} />
                </div>
                <p>${P.detail}</p>
              </div>
              <div class="cmd-card rounded-xl-foot">Next tool: ${P.tool}</div>
            </article>
          `)}
        </div>

        ${u.length>0?s`
              <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card warn">
                <div class="flex justify-between gap-3 items-start">
                  <strong>자주 막히는 지점</strong>
                  <${g} label=${String(u.length)} tone="warn" />
                </div>
                <div class="flex flex-col gap-3">
                  ${u.map(P=>s`
                    <article class="p-3 rounded-[10px] bg-[rgba(9,12,20,0.5)] border border-solid border-[var(--white-6)] break-words [overflow-wrap:anywhere]">
                      <strong>${P.title}</strong>
                      <div>${P.symptom}</div>
                      <div class="cmd-card rounded-xl-sub">${P.fix_tool} 로 해결: ${P.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">운영 경로</div>
        </div>
        ${ys.value?s`<${M} message="CPv2 runbook 불러오는 중…" compact />`:ea.value?s`<${M} message=${ea.value} compact />`:s`
                <div class="grid gap-3">
                  ${B.map(P=>s`
                    <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card">
                      <div class="flex justify-between gap-3 items-start">
                        <strong>${P.title}</strong>
                        <${g} label=${P.id} />
                      </div>
                      <p>${P.summary}</p>
                      <div class="cmd-card rounded-xl-sub">${P.when_to_use}</div>
                      <div class="flex flex-col gap-1.5 mt-3">
                        ${P.steps.slice(0,4).map(J=>s`
                          <div class="flex gap-3 flex-wrap items-baseline">
                            <span class="font-mono text-[#67e8f9] text-[13px]">${J.tool}</span>
                            <span>${J.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${S.length>0?s`<div class="flex flex-wrap gap-2 mt-3">
                      ${S.map(P=>s`<span class="cmd-tag rounded-full">${P.title}: ${P.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Dn(){return s`
    <${qn} />
    <${zn} />
    <${Xn} />
  `}function Vn(){return hs.value?s`<${M} message="command-plane detail 불러오는 중…" compact />`:Qt.value?s`<${M} message=${Qt.value} compact />`:s`<${M} message="surface를 선택하면 command-plane detail을 로드합니다." compact />`}const me=N(null),Je=N("compact"),oe=N({zoom:1,panX:0,panY:0}),vt=N(!1),Ze=N(!1),Te={width:1280,height:760},qa=.42,za=1.9;function at(e,t,a){return Math.max(t,Math.min(a,e))}function kt(e,t){const a=e==null?void 0:e.trim();return a?a.length<=t?a:`${a.slice(0,Math.max(1,t-1))}…`:null}function $a(e){switch((e??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(e==null?void 0:e.trim())||"노드"}}function ga(e,t,a){const n={...a};if(delete n.section,delete n.surface,e==="command"){if(t){te(t),ee("operations",{...be(t),...n});return}ee("operations",{section:"command",...n});return}if(e==="intervene"){ee("operations",{section:"intervene",...n});return}ee("operations",{section:"command",...n})}function Xa(e,t){return e.kind==="room"?t==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:e.kind==="worker"?t==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:e.kind==="lane"?t==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:e.kind==="keeper"?t==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:e.kind==="session"?t==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:t==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function Kn(e,t){const a=e.kind==="worker"?t==="compact"?10:14:e.kind==="keeper"?t==="compact"?12:16:e.kind==="lane"?t==="compact"?16:22:t==="compact"?18:26;return kt(e.label,a)??e.label}function Hn(e,t){if(t==="compact"&&(e.kind==="worker"||e.kind==="keeper"||e.kind==="detachment"))return null;const a=e.kind==="session"?t==="compact"?20:28:t==="compact"?14:24;return kt(e.subtitle,a)}function Gn(e,t){return t==="compact"&&e.kind!=="session"&&e.kind!=="operation"?null:kt(e.status,t==="compact"?10:14)}function Un(e,t){const a=(e.x+t.x)/2,n=t.y>=e.y?32:-32;return`M ${e.x} ${e.y} C ${a} ${e.y+n}, ${a} ${t.y-n}, ${t.x} ${t.y}`}function Da(e){var n,r;const t=me.value;if(t){const o=e.nodes.find(d=>d.id===t);if(o)return{type:"node",value:o};const i=e.signals.find(d=>d.id===t);if(i)return{type:"signal",value:i}}if(((n=e.focus)==null?void 0:n.target_kind)==="node"){const o=e.nodes.find(i=>{var d;return i.id===((d=e.focus)==null?void 0:d.target_id)});if(o)return{type:"node",value:o}}if(((r=e.focus)==null?void 0:r.target_kind)==="signal"){const o=e.signals.find(i=>{var d;return i.id===((d=e.focus)==null?void 0:d.target_id)});if(o)return{type:"signal",value:o}}const a=e.nodes[0];return a?{type:"node",value:a}:null}function Jn(e,t,a,n){let r=Number.POSITIVE_INFINITY,o=Number.NEGATIVE_INFINITY,i=Number.POSITIVE_INFINITY,d=Number.NEGATIVE_INFINITY;for(const l of e.nodes){const p=t.get(l.id);if(!p)continue;const x=Xa(l,n);l.kind==="room"?(r=Math.min(r,p.x-x.radius),o=Math.max(o,p.x+x.radius),i=Math.min(i,p.y-x.radius),d=Math.max(d,p.y+x.radius)):(r=Math.min(r,p.x-x.width/2),o=Math.max(o,p.x+x.width/2),i=Math.min(i,p.y-x.height/2),d=Math.max(d,p.y+x.height/2))}for(const l of a)r=Math.min(r,l.x-20),o=Math.max(o,l.x+20),i=Math.min(i,l.y-20),d=Math.max(d,l.y+20);return!Number.isFinite(r)||!Number.isFinite(o)||!Number.isFinite(i)||!Number.isFinite(d)?{minX:0,minY:0,maxX:Te.width,maxY:Te.height,width:Te.width,height:Te.height}:{minX:r,minY:i,maxX:o,maxY:d,width:Math.max(1,o-r),height:Math.max(1,d-i)}}function xa(e,t,a){const n=a==="compact"?48:72,r=Math.max(360,t.width-n*2),o=Math.max(280,t.height-n*2),i=at(Math.min(r/Math.max(e.width,1),o/Math.max(e.height,1)),qa,za),d=e.minX+e.width/2,l=e.minY+e.height/2;return{zoom:i,panX:t.width/2-d*i,panY:t.height/2-l*i}}function Zn({signalNodes:e,roomPoint:t,onSelect:a}){return!t||e.length===0?null:s`
    ${e.map(({signalNode:n,x:r,y:o})=>s`
      <g
        key=${n.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${h(n.tone)}`}
        onClick=${()=>a(n.id)}
      >
        <title>${n.label}${n.detail?` — ${n.detail}`:""}</title>
        <line x1=${t.x} y1=${t.y} x2=${r} y2=${o} class="orchestra-signal-link" />
        <circle cx=${r} cy=${o} r="16" class="orchestra-signal-dot" />
        <text x=${r} y=${o+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function Qn({edges:e,positions:t,selectedId:a}){return s`
    ${e.map(n=>{const r=t.get(n.source),o=t.get(n.target);if(!r||!o)return null;const i=a!=null&&(n.source===a||n.target===a);return s`
        <path
          key=${n.id}
          d=${Un(r,o)}
          class=${`orchestra-edge ${h(n.tone)} ${n.animated?"animated":""} ${i?"active":""}`}
        />
      `})}
  `}function er({orchestra:e,positions:t,density:a,selectedId:n,onSelect:r}){var i;const o=((i=e.focus)==null?void 0:i.target_kind)==="node"?e.focus.target_id:null;return s`
    ${e.nodes.map(d=>{const l=t.get(d.id);if(!l)return null;const p=Xa(d,a),x=d.id===n,m=d.id===o,_=d.visual_class??d.kind,f=Kn(d,a),y=Hn(d,a),v=Gn(d,a);if(d.kind==="room")return s`
          <g
            key=${d.id}
            data-orchestra-node="true"
            class=${`orchestra-node room cursor-pointer ${h(d.tone)} ${x?"selected":""} ${m?"focused":""}`}
            onClick=${()=>r(d.id)}
          >
            <title>${d.label}</title>
            <circle cx=${l.x} cy=${l.y} r=${p.radius} class="orchestra-room-ring outer" />
            <circle cx=${l.x} cy=${l.y} r=${p.radius-16} class="orchestra-room-ring inner" />
            <text x=${l.x} y=${l.y-10} text-anchor="middle" class="orchestra-room-glyph">${d.glyph??"◎"}</text>
            <text x=${l.x} y=${l.y+22} text-anchor="middle" class="orchestra-room-label">${f}</text>
          </g>
        `;const b=l.x-p.width/2,$=l.y-p.height/2;return s`
        <g
          key=${d.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${_} cursor-pointer ${h(d.tone)} ${x?"selected":""} ${m?"focused":""}`}
          onClick=${()=>r(d.id)}
        >
          <title>${d.label}${d.subtitle?` — ${d.subtitle}`:""}${d.status?` (${d.status})`:""}</title>
          <rect x=${b} y=${$} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${b+16} y=${$+24} class="orchestra-node-glyph">${d.glyph??"•"}</text>
          <text x=${b+38} y=${$+24} class="orchestra-node-label">${f}</text>
          ${y?s`<text x=${b+38} y=${$+42} class="orchestra-node-subtitle">${y}</text>`:null}
          ${v?s`<text x=${b+p.width-10} y=${$+18} text-anchor="end" class="orchestra-node-status">${v}</text>`:null}
        </g>
      `})}
  `}function tr({orchestra:e}){const t=Da(e);if(!t)return s`<aside class="orchestra-drawer flex flex-col gap-3 min-h-[720px] card rounded-xl"><${M} message="선택 가능한 대상이 아직 없습니다." compact /></aside>`;if(t.type==="signal"){const o=t.value;return s`
      <aside class="orchestra-drawer flex flex-col gap-3 min-h-[720px] card rounded-xl ${h(o.tone)}">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">${o.label}</div>
          <${g} label=${$a(o.kind)} tone=${h(o.tone)} />
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?s`
              <div class="flex gap-3 flex-wrap mt-3">
                <${z}
                  onClick=${()=>ga("command",o.suggested_surface,o.suggested_params??{})}
                >
                  추천 화면 열기
                <//>
              </div>
            `:null}
      </aside>
    `}const a=t.value,n=e.signals.filter(o=>o.source_id===a.id||o.target_id===a.id),r=e.edges.filter(o=>o.source===a.id||o.target===a.id);return s`
    <aside class="orchestra-drawer flex flex-col gap-3 min-h-[720px] card rounded-xl ${h(a.tone)}">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">${a.label}</div>
        <${g} label=${$a(a.kind)} tone=${h(a.tone)} />
      </div>
      ${a.subtitle?s`<p class="cmd-card rounded-xl-sub">${a.subtitle}</p>`:null}
      <div class="orchestra-fact-list flex flex-col gap-2">
        ${a.facts.map(o=>s`
          <div class="flex justify-between gap-3 py-2 px-2.5 rounded-[10px] bg-[var(--white-3)] border border-[var(--white-6)]">
            <span class="text-[rgba(226,232,240,0.64)] text-[0.82rem]">${o.label}</span>
            <strong class="text-[var(--text-near-white)] text-[0.84rem] text-right">${o.value}</strong>
          </div>
        `)}
      </div>
      ${n.length>0?s`
        <div class="cmd-tag rounded-full-row">
          ${n.map(o=>s`<${g} label=${o.label} tone=${h(o.tone)} />`)}
        </div>
      `:null}
      <div class="cmd-card rounded-xl-sub">연결 ${r.length}개 · 근거 ${a.provenance}</div>
      ${a.link_tab&&(a.link_surface||Object.keys(a.link_params??{}).length>0)?s`
            <div class="flex gap-3 flex-wrap mt-3">
              <${z}
                onClick=${()=>ga(a.link_tab??"command",a.link_surface,a.link_params??{})}
              >
                이 화면 열기
              <//>
            </div>
          `:null}
    </aside>
  `}function ar(e){return e==="compact"?"집약":"균형"}function Qe(e,t,a){if(e<=0)return[];if(e===1)return[Math.round((t+a)/2)];const n=(a-t)/(e-1);return Array.from({length:e},(r,o)=>Math.round(t+o*n))}function Va(e){return e==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function sr(e,t){const a=Va(t),n=new Map,r=e.nodes,o=r.find(v=>v.kind==="room")??null,i=r.filter(v=>v.kind==="session"),d=r.filter(v=>v.kind==="operation"),l=r.filter(v=>v.kind==="detachment"),p=r.filter(v=>v.kind==="lane"),x=r.filter(v=>v.kind==="worker"),m=r.filter(v=>v.kind==="keeper");o&&n.set(o.id,{x:a.room.x,y:a.room.y}),Qe(i.length,a.sessions.min,a.sessions.max).forEach((v,b)=>{const $=i[b];$&&n.set($.id,{x:v,y:a.sessions.y})}),Qe(d.length,a.operations.min,a.operations.max).forEach((v,b)=>{const $=d[b];$&&n.set($.id,{x:v,y:a.operations.y})}),Qe(l.length,a.detachments.min,a.detachments.max).forEach((v,b)=>{const $=l[b];$&&n.set($.id,{x:v,y:a.detachments.y})}),Qe(p.length,a.lanes.min,a.lanes.max).forEach((v,b)=>{const $=p[b];$&&n.set($.id,{x:v,y:a.lanes.y})});const _=new Map(p.map(v=>{const b=n.get(v.id);return b?[v.id,b.x]:null}).filter(v=>v!==null)),f=Ss(x,v=>v.lane_id?`lane:${v.lane_id}`:v.parent_id?v.parent_id:"free");let y=0;for(const[v,b]of f){let $=_.get(v.replace(/^lane:/,""));if($==null){const u=n.get(v);$=u==null?void 0:u.x}$==null&&($=260+y%4*180,y+=1);const C=Math.max(1,Math.ceil(b.length/a.worker.perRow));for(let u=0;u<C;u+=1){const L=b.slice(u*a.worker.perRow,(u+1)*a.worker.perRow),E=(L.length-1)*a.worker.xSpacing,c=$-E/2;L.forEach((S,B)=>{var W;n.set(S.id,{x:Math.round(c+B*a.worker.xSpacing),y:v==="free"?a.worker.freeBaseY+u*a.worker.ySpacing:(((W=n.get(v.replace(/^lane:/,"")))==null?void 0:W.y)??a.lanes.y)+a.worker.laneOffsetY+u*a.worker.ySpacing})})}}return m.forEach((v,b)=>{const $=b%a.keeper.columns,C=Math.floor(b/a.keeper.columns);n.set(v.id,{x:a.keeper.startX+$*a.keeper.colSpacing,y:a.keeper.startY+C*a.keeper.rowSpacing})}),n}function nr(e,t,a){if(!t||e.signals.length===0)return[];const n=Va(a);return e.signals.slice(0,6).map((r,o)=>{const i=(-130+o*36)*(Math.PI/180);return{signalNode:r,x:Math.round(t.x+Math.cos(i)*n.signalRadius),y:Math.round(t.y+Math.sin(i)*n.signalRadius)}})}function rr(){var B,W,q,X;const e=ks.value,t=Ie(null),a=Ie(null),n=Ie(""),[r,o]=ht(Te);if(H(()=>{const w=t.current;if(!w)return;const k=()=>{const R=w.getBoundingClientRect();R.width<=0||R.height<=0||o({width:Math.max(640,Math.round(R.width)),height:Math.max(480,Math.round(R.height))})};if(k(),typeof ResizeObserver>"u")return window.addEventListener("resize",k),()=>window.removeEventListener("resize",k);const A=new ResizeObserver(()=>k());return A.observe(w),()=>A.disconnect()},[]),Cs.value&&!e)return s`<section class="card rounded-xl min-h-[240px]"><${M} message="오케스트라 맵 불러오는 중…" compact /></section>`;if(ta.value)return s`<section class="card rounded-xl min-h-[240px]"><${M} message=${ta.value} compact /></section>`;if(!e)return s`<section class="card rounded-xl min-h-[240px]"><${M} message="오케스트라 맵 데이터가 아직 없습니다." compact /></section>`;const i=Je.value,d=sr(e,i),l=e.nodes.find(w=>w.kind==="room")??null,p=l?d.get(l.id)??null:null,x=nr(e,p,i),m=Jn(e,d,x,i),_=Da(e),f=(_==null?void 0:_.value.id)??null,y=`${i}:${r.width}x${r.height}:${e.nodes.length}:${e.edges.length}:${e.signals.length}`,v=(w,k)=>{oe.value=w,Ze.value=k},b=()=>{v(xa(m,r,i),!1)},$=()=>{if(me.value=null,i!=="compact"){Je.value="compact",Ze.value=!1;return}b()};H(()=>{f&&!e.nodes.some(w=>w.id===f)&&!e.signals.some(w=>w.id===f)&&(me.value=null)},[y,f,e]),H(()=>{(!Ze.value||n.current!==y)&&(v(xa(m,r,i),!1),n.current=y)},[y]);const C=oe.value,u=(w,k,A)=>{const R=oe.value.zoom,G=at(R*A,qa,za);if(Math.abs(G-R)<.001)return;const se=(w-oe.value.panX)/R,P=(k-oe.value.panY)/R;v({zoom:G,panX:w-se*G,panY:k-P*G},!0)},L=w=>{w.preventDefault();const k=t.current;if(!k)return;const A=k.getBoundingClientRect(),R=at(w.clientX-A.left,0,A.width),G=at(w.clientY-A.top,0,A.height);u(R,G,w.deltaY<0?1.1:.92)},E=w=>{var R;const k=w.target;if(!(k instanceof Element)||!k.closest('[data-orchestra-background="true"]'))return;const A=w.currentTarget;A&&(a.current={pointerId:w.pointerId,startX:w.clientX,startY:w.clientY,panX:oe.value.panX,panY:oe.value.panY},vt.value=!0,Ze.value=!0,(R=A.setPointerCapture)==null||R.call(A,w.pointerId))},c=w=>{const k=a.current;!k||k.pointerId!==w.pointerId||v({zoom:oe.value.zoom,panX:k.panX+(w.clientX-k.startX),panY:k.panY+(w.clientY-k.startY)},!0)},S=w=>{var A;if(!a.current)return;const k=w==null?void 0:w.currentTarget;k&&w&&((A=k.releasePointerCapture)==null||A.call(k,w.pointerId)),a.current=null,vt.value=!1};return s`
    <section class="card rounded-xl min-h-[240px] overflow-hidden">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">오케스트라 맵</div>
      </div>
      <p class="cmd-card rounded-xl-sub">
        룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <${z} variant="ghost" onClick=${b}>맞춤 보기<//>
          <${z} variant="ghost" onClick=${$}>초기화<//>
        </div>
        <div class="orchestra-toolbar-group">
          <${z}
            variant="ghost"
            onClick=${()=>u(r.width/2,r.height/2,1.12)}
          >
            확대
          <//>
          <${z}
            variant="ghost"
            onClick=${()=>u(r.width/2,r.height/2,.9)}
          >
            축소
          <//>
          <${g} label=${`${Math.round(C.zoom*100)}%`} />
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${i==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Je.value="balanced",me.value=f}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${i==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Je.value="compact",me.value=f}}
          >
            집약
          </button>
          <${g} label=${ar(i)} />
        </div>
      </div>

      <div class="grid grid-cols-[minmax(0,1.35fr)_minmax(320px,0.65fr)] gap-4 mt-4">
        <div
          ref=${t}
          class="orchestra-canvas-wrap"
          onWheel=${L}
          onPointerDown=${E}
          onPointerMove=${c}
          onPointerUp=${S}
          onPointerCancel=${S}
          onPointerLeave=${()=>S()}
        >
          <svg
            class=${`orchestra-canvas block w-full h-auto min-h-[720px] ${vt.value?"is-dragging":""}`}
            viewBox=${`0 0 ${r.width} ${r.height}`}
            preserveAspectRatio="xMidYMid meet"
          >
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect
              data-orchestra-background="true"
              width=${r.width}
              height=${r.height}
              fill="url(#orchestra-grid)"
              class="orchestra-grid"
            ></rect>
            <g transform=${`translate(${C.panX} ${C.panY}) scale(${C.zoom})`}>
              <${Qn} edges=${e.edges} positions=${d} selectedId=${f} />
              <${Zn} signalNodes=${x} roomPoint=${p} onSelect=${w=>{me.value=w}} />
              <${er}
                orchestra=${e}
                positions=${d}
                density=${i}
                selectedId=${f}
                onSelect=${w=>{me.value=w}}
              />
            </g>
          </svg>
          <div class="absolute left-3.5 right-3.5 bottom-3 flex flex-wrap gap-2 pointer-events-none">
            <${g} label=${`세션 ${((B=e.summary)==null?void 0:B.session_count)??0}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${g} label=${`워커 ${((W=e.summary)==null?void 0:W.worker_count)??0}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${g} label=${`키퍼 ${((q=e.summary)==null?void 0:q.keeper_count)??0}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${g} label=${`신호 ${((X=e.summary)==null?void 0:X.signal_count)??e.signals.length}`} tone=${h(e.signals.some(w=>w.tone==="bad")?"bad":e.signals.length>0?"warn":"ok")} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
            <${g} label=${`갱신 ${T(e.generated_at)}`} class="pointer-events-auto bg-[rgba(15,23,42,0.8)]" />
          </div>
        </div>

        <${tr} orchestra=${e} />
      </div>
    </section>
  `}function Ce(e){if(!e)return 0;const t=Date.parse(e);return Number.isNaN(t)?0:t}function or(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function ir(e){const t=typeof e.timestamp=="string"?e.timestamp:typeof e.created_at=="string"?e.created_at:typeof e.at=="string"?e.at:null,a=typeof e.title=="string"?e.title:typeof e.kind=="string"?e.kind:typeof e.event=="string"?e.event:"세션 이벤트",n=typeof e.detail=="string"?e.detail:typeof e.summary=="string"?e.summary:xe(e);return{timestamp:t,title:a,detail:ne(n,220)}}function lr(e){var a;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"할당 없음",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}초`:e.heartbeat_fresh?"정상":"정보 없음",detail:[e.bound_task_status??null,e.detachment_member?"분견대 소속":null,e.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:t,note:((a=e.last_message)==null?void 0:a.content)??null}}function dr(e,t){const a=e.actor??e.spawn_role??`워커-${t+1}`,n=e.spawn_role??e.worker_class??e.spawn_agent??"워커",r=e.lane_id??e.capsule_mode??e.control_domain??"세션",o=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${a}:${t}`,name:a,role:n,lane:r,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"세션 레인",heartbeat:e.last_turn_ts_iso?T(e.last_turn_ts_iso):"정보 없음",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?je(e.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:e.routing_reason??null}}function cr(e){var t;return{key:`agent:${e.name}`,name:e.name,role:e.agent_type??"agent",source:"agent",status:K(e.status),tone:h(le(e.status)),task:e.current_task??"대기 중",signal:T(e.last_seen),detail:[e.model??null,((t=e.capabilities)==null?void 0:t.slice(0,2).join(", "))||null].filter(Boolean).join(" · ")||"글로벌 agent roster",chips:[e.context_ratio!=null?`ctx ${Math.round(e.context_ratio*100)}%`:"ctx n/a",e.status??"(unknown)"],note:e.personalityHint??null}}function pr(e){var a,n,r;const t=e.status==="offline"||e.status==="inactive"?"bad":e.status==="active"||e.status==="healthy"?"ok":"warn";return{key:`keeper:${e.name}`,name:e.name,role:e.runtime_class??"keeper",source:"keeper",status:K(e.status),tone:t,task:((a=e.active_goal_ids)==null?void 0:a[0])??e.last_proactive_reason??((n=e.agent)==null?void 0:n.current_task)??"standby",signal:e.last_heartbeat?T(e.last_heartbeat):or(e.last_turn_ago_s),detail:[e.autonomy_level??null,e.active_model??e.primary_model??e.model??null,e.keepalive_running?"keepalive on":null].filter(Boolean).join(" · ")||"글로벌 keeper roster",chips:[e.context_ratio!=null?`ctx ${Math.round(e.context_ratio*100)}%`:"ctx n/a",e.latest_tool_call_count!=null?`tools ${e.latest_tool_call_count}`:"tools n/a"],note:((r=e.diagnostic)==null?void 0:r.summary)??e.last_proactive_preview??e.recent_output_preview??null}}function ur(e){return{key:`resident:${e.keeper_name??"judge"}`,name:e.keeper_name??"resident-judge",role:"resident judge",source:"resident",status:dt(e),tone:Aa(e),task:e.judge_online?"live guidance":"standby",signal:e.generated_at?T(e.generated_at):"정보 없음",detail:[e.model_used??null,e.last_error?"error":null].filter(Boolean).join(" · ")||"resident runtime",chips:[e.enabled?"enabled":"disabled",e.judge_online?"online":"offline"],note:e.last_error??null}}function vr(e){return h(e.severity)}function mr({swarmMessages:e,traceEvents:t,chainOverlay:a,linkedAutoresearch:n,selectedSession:r,activeRecommendedActions:o,attentionItems:i}){const d=[];for(const l of e.slice(0,8))d.push({key:`message:${l.seq}`,title:l.from,detail:ne(l.content,280),meta:`메시지 · seq ${l.seq}`,source:"swarm",tone:"ok",timestamp:l.timestamp,sortTs:Ce(l.timestamp)});for(const l of t.slice(0,8))d.push({key:`trace:${l.event_id}`,title:l.event_type,detail:ne(xe(l.detail),280),meta:[l.actor??null,l.source??null].filter(Boolean).join(" · ")||"trace",source:"trace",tone:l.event_type.includes("error")||l.event_type.includes("fail")?"bad":"warn",timestamp:l.timestamp,sortTs:Ce(l.timestamp)});if(a!=null&&a.history&&d.push({key:`chain:${a.operation.operation_id}:${a.history.event}`,title:`Chain · ${a.history.event}`,detail:ne(lt(a.history),260),meta:a.history.chain_id??a.operation.operation_id,source:"chain",tone:a.history.event.includes("error")||a.history.event.includes("fail")?"bad":"warn",timestamp:a.history.timestamp,sortTs:Ce(a.history.timestamp)}),n){const l=[n.last_decision??null,n.target_file?`target ${n.target_file}`:null,n.error??null].filter(Boolean);d.push({key:`autoresearch:${n.loop_id??(r==null?void 0:r.session_id)??"session"}`,title:`Autoresearch · ${n.status??"unknown"}`,detail:ne(l.join(" · ")||"linked autoresearch context",260),meta:[n.loop_id?`loop ${n.loop_id}`:null,n.current_cycle!=null?`cycle ${n.current_cycle}`:null,n.best_score!=null?`best ${n.best_score}`:null].filter(Boolean).join(" · ")||"linked autoresearch",source:"autoresearch",tone:n.error?"bad":n.status==="running"?"warn":"ok",timestamp:null,sortTs:0})}for(const l of o.slice(0,4))d.push({key:`recommendation:${l.action_type}:${l.target_type}:${l.target_id??"session"}`,title:`${l.action_type} · ${l.target_type}`,detail:ne(l.reason,240),meta:l.target_id??"operator recommendation",source:"recommendation",tone:vr(l),timestamp:null,sortTs:0});for(const l of i.slice(0,4))d.push({key:`attention:${l.kind}:${l.target_id??"session"}`,title:`${l.kind} · ${l.target_type}`,detail:ne(l.summary,240),meta:l.target_id??"attention",source:"attention",tone:h(l.severity),timestamp:null,sortTs:0});for(const[l,p]of((r==null?void 0:r.recent_events)??[]).slice(0,4).entries()){const x=ir(p);d.push({key:`session:${(r==null?void 0:r.session_id)??"unknown"}:${l}`,title:x.title,detail:x.detail,meta:(r==null?void 0:r.session_id)??"session",source:"session",tone:"warn",timestamp:x.timestamp,sortTs:Ce(x.timestamp)})}return d.sort((l,p)=>p.sortTs-l.sortTs||l.title.localeCompare(p.title)).slice(0,14)}function ae({label:e,surface:t,params:a={}}){return s`
    <${z}
      variant="ghost"
      onClick=${()=>{if(t){te(t),ee("operations",{...be(t),...a});return}ee("operations",{section:"intervene"})}}
    >
      ${e}
    <//>
  `}function $r({chainOverlay:e,linkedAutoresearch:t}){var a,n,r,o;return!e&&!t?s`<div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`:s`
    <div class="grid grid-cols-1 gap-3">
      ${e?s`
            <article class="cmd-card rounded-xl cmd-orch-card min-h-[220px]">
              <div class="cmd-card rounded-xl-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="cmd-card rounded-xl-sub">${e.operation.operation_id}</div>
                </div>
                <${g} label=${K(e.operation.status)} tone=${h(le(e.operation.status))} />
              </div>
              <div class="cmd-card rounded-xl-grid">
                <span>Chain</span><span>${((a=e.runtime)==null?void 0:a.chain_id)??((n=e.preview_run)==null?void 0:n.chain_id)??"n/a"}</span>
                <span>Progress</span><span>${je((r=e.runtime)==null?void 0:r.progress)}</span>
                <span>Elapsed</span><span>${ke((o=e.runtime)==null?void 0:o.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${lt(e.history)}</span>
              </div>
              <div class="flex gap-3 flex-wrap mt-3">
                <${ae}
                  label="체인 상세"
                  surface="chains"
                  params=${{operation:e.operation.operation_id}}
                />
              </div>
            </article>
          `:null}
      ${t?s`
            <article class="cmd-card rounded-xl cmd-orch-card min-h-[220px]">
              <div class="cmd-card rounded-xl-head">
                <div>
                  <strong>Autoresearch Loop</strong>
                  <div class="cmd-card rounded-xl-sub">${t.loop_id??t.session_id??"linked session"}</div>
                </div>
                <${g} label=${t.status??"unknown"} tone=${t.error?"bad":t.status==="running"?"warn":"ok"} />
              </div>
              <div class="cmd-card rounded-xl-grid">
                <span>Cycle</span><span>${t.current_cycle??0}</span>
                <span>Best score</span><span>${t.best_score??"n/a"}</span>
                <span>Target</span><span>${t.target_file??"n/a"}</span>
                <span>Last decision</span><span>${t.last_decision??t.error??"기록 없음"}</span>
              </div>
              <div class="flex gap-3 flex-wrap mt-3">
                <${ae} label="세션 개입" />
                ${t.operation_id?s`<${ae}
                      label="작전 상세"
                      surface="operations"
                      params=${{operation_id:t.operation_id}}
                    />`:null}
              </div>
            </article>
          `:null}
    </div>
  `}function gr(){var e;document.fullscreenElement&&((e=document.exitFullscreen)==null||e.call(document)),te("warroom"),ee("operations",be("warroom"))}function xr({wallboard:e,stickyTone:t,heroTitle:a,heroSummary:n,swarmHasEvidence:r,swarm:o,selectedSession:i,activeLane:d,activeSummary:l,guidanceLayer:p,fullscreenActive:x,workerJoined:m,workerExpected:_,workerCardCount:f,blockersCount:y,pendingApprovals:v,pendingConfirmTotal:b,pendingConfirmVisible:$,pendingConfirmHidden:C,residentRuntime:u,latestSignal:L,latestMessage:E,latestTrace:c,chainOverlay:S,onRefresh:B,onToggleFullscreen:W}){var q,X,w,k,A,R,G,se,P,J,re;return s`
    <section class="sticky top-0 z-[3] flex flex-col gap-4 p-[18px] rounded-[18px] border border-[var(--white-8)] backdrop-blur-[18px] cmd-warroom-strip ${h(t)} ${e?"wallboard":""}">
      <div class="flex justify-between gap-4 items-start flex-wrap">
        <div>
          <span class="inline-flex w-fit items-center gap-2 py-[5px] px-[10px] rounded-full text-[#7dd3fc] bg-[rgba(14,116,144,0.22)] border border-solid border-[rgba(125,211,252,0.18)] text-[11px] tracking-[0.08em] uppercase">${e?"War Room Wallboard":"실시간 워룸"}</span>
          <strong>${a}</strong>
          <div class="cmd-card rounded-xl-sub">
            ${r?((q=o==null?void 0:o.operation)==null?void 0:q.operation_id)??"작전 정보 없음":"세션 기준값"}
            ${i!=null&&i.session_id?` · 세션 ${i.session_id}`:""}
            ${r&&((X=o==null?void 0:o.detachment)!=null&&X.detachment_id)?` · 분견대 ${o.detachment.detachment_id}`:""}
            ${d?` · 대표 레인 ${d.label}`:""}
          </div>
          <div class="mt-3 text-[rgba(226,232,240,0.86)] leading-[1.55] max-w-[82ch]">${n}</div>
          ${l!=null&&l.summary?s`<div class="grid gap-1 mt-3 py-3 px-3 rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] text-[rgba(255,255,255,0.84)] text-[13px] leading-snug cmd-warroom-guidance ${rt(p)}">
                <strong>${wt(p)}</strong>
                <span>${l.summary}</span>
              </div>`:null}
        </div>
        <div class="flex gap-3 flex-wrap items-start justify-end">
          <${z} variant="ghost" onClick=${B}>새로고침<//>
          ${e?s`
                <${z} variant="ghost" onClick=${W}>
                  ${x?"전체 화면 해제":"전체 화면"}
                </button>
                <${z} variant="ghost" onClick=${gr}>
                  표준 보기
                </button>
              `:null}
          <${ae}
            label="스웜 상세"
            surface="swarm"
            params=${{...r&&((w=o==null?void 0:o.operation)!=null&&w.operation_id)?{operation_id:o.operation.operation_id}:{},...r&&(o!=null&&o.run_id)?{run_id:o.run_id}:{}}}
          />
          ${S?s`<${ae}
                label="체인"
                surface="chains"
                params=${{operation:S.operation.operation_id}}
              />`:null}
          <${ae} label="개입" />
        </div>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-3">
        <${Y} label="워커" value=${`${m??0}/${_??0}`} detail=${`${r?((k=o==null?void 0:o.summary)==null?void 0:k.completed_workers)??0:0} 완료 · ${f} 카드`} />
        <${Y} label="런타임" value=${r?(A=o==null?void 0:o.provider)!=null&&A.runtime_blocker?"막힘":(R=o==null?void 0:o.provider)!=null&&R.provider_reachable?"준비됨":i?K(i.status):"확인 필요":i?K(i.status):"확인 필요"} detail=${r?`설정 ${((G=o==null?void 0:o.provider)==null?void 0:G.configured_capacity)??"n/a"} · 실제 ${((se=o==null?void 0:o.provider)==null?void 0:se.actual_slots)??((P=o==null?void 0:o.provider)==null?void 0:P.total_slots)??0} · hot ${((J=o==null?void 0:o.summary)==null?void 0:J.peak_hot_slots)??((re=o==null?void 0:o.provider)==null?void 0:re.peak_active_slots)??0}`:`세션 워커 ${f}`} />
        <${Y} label="압력" value=${y+v+b} detail=${`막힘 ${y} · 승인 ${v} · 확인 ${$}${C>0?`/${b}`:""}`} tone=${h(y>0||v>0||b>0?"warn":"ok")} />
        <${Y} label="상주 판정기" value=${dt(u)} detail=${`${yt(l)}${u!=null&&u.model_used?` · ${u.model_used}`:""}`} tone=${h(rt(p))} />
        <${Y} label="마지막 신호" value=${T(L)} detail=${E?"메시지":c?"트레이스":"대기 중"} />
      </div>
    </section>
  `}function br({item:e}){return s`
    <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${h(e.status)}">
      <div class="flex justify-between gap-3 items-start">
        <strong>${e.title}</strong>
        <${g} label=${e.status} tone=${h(e.status)} />
      </div>
      <p>${e.detail}</p>
      <div class="cmd-card rounded-xl-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function Ka({blocker:e}){return s`
    <article class="cmd-alert ${h(e.severity)} ${Ta(h(e.severity))}">
      <div class="cmd-card rounded-xl-head">
        <strong>${e.title}</strong>
        <${g} label=${e.severity} tone=${h(e.severity)} />
      </div>
      <div class="flex justify-between items-start">
        <span>${e.code}</span>
        <span>next ${e.next_tool}</span>
      </div>
      <p>${e.detail}</p>
    </article>
  `}function fr({worker:e}){return s`
    <article class="cmd-card rounded-xl p-3">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${e.name}</strong>
          <div class="cmd-card rounded-xl-sub">${e.role} · ${e.lane}</div>
        </div>
        <${g} label=${e.status} tone=${h(e.joined?e.heartbeat_fresh?"ok":"warn":"bad")} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>Joined</span><span>${e.joined?"yes":"no"}</span>
        <span>Live</span><span>${e.live_presence?"yes":"no"}</span>
        <span>Completed</span><span>${e.completed?"yes":"no"}</span>
        <span>Task</span><span>${e.current_task??e.bound_task_id??"none"}</span>
        <span>Task Title</span><span>${e.bound_task_title??"n/a"}</span>
        <span>Task Status</span><span>${e.bound_task_status??"n/a"}</span>
        <span>Heartbeat</span><span>${e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}s`:e.heartbeat_fresh?"completed-cleanly":"n/a"}</span>
        <span>Squad</span><span>${e.squad_member?"yes":"no"}</span>
        <span>Detachment</span><span>${e.detachment_member?"yes":"no"}</span>
      </div>
      <div class="cmd-tag rounded-full-row">
        <span class="cmd-tag rounded-full">${e.lane}</span>
        <span class="cmd-tag rounded-full ${e.current_task_matches_run?"ok":"warn"}">current_task</span>
        <span class="cmd-tag rounded-full ${e.claim_marker_seen?"ok":"warn"}">claim</span>
        <span class="cmd-tag rounded-full ${e.done_marker_seen?"ok":"warn"}">done</span>
        <span class="cmd-tag rounded-full ${e.final_marker_seen?"ok":"warn"}">final</span>
      </div>
      ${e.last_message?s`<div class="cmd-card rounded-xl-foot">${T(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function hr({total:e}){const a=Math.min(e,20),n=e>20?e-20:0,r=Array.from({length:a});return s`
    <div class="swarm-worker-grid flex flex-wrap gap-[3px] items-center">
      ${r.map(()=>s`<span class="w-2 h-2 rounded-full bg-[rgba(134,160,207,0.7)]"></span>`)}
      ${n>0?s`<span class="text-[11px] text-[var(--text-dim,var(--white-50))] ml-1">+${n}</span>`:null}
      <span class="text-[11px] text-[var(--text-dim,var(--white-50))] ml-1">(워커 ${e})</span>
    </div>
  `}function _r({event:e}){const t=e.timestamp?new Date(e.timestamp):null,a=t&&!isNaN(t.getTime())?t:null,n=a?`${String(a.getHours()).padStart(2,"0")}:${String(a.getMinutes()).padStart(2,"0")}`:"";return s`
    <div class="flex items-start gap-2 relative py-1 text-[0.82rem]">
      <span class="swarm-event-dot ${h(e.tone)}"></span>
      <span class="shrink-0 w-12 text-[11px] text-[var(--text-dim,var(--white-45))]">${n}</span>
      <div class="min-w-0 flex-1">
        <strong>${e.title}</strong>
        <span class="text-[11px] opacity-60 ml-1.5">${e.kind}</span>
        ${e.detail?s`<div class="cmd-card rounded-xl-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function wr({gap:e}){return s`
    <div class="flex items-center gap-1.5 py-[3px] text-[0.78rem]">
      <span class="swarm-gap-dot"></span>
      <${g} label=${`${e.code} (${e.count})`} tone=${h(e.severity)} />
      <span class="cmd-card rounded-xl-sub">${e.summary}</span>
    </div>
  `}function yr({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return s`
    <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${h(t)}">
        <div class="flex justify-between gap-3 items-start">
          <strong>Hot Proof / 가동 증거</strong>
          <${g} label=${(e==null?void 0:e.status)??"missing"} tone=${h(t)} />
        </div>
      ${e?s`
            <div class="cmd-card rounded-xl-grid">
              <span>소스</span><span>${e.source}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${T(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.artifact_ref?s`<div class="cmd-card rounded-xl-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?s`<p>${e.missing_reason}</p>`:null}
          `:s`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Ha(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function kr({lane:e}){const t=e.counts??{},a=Ha(e),n=t.workers??0,r=t.operations??0,o=t.detachments??0,i=r+o,d=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return s`
    <article class="swarm-lane-strip transition-colors duration-200 ${h(a)}">
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2 min-w-0">
          <span class="swarm-motion-dot inline-block rounded-full shrink-0 w-2.5 h-2.5 ${e.motion_state}"></span>
          <div>
            <span class="block mb-1 text-[rgba(125,211,252,0.78)] text-[10px] tracking-[0.1em] uppercase">${e.kind} · ${e.source_of_truth}</span>
            <strong class="text-[var(--text-near-white)] text-[16px] leading-[1.25]">${e.label}</strong>
          </div>
        </div>
        <div class="cmd-tag rounded-full-row">
          <${g} label=${e.phase} tone=${h(a)} />
          <${g} label=${e.motion_state} tone=${h(a)} />
          <${g} label=${T(e.last_movement_at)} />
        </div>
      </div>
      <p class="mt-3 mb-0 text-[var(--frost-72)] leading-[1.5]">${e.movement_reason}</p>
      <div class="swarm-lane-track rounded-full">
        <span class="${h(a)}" style=${`width:${d}%`}></span>
      </div>
      <div class="flex flex-col gap-1.5 mt-2 text-[0.82rem]">
        <div class="flex items-center gap-1.5 text-[var(--text-dim,var(--white-55))]">
          <span class="shrink-0 w-14 text-[11px] uppercase tracking-[0.04em] opacity-60">Step</span>
          <span>${e.current_step}</span>
        </div>
        ${n>0?s`
              <div class="flex items-center gap-1.5 text-[var(--text-dim,var(--white-55))]">
                <span class="shrink-0 w-14 text-[11px] uppercase tracking-[0.04em] opacity-60">워커</span>
                <${hr} total=${n} />
              </div>
            `:null}
        ${i>0?s`
              <div class="flex items-center gap-1.5 text-[var(--text-dim,var(--white-55))]">
                <span class="shrink-0 w-14 text-[11px] uppercase tracking-[0.04em] opacity-60">흐름</span>
                <div class="flex-1 h-1 rounded-sm overflow-hidden bg-[var(--white-8)]">
                  <div class="h-full rounded-sm bg-[var(--ok)] transition-[width] duration-300 ease-in-out" style="width: ${i>0?Math.round(r/i*100):0}%; background: var(--${a==="bad"?"bad":a==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="text-[11px] text-[var(--text-dim,var(--white-50))] ml-1">작전 ${r} · 실행체 ${o}</span>
              </div>
            `:null}
      </div>
      ${e.blockers.length>0?s`<div class="bg-[rgba(239,68,68,0.1)] border border-[rgba(239,68,68,0.25)] py-1.5 px-2.5 text-[0.78rem] text-[var(--bad)] mt-1 rounded-md">막힘: ${e.blockers.join(" · ")}</div>`:null}
      ${e.hard_flags.length>0?s`
            <div class="flex flex-wrap gap-1 mt-1">
              ${e.hard_flags.map(l=>s`<${g} label=${l.code} tone=${h(l.severity)} />`)}
            </div>
          `:null}
    </article>
  `}function Ga({lanes:e}){const t=e.slice(0,4);return t.length===0?null:s`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3 mb-4">
      ${t.map(a=>{const n=Ha(a),r=a.counts.workers??0,o=a.counts.operations??0,i=a.counts.detachments??0;return s`
          <article class="swarm-story-card rounded-xl ${h(n)}">
            <div class="swarm-story-topline flex justify-between gap-1.5 flex-wrap">
              <${g} label=${a.motion_state} tone=${h(n)} />
              <${g} label=${a.phase} />
            </div>
            <strong class="text-[var(--text-near-white)] text-lg leading-[1.3]">${a.label}</strong>
            <p class="m-0 text-[var(--frost-72)] leading-[1.5]">${a.current_step}</p>
            <div class="flex gap-2 flex-wrap">
              ${[`워커 ${r}`,`작전 ${o}`,`실행체 ${i}`].map(d=>s`
                <span class="inline-flex items-center py-1 px-2 bg-[var(--white-6)] text-[rgba(191,219,254,0.9)] text-[11px]">${d}</span>
              `)}
            </div>
            <small class="m-0 text-[var(--frost-72)] leading-[1.5]">${a.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function Ua({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const r of e){const o=r.motion_state;o in t?t[o]++:t.waiting++}if(e.length===0)return null;const n=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return s`
    <div>
      <div class="flex h-2 rounded overflow-hidden bg-[var(--white-6)] mt-3">
        ${n.filter(r=>r.count>0).map(r=>s`
          <div class="swarm-health-seg ${r.key}" style="flex: ${r.count}"></div>
        `)}
      </div>
      <div class="flex gap-4 text-[0.75rem] text-[var(--text-dim,var(--white-50))] mt-1.5">
        ${n.filter(r=>r.count>0).map(r=>s`
          <span class="flex items-center gap-1">
            <span class="w-2 h-2 rounded-sm inline-block" style="background: ${r.color}"></span>
            ${r.count} ${r.key}
          </span>
        `)}
      </div>
    </div>
  `}function Cr(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Sr(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function Mr(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function Ja({swarm:e}){var l;const t=e.run_id,a=e.resolution_recommendation,n=e.run_resolution;if(!t||!a&&!n)return null;const r=((l=pe.value)==null?void 0:l.pending_confirms.find(p=>p.target_type==="swarm_run"&&p.target_id===t))??null,o=Sr(a,n),i=!!(a&&(a.continue_available||a.rerun_available||a.abandon_available)),d=async p=>{if(!r)return;const x=Xe.value.trim()||"dashboard";await ha(x,r.confirm_token,p)};return s`
    <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${h(o)}">
      <div class="flex justify-between gap-3 items-start">
        <strong>Run Resolution</strong>
        <${g} label=${Mr((n==null?void 0:n.status)??(a==null?void 0:a.recommended_kind)??null)} tone=${h(o)} />
      </div>
      <p>
        ${(n==null?void 0:n.status)==="abandoned"?`이 run은 ${n.decided_by}가 ${T(n.decided_at)}에 soft abandon 처리했습니다. ${n.reason}`:(a==null?void 0:a.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="cmd-card rounded-xl-grid">
        <span>Run</span><span>${t}</span>
        <span>Provenance</span><span><${Ra} item=${{kind:(a==null?void 0:a.provenance)??"recorded"}} /></span>
        <span>Engine</span><span>${(a==null?void 0:a.decision_engine)??"operator_record"}</span>
        <span>Authoritative</span><span>${a!=null&&a.authoritative?"yes":"no"}</span>
      </div>
      ${a!=null&&a.evidence?s`
            <div class="cmd-tag rounded-full-row">
              <span class="cmd-tag rounded-full">joined ${a.evidence.joined_workers??0}</span>
              <span class="cmd-tag rounded-full">trace ${a.evidence.trace_events??0}</span>
              <span class="cmd-tag rounded-full">message ${a.evidence.message_events??0}</span>
              ${a.evidence.runtime_blocker?s`<span class="cmd-tag rounded-full ${h("bad")}">${a.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${r?s`
            <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card warn">
              <div class="flex justify-between gap-3 items-start">
                <strong>확인 대기</strong>
                <${g} label=${r.confirm_token} tone="warn" />
              </div>
              ${r.preview?s`<pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[13px] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${Cr(r.preview)}</pre>`:null}
              <div class="flex gap-3 flex-wrap mt-3">
                <${z} onClick=${()=>{d("confirm")}} disabled=${D.value}>확인 실행<//>
                <${z} variant="ghost" onClick=${()=>{d("deny")}} disabled=${D.value}>취소<//>
              </div>
            </div>
          `:i?s`
              <p>
                Run resolution은 현재 operator action surface에서 직접 실행되지 않습니다.
                이 카드는 recommendation과 recorded resolution만 보여줍니다.
              </p>
            `:null}
    </article>
  `}function Pr(){const e=ze(),t=qe(j.value),a=en(t),n=e==null?void 0:e.swarm_status,r=e==null?void 0:e.swarm_proof,o=(n==null?void 0:n.lanes.filter(m=>m.present))??[],i=(n==null?void 0:n.gaps.items)??[],d=(n==null?void 0:n.timeline.slice(0,8))??[],l=n==null?void 0:n.overview,p=n==null?void 0:n.recommended_next_action,x=o.length<=1;return s`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">스웜</div>
      </div>
      ${n?s`
            <${Ga} lanes=${o} />
            <div class="command-summary-grid mt-3">
              <${Y} label="활성 레인" value=${(l==null?void 0:l.active_lanes)??0} detail=${`${(l==null?void 0:l.moving_lanes)??0}개 이동 중`} />
              <${Y} label="정체" value=${(l==null?void 0:l.stalled_lanes)??0} detail=${`${(l==null?void 0:l.projected_lanes)??0}개 예상 레인`} />
              <${Y} label="마지막 이동" value=${T(l==null?void 0:l.last_movement_at)} detail=${n.generated_at?`스냅샷 ${T(n.generated_at)}`:"방금 스냅샷"} />
              <${Y} label="다음 액션" value=${(p==null?void 0:p.label)??"운영자 상태 확인"} detail=${(p==null?void 0:p.tool)??"masc_operator_snapshot"} />
            </div>

            ${o.length>0?s`<${Ua} lanes=${o} />`:null}

            <div class="${x?"grid grid-cols-[minmax(0,1fr)] gap-4 mt-4":"grid grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)] max-[1100px]:grid-cols-[minmax(0,1fr)] gap-4 mt-4"}">
              <div class="cmd-card rounded-xl-stack">
                ${o.length>0?o.map(m=>s`<${kr} lane=${m} />`):s`<${M} message="활성 스웜 레인이 없습니다." compact />`}
              </div>

              <div class="cmd-card rounded-xl-stack">
                <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card highlight ${a==="recommendation"?"shadow-[0_0_0_1px_rgba(34,211,238,0.16)]":""}">
                  <div class="flex justify-between gap-3 items-start">
                    <strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong>
                    <${g} label=${(p==null?void 0:p.lane_id)??"전체"} />
                  </div>
                  <p>${(p==null?void 0:p.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="cmd-card rounded-xl-foot">${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${yr} proof=${r} />

                <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${i.length>0?"warn":"ok"} ${a==="gaps"?"shadow-[0_0_0_1px_rgba(34,211,238,0.16)]":""}">
                  <div class="flex justify-between gap-3 items-start">
                    <strong>핵심 공백</strong>
                    <${g} label=${String(i.length)} tone=${h(i.some(m=>m.severity==="bad")?"bad":i.length>0?"warn":"ok")} />
                  </div>
                  ${i.length>0?s`<div class="border-l-2 border-[var(--card-border,var(--white-10))] pl-4 flex flex-col gap-0.5">${i.slice(0,4).map(m=>s`<${wr} gap=${m} />`)}</div>`:s`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card">
                  <div class="flex justify-between gap-3 items-start">
                    <strong>이동 타임라인</strong>
                    <${g} label=${String(d.length)} />
                  </div>
                  ${d.length>0?s`<div class="border-l-2 border-[var(--card-border,var(--white-10))] pl-4 flex flex-col gap-0.5">${d.map(m=>s`<${_r} event=${m} />`)}</div>`:s`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:s`<${M} message="스웜 상태를 아직 불러오지 못했습니다." compact />`}
    </section>
  `}function Za(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function Qa(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function jr(e){switch(e){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function Rr(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function es({node:e,depth:t=0}){const a=e.roster_live??0,n=e.roster_total??e.unit.roster.length,r=e.active_operation_count??0,o=e.unit.policy,i=e.unit.source??"unknown",d=r>0?`${r}개 작전 연결`:"실행 연결 없음";return s`
    <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-tree-node depth-${Math.min(t,3)} ${t<=2?"border-[rgba(248,113,113,0.3)]":""}">
      <div class="flex justify-between items-start">
        <div>
          <div class="flex justify-between items-start flex-wrap gap-2">
            <strong>${e.unit.label}</strong>
            <${g} label=${tn(e.unit.kind)} />
            <${g} label=${e.health??"ok"} tone=${h(e.health)} />
            <${g} label=${Za(i)} tone=${Qa(i)} />
            <${g} label=${d} tone=${r>0?"ok":"warn"} />
            ${o!=null&&o.frozen?s`<${g} label="동결됨" tone="warn" />`:null}
            ${o!=null&&o.kill_switch?s`<${g} label="킬 스위치" tone="bad" />`:null}
          </div>
          <div class="flex gap-2 flex-wrap mt-2 text-[var(--white-56)] text-[13px]">
            <span>ID ${e.unit.unit_id}</span>
            <span>리더 ${e.unit.leader_id??"미지정"} / ${e.leader_status??"확인 필요"}</span>
            <span>편성 ${a}/${n}</span>
            <span>작전 ${r}</span>
            <span>자율성 ${(o==null?void 0:o.autonomy_level)??"정보 없음"}</span>
          </div>
          <div class="cmd-card rounded-xl-sub">${Rr(e)}</div>
          ${e.reasons&&e.reasons.length>0?s`<div class="cmd-tag rounded-full-row">
                ${e.reasons.map(l=>s`<span class="cmd-tag rounded-full warn">${l}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?s`<div class="flex flex-col gap-3 mt-3 pl-4 border-l border-[var(--white-8)]">
            ${e.children.map(l=>s`<${es} node=${l} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function Tr({alert:e}){return s`
    <article class="cmd-alert ${h(e.severity)} ${Ta(h(e.severity))}">
      <div class="cmd-card rounded-xl-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <${g} label=${e.severity??"warn"} tone=${h(e.severity)} />
      </div>
      <div class="flex justify-between items-start">
        <span>${e.scope_type??"범위"}:${e.scope_id??"정보 없음"}</span>
        <span>${T(e.timestamp)}</span>
      </div>
      ${e.detail?s`<p>${e.detail}</p>`:null}
    </article>
  `}function Ct({event:e}){return s`
    <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-4">
      <div class="min-w-0 [overflow-wrap:anywhere] break-words">
        <div class="flex justify-between items-start">
          <strong>${e.event_type}</strong>
          <${g} label=${e.source??"control_plane"} />
          <${g} label=${T(e.timestamp)} />
        </div>
        <div class="cmd-card rounded-xl-sub">
          ${e.operation_id??e.trace_id}
          ${e.unit_id?` · ${e.unit_id}`:""}
          ${e.actor?` · ${e.actor}`:""}
        </div>
      </div>
      <pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[13px] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${xe(e.detail)}</pre>
    </article>
  `}function Ir(){const e=_e.value,t=e==null?void 0:e.topology,a=t==null?void 0:t.source,n=t==null?void 0:t.summary,r=(n==null?void 0:n.managed_unit_count)??0,o=(n==null?void 0:n.active_operation_count)??0;return s`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">지휘 계층</div>
      </div>
      ${e?s`
            <div class="mb-4 p-4 bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl">
              <div class="flex justify-between items-start flex-wrap gap-2">
                <${g} label=${Za(a)} tone=${Qa(a)} />
                <${g} label=${`관리 유닛 ${r}`} />
                <${g} label=${`활성 작전 ${o}`} tone=${o>0?"ok":"warn"} />
              </div>
              <p>${jr(a)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?s`${e.topology.units.map(i=>s`<${es} node=${i} />`)}`:s`<${M} message="지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다." compact />`}
    </section>
  `}function Er(){const e=_e.value;return s`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">경보</div>
      </div>
      ${e&&e.alerts.alerts.length>0?s`<div class="cmd-card rounded-xl-stack">
            ${e.alerts.alerts.map(t=>s`<${Tr} alert=${t} />`)}
          </div>`:s`<${M} message="지금 올라온 지휘면 경보는 없습니다." compact />`}
    </section>
  `}function Lr(){const e=_e.value;return s`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">최근 트레이스</div>
      </div>
      ${e&&e.traces.events.length>0?s`<div class="flex flex-col gap-3">
            ${e.traces.events.map(t=>s`<${Ct} event=${t} />`)}
          </div>`:s`<${M} message="최근 트레이스 이벤트가 없습니다." compact />`}
    </section>
  `}function Ar(){var l,p,x,m,_,f,y,v,b,$,C,u,L,E,c,S,B,W,q,X,w;const e=Ma.value,t=an(),a=sn(),n=(l=e==null?void 0:e.provider)!=null&&l.runtime_blocker?"blocked":(p=e==null?void 0:e.provider)!=null&&p.provider_reachable?"ready":"check",r=((x=e==null?void 0:e.provider)==null?void 0:x.actual_slots)??((m=e==null?void 0:e.provider)==null?void 0:m.total_slots)??0,o=((_=e==null?void 0:e.provider)==null?void 0:_.expected_slots)??"n/a",i=((f=e==null?void 0:e.provider)==null?void 0:f.actual_ctx)??((y=e==null?void 0:e.provider)==null?void 0:y.ctx_per_slot)??0,d=((v=e==null?void 0:e.provider)==null?void 0:v.expected_ctx)??"n/a";return s`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">스웜 라이브 런</div>
        </div>
        ${Pa.value?s`<${M} message="Loading swarm live state…" compact />`:aa.value?s`<${M} message=${aa.value} compact />`:e?s`
                  <div class="cmd-tag rounded-full-row">
                    <span class="cmd-tag rounded-full">experimental</span>
                    <${Ra} item=${{kind:"derived",label:"derived read-model"}} />
                    <span class="cmd-tag rounded-full ${e.run_resolution||e.resolution_recommendation?"warn":"ok"}">
                      ${e.run_resolution||e.resolution_recommendation?"operator resolution aware":"no resolution advice"}
                    </span>
                  </div>
                  <div class="cmd-card rounded-xl-sub">
                    이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                  </div>
                  <div class="command-summary-grid">
                    <${Y} label="실행 런" value=${e.run_id??t??"swarm-live"} detail=${e.room_id??"room 정보 없음"} />
                    <${Y} label="워커" value=${`${((b=e.summary)==null?void 0:b.joined_workers)??0}/${(($=e.summary)==null?void 0:$.expected_workers)??0}`} detail=${`${((C=e.summary)==null?void 0:C.live_workers)??0}개 가동 · ${((u=e.summary)==null?void 0:u.completed_workers)??0}개 완료`} />
                    <${Y} label="런타임" value=${n} detail=${`slots ${r}/${o} · ctx ${i}/${d}`} />
                    <${Y} label="고동시성" value=${(L=e.summary)!=null&&L.pass_hot_concurrency?"통과":"확인 필요"} detail=${((E=e.provider)==null?void 0:E.slot_url)??"slot 정보 없음"} />
                    <${Y} label="종단 점검" value=${(c=e.summary)!=null&&c.pass_end_to_end?"통과":"확인 필요"} detail=${e.recommended_next_tool??"masc_observe_traces"} />
                  </div>
                  <div class="cmd-card rounded-xl-grid">
                    <span>작전</span><span>${((S=e.operation)==null?void 0:S.operation_id)??a??"없음"}</span>
                    <span>분대</span><span>${((B=e.squad)==null?void 0:B.label)??"없음"}</span>
                    <span>실행체</span><span>${((W=e.detachment)==null?void 0:W.detachment_id)??"없음"}</span>
                    <span>예상 워커</span><span>${((q=e.summary)==null?void 0:q.expected_workers)??0}명</span>
                    <span>최종 마커</span><span>${((X=e.summary)==null?void 0:X.final_markers_seen)??0}</span>
                    <span>런타임 막힘</span><span>${((w=e.provider)==null?void 0:w.runtime_blocker)??"없음"}</span>
                    <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                  </div>
                  ${e.truth_notes.length>0?s`<div class="cmd-tag rounded-full-row">
                        ${e.truth_notes.map(k=>s`<span class="cmd-tag rounded-full">${k}</span>`)}
                      </div>`:null}
                  <${Ja} swarm=${e} />
                `:s`<${M} message="스웜 read-model이 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">체크리스트</div>
        </div>
        ${e&&e.checklist.length>0?s`<div class="cmd-card rounded-xl-stack">
              ${e.checklist.map(k=>s`<${br} item=${k} />`)}
            </div>`:s`<${M} message="체크리스트가 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">워커</div>
        </div>
        ${e&&e.workers.length>0?s`<div class="cmd-card rounded-xl-stack">
              ${e.workers.map(k=>s`<${fr} worker=${k} />`)}
            </div>`:s`<${M} message="워커 행이 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">런타임</div>
        </div>
        ${e!=null&&e.provider?s`
              <div class="cmd-card rounded-xl-grid">
                <span>Provider</span><span>${e.provider.provider_base_url??"n/a"}</span>
                <span>Provider Reachable</span><span>${e.provider.provider_reachable==null?"n/a":e.provider.provider_reachable?"yes":"no"}</span>
                <span>Requested Model</span><span>${e.provider.provider_model_id??"n/a"}</span>
                <span>Actual Model</span><span>${e.provider.actual_model_id??"n/a"}</span>
                <span>Slot URL</span><span>${e.provider.slot_url??"n/a"}</span>
                <span>Expected Slots</span><span>${e.provider.expected_slots??"n/a"}</span>
                <span>Actual Slots</span><span>${e.provider.actual_slots??e.provider.total_slots??0}</span>
                <span>Expected Ctx</span><span>${e.provider.expected_ctx??"n/a"}</span>
                <span>Actual Ctx</span><span>${e.provider.actual_ctx??e.provider.ctx_per_slot??0}</span>
                <span>Active Now</span><span>${e.provider.active_slots_now??0}</span>
                <span>Peak Active</span><span>${e.provider.peak_active_slots??0}</span>
                <span>Sample Count</span><span>${e.provider.sample_count??0}</span>
                <span>Last Sample</span><span>${e.provider.last_sample_at?T(e.provider.last_sample_at):"n/a"}</span>
                <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"none"}</span>
                <span>Doctor Checked</span><span>${e.provider.checked_at?T(e.provider.checked_at):"n/a"}</span>
              </div>
              ${e.provider.detail?s`<div class="cmd-card rounded-xl-sub">${e.provider.detail}</div>`:null}
              ${e.provider.timeline.length>0?s`<div class="flex flex-col gap-3">
                    ${e.provider.timeline.slice(-12).map(k=>s`
                      <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-4">
                        <div class="min-w-0 [overflow-wrap:anywhere] break-words">
                          <div class="flex justify-between items-start">
                            <strong>${k.active_slots} active</strong>
                            <${g} label=${T(k.timestamp)} />
                          </div>
                          <div class="cmd-card rounded-xl-sub">slots ${k.active_slot_ids.join(", ")||"none"}</div>
                        </div>
                      </article>
                    `)}
                  </div>`:s`<${M} message="slot telemetry가 아직 없습니다." compact />`}
            `:s`<${M} message="런타임 telemetry가 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">막힘 요인</div>
        </div>
        ${e&&e.blockers.length>0?s`<div class="cmd-card rounded-xl-stack">
              ${e.blockers.map(k=>s`<${Ka} blocker=${k} />`)}
            </div>`:s`<${M} message=${`막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.`} compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">최근 메시지</div>
        </div>
        ${e&&e.recent_messages.length>0?s`<div class="flex flex-col gap-3">
              ${e.recent_messages.map(k=>s`
                <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-4">
                  <div class="min-w-0 [overflow-wrap:anywhere] break-words">
                    <div class="flex justify-between items-start">
                      <strong>${k.from}</strong>
                      <${g} label=${T(k.timestamp)} />
                    </div>
                    <div class="cmd-card rounded-xl-sub">seq ${k.seq}</div>
                  </div>
                  <pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[13px] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${Wa(k.content)}</pre>
                </article>
              `)}
            </div>`:s`<${M} message="run 범위 메시지가 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">최근 트레이스 이벤트</div>
        </div>
        ${e&&e.recent_trace_events.length>0?s`<div class="flex flex-col gap-3">
              ${e.recent_trace_events.map(k=>s`<${Ct} event=${k} />`)}
            </div>`:s`<${M} message="run 범위 trace event가 아직 없습니다." compact />`}
      </section>
    </div>
  `}function Nr(){return s`
    <div class="flex flex-col gap-4">
      <${Pr} />
      <${Ar} />
    </div>
  `}function Br(e){return e==="swarm"?"스웜 실시간":"세션 요약"}function Yr(e){switch(e){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return e.startsWith("empty:")?`빈 노트 ${e.slice(6)}회`:e.startsWith("turns:")?`턴 ${e.slice(6)}회`:e}}function Fr({worker:e}){return s`
    <article class="cmd-card rounded-xl p-3 warroom-worker-card ${h(le(e.status))}">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${e.name}</strong>
          <div class="cmd-card rounded-xl-sub">${e.role} · ${e.lane}</div>
        </div>
        <${g} label=${K(e.status)} tone=${h(le(e.status))} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>출처</span><span>${Br(e.source)}</span>
        <span>과업</span><span>${e.task}</span>
        <span>최근 신호</span><span>${e.heartbeat}</span>
        <span>근거</span><span>${e.detail}</span>
      </div>
      <div class="cmd-tag rounded-full-row mt-3">
        ${e.markers.map(t=>s`<span class="cmd-tag rounded-full">${Yr(t)}</span>`)}
      </div>
      ${e.note?s`<div class="cmd-card rounded-xl-foot">${ne(e.note,220)}</div>`:null}
    </article>
  `}function ba({item:e}){return s`
    <article class="cmd-card rounded-xl p-3 cmd-presence-card ${Ea(e.tone)}">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${e.name}</strong>
          <div class="cmd-card rounded-xl-sub">${e.role} · ${e.source}</div>
        </div>
        <${g} label=${e.status} tone=${e.tone} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>현재 과업</span><span>${e.task}</span>
        <span>최근 신호</span><span>${e.signal}</span>
        <span>근거</span><span>${e.detail}</span>
      </div>
      <div class="cmd-tag rounded-full-row">
        ${e.chips.map(t=>s`<span class="cmd-tag rounded-full">${t}</span>`)}
      </div>
      ${e.note?s`<div class="cmd-card rounded-xl-foot">${ne(e.note,200)}</div>`:null}
    </article>
  `}function Or({item:e}){return s`
    <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-4 cmd-feed-card rounded-xl ${Ea(e.tone)}">
      <div class="min-w-0 [overflow-wrap:anywhere] break-words">
        <div class="flex justify-between items-start">
          <strong>${e.title}</strong>
          <${g} label=${e.timestamp?T(e.timestamp):e.source} tone=${e.tone} />
        </div>
        <div class="cmd-card rounded-xl-sub">${e.meta}</div>
      </div>
      <div class="text-[rgba(226,232,240,0.86)] leading-[1.55] whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${e.detail}</div>
    </article>
  `}function Wr({wallboard:e,liveLanes:t,selectedSession:a,chainOverlay:n,linkedAutoresearch:r,workers:o,feedItems:i,swarm:d,agentViews:l,keeperViews:p,swarmHasEvidence:x,blockers:m,pendingApprovals:_,pendingConfirmTotal:f,pendingConfirmVisible:y,pendingConfirmHidden:v,pendingConfirms:b,activeLane:$}){return s`
    <div class="grid gap-4 items-start cmd-warroom-grid ${e?"wallboard":""}">
      <div class="flex flex-col gap-4 min-w-0">
        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">실행 흐름</div>
          </div>
          ${t.length>0?s`
                <${Ga} lanes=${t} />
                <${Ua} lanes=${t} />
              `:a?s`
                  <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card">
                    <div class="flex justify-between gap-3 items-start">
                      <strong>${a.session_id}</strong>
                      <${g} label=${K(a.status)} tone=${h(le(a.status))} />
                    </div>
                    <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                    <div class="cmd-card rounded-xl-grid">
                      <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                      <span>경과</span><span>${ke(a.elapsed_sec)}</span>
                      <span>남은 시간</span><span>${ke(a.remaining_sec)}</span>
                    </div>
                  </article>
                `:s`<${M} message="보이는 레인이 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">오케스트레이션</div>
          </div>
          <${$r} chainOverlay=${n} linkedAutoresearch=${r} />
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">워커 현황</div>
          </div>
          ${o.length>0?s`<div class="cmd-card rounded-xl-stack">
                ${o.map(C=>s`<${Fr} worker=${C} />`)}
              </div>`:s`<${M} message="활성 워커 카드가 아직 없습니다." compact />`}
        </section>
      </div>

      <div class="flex flex-col gap-4 min-w-0">
        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">상황 피드</div>
          </div>
          ${i.length>0?s`<div class="flex flex-col gap-3">
                ${i.map(C=>s`<${Or} item=${C} />`)}
              </div>`:s`<${M} message="메시지, chain, autoresearch, attention feed가 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">트레이스 흐름</div>
          </div>
          ${d&&d.recent_trace_events.length>0?s`<div class="flex flex-col gap-3">
                ${d.recent_trace_events.map(C=>s`<${Ct} event=${C} />`)}
              </div>`:s`<${M} message="실행 범위 트레이스 이벤트가 아직 없습니다." compact />`}
        </section>
      </div>

      <div class="flex flex-col gap-4 min-w-0">
        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">Agents</div>
          </div>
          ${l.length>0?s`<div class="grid grid-cols-1 gap-3">
                ${l.map(C=>s`<${ba} item=${C} />`)}
              </div>`:s`<${M} message="가시적인 active agent가 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">Keepers</div>
          </div>
          ${p.length>0?s`<div class="grid grid-cols-1 gap-3">
                ${p.map(C=>s`<${ba} item=${C} />`)}
              </div>`:s`<${M} message="가시적인 keeper/runtime 카드가 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">압력</div>
          </div>
          <div class="cmd-card rounded-xl-stack">
            ${x&&d?s`<${Ja} swarm=${d} />`:null}
            ${m.length>0?m.map(C=>s`<${Ka} blocker=${C} />`):s`<div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
            ${_>0?s`
                  <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card warn">
                    <div class="flex justify-between gap-3 items-start">
                      <strong>승인 대기</strong>
                      <${g} label=${String(_)} tone="warn" />
                    </div>
                    <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                  </article>
                `:null}
            ${f>0?s`
                  <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card warn">
                    <div class="flex justify-between gap-3 items-start">
                      <strong>확인 대기</strong>
                      <${g} label=${String(v>0?`${y}/${f}`:f)} tone="warn" />
                    </div>
                    <p>
                      운영자 미리보기가 사람 확인을 기다리고 있습니다.
                      ${v>0?` 현재 actor 기준으로는 ${y}건만 보입니다.`:""}
                    </p>
                    <div class="cmd-tag rounded-full-row">
                      ${b.slice(0,3).map(C=>s`<span class="cmd-tag rounded-full">${C.confirm_token}</span>`)}
                    </div>
                  </article>
                `:null}
            ${$?s`
                  <article class="cmd-card rounded-xl p-3">
                    <div class="cmd-card rounded-xl-head">
                      <div>
                        <strong>${$.label}</strong>
                        <div class="cmd-card rounded-xl-sub">${$.kind} · ${$.phase}</div>
                      </div>
                      <${g} label=${K($.motion_state)} tone=${h(le($.motion_state))} />
                    </div>
                    <div class="cmd-card rounded-xl-grid">
                      <span>현재 단계</span><span>${$.current_step}</span>
                      <span>이동 사유</span><span>${$.movement_reason}</span>
                      <span>막힘 수</span><span>${$.blockers.length}</span>
                      <span>최근 이동</span><span>${T($.last_movement_at)}</span>
                    </div>
                  </article>
                `:null}
            ${x&&(d!=null&&d.detachment)?s`
                  <article class="cmd-card rounded-xl p-3">
                    <div class="cmd-card rounded-xl-head">
                      <div>
                        <strong>${d.detachment.detachment_id}</strong>
                        <div class="cmd-card rounded-xl-sub">${d.detachment.assigned_unit_id}</div>
                      </div>
                      <${g} label=${K(d.detachment.status??"active")} tone=${h(le(d.detachment.status))} />
                    </div>
                    <div class="cmd-card rounded-xl-grid">
                      <span>리더</span><span>${d.detachment.leader_id??"미지정"}</span>
                      <span>편성</span><span>${d.detachment.roster.length}</span>
                      <span>세션</span><span>${d.detachment.session_id??"연결 없음"}</span>
                      <span>하트비트</span><span>${Ia(d.detachment.heartbeat_deadline)}</span>
                    </div>
                  </article>
                `:a?s`
                    <article class="cmd-card rounded-xl p-3">
                      <div class="cmd-card rounded-xl-head">
                        <div>
                          <strong>${a.session_id}</strong>
                          <div class="cmd-card rounded-xl-sub">현재 세션 기준</div>
                        </div>
                        <${g} label=${K(a.status)} tone=${h(le(a.status))} />
                      </div>
                      <div class="cmd-card rounded-xl-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${ke(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${ke(a.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
          </div>
        </section>
      </div>
    </div>
  `}function qr({wallboard:e=!1}){var Mt,Pt,jt,Rt,Tt,It,Et,Lt,At,Nt,Bt,Yt,Ft,Ot,Wt,qt,zt,Xt,Dt,Vt,Kt;const t=ze(),a=Ma.value,n=pe.value,r=wa.value,o=nn(),i=a!=null&&a.operation?((Mt=bt.value)==null?void 0:Mt.operations.find(I=>{var ue;return I.operation.operation_id===((ue=a.operation)==null?void 0:ue.operation_id)}))??null:null,d=(o==null?void 0:o.linked_autoresearch)??null,l=rn(),p=(a==null?void 0:a.workers)??[],x=(r==null?void 0:r.worker_cards)??[],m=l&&p.length>0?p.map(lr):x.map(dr),_=Sa.value.filter(I=>I.status==="active"||I.status==="busy"||I.status==="listening"||I.status==="idle"),f=Ms.value.filter(I=>I.status!=="offline"||I.keepalive_running||I.last_heartbeat).sort((I,ue)=>Ce(ue.last_heartbeat)-Ce(I.last_heartbeat)),y=l,v=((Pt=t==null?void 0:t.decisions.summary)==null?void 0:Pt.pending)??0,b=xt(n),$=b.items,C=b.total_count,u=b.visible_count,L=b.hidden_count,E=l?(a==null?void 0:a.blockers)??[]:[],c=(r==null?void 0:r.recommended_actions)??[],S=(jt=r==null?void 0:r.active_recommended_actions)!=null&&jt.length?r.active_recommended_actions:c,B=r==null?void 0:r.active_summary,W=(r==null?void 0:r.active_guidance_layer)??"fallback",q=(r==null?void 0:r.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),X=(r==null?void 0:r.attention_items)??[],w=((Rt=a==null?void 0:a.recent_messages[0])==null?void 0:Rt.timestamp)??null,k=((Tt=a==null?void 0:a.recent_trace_events[0])==null?void 0:Tt.timestamp)??null,A=l?w??k??null:null,R=o==null?void 0:o.summary,G=(l?(It=a==null?void 0:a.summary)==null?void 0:It.expected_workers:void 0)??(typeof(R==null?void 0:R.planned_worker_count)=="number"?R.planned_worker_count:void 0)??(r==null?void 0:r.worker_cards.length)??0,se=(l?(Et=a==null?void 0:a.summary)==null?void 0:Et.joined_workers:void 0)??(typeof(R==null?void 0:R.active_agent_count)=="number"?R.active_agent_count:void 0)??m.length,P=E.length>0||v>0||C>0?"warn":y||o?"ok":"warn",J=l?((Lt=t==null?void 0:t.swarm_status)==null?void 0:Lt.lanes.filter(I=>I.present))??[]:[],re=((Nt=(At=t==null?void 0:t.swarm_status)==null?void 0:At.narrative)==null?void 0:Nt.lane_id)??((Yt=(Bt=t==null?void 0:t.swarm_status)==null?void 0:Bt.recommended_next_action)==null?void 0:Yt.lane_id)??((Ft=J[0])==null?void 0:Ft.lane_id)??null,Re=re?J.find(I=>I.lane_id===re)??null:J[0]??null,St=[...q?[ur(q)]:[],..._.slice(0,e?8:5).map(cr),...f.slice(0,e?8:5).map(pr)],ts=St.filter(I=>I.source==="agent"),as=St.filter(I=>I.source==="keeper"||I.source==="resident"),ss=mr({swarmMessages:(a==null?void 0:a.recent_messages)??[],traceEvents:(a==null?void 0:a.recent_trace_events)??[],chainOverlay:i,linkedAutoresearch:d,selectedSession:o,activeRecommendedActions:S,attentionItems:X}),ns=((Ot=a==null?void 0:a.operation)==null?void 0:Ot.objective)??((qt=(Wt=t==null?void 0:t.swarm_status)==null?void 0:Wt.narrative)==null?void 0:qt.active_work)??(o==null?void 0:o.session_id)??"가동 중인 워룸",rs=[(B==null?void 0:B.summary)??null,((Xt=(zt=t==null?void 0:t.swarm_status)==null?void 0:zt.narrative)==null?void 0:Xt.state)??null,((Vt=(Dt=t==null?void 0:t.swarm_status)==null?void 0:Dt.narrative)==null?void 0:Vt.active_work)??null,Re?`${Re.label} · ${Re.current_step}`:null].filter(Boolean).join(" · ")||"실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.",[os,is]=ht(typeof document<"u"&&!!document.fullscreenElement);H(()=>{ie()},[]),H(()=>{o!=null&&o.session_id&&Le(o.session_id)},[o==null?void 0:o.session_id,n,(Kt=a==null?void 0:a.detachment)==null?void 0:Kt.session_id]),H(()=>{if(!e)return;const I=()=>{is(!!document.fullscreenElement)};return document.addEventListener("fullscreenchange",I),I(),()=>{document.removeEventListener("fullscreenchange",I)}},[e]);const ls=()=>{var I,ue,Ht;if(!(typeof document>"u")){if(document.fullscreenElement){(I=document.exitFullscreen)==null||I.call(document);return}(Ht=(ue=document.documentElement).requestFullscreen)==null||Ht.call(ue)}},ds=()=>{ie(),ye(),et(),o!=null&&o.session_id&&Le(o.session_id)};return!y&&!o?Pa.value||mt.value?s`<${M} message="실시간 워룸 불러오는 중…" compact />`:s`
      <section class="card rounded-xl ${e?"min-h-[calc(100vh-180px)]":"min-h-[360px]"} flex flex-col justify-center gap-[18px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">실시간 워룸</div>
        </div>
        <div class="flex flex-col gap-3 max-w-[520px]">
          <span class="inline-flex w-fit items-center gap-2 py-[5px] px-[10px] rounded-full text-[#7dd3fc] bg-[rgba(14,116,144,0.22)] border border-solid border-[rgba(125,211,252,0.18)] text-[11px] tracking-[0.08em] uppercase">Narrative Playback</span>
          <strong>지금 붙잡을 live swarm 또는 team session이 없습니다</strong>
          <p>chain, autoresearch, worker wallboard는 활성 작전 또는 세션이 생기면 자동으로 붙습니다. 지금은 drill-down surface로 이동하는 편이 맞습니다.</p>
        </div>
        <div class="flex gap-3 flex-wrap mt-3">
          <${ae} label="작전 보기" surface="operations" />
          <${ae} label="스웜 보기" surface="swarm" />
          <${ae} label="체인 보기" surface="chains" />
          <${ae} label="개입 열기" />
        </div>
      </section>
    `:s`
    <div class="flex flex-col ${e?"gap-5":"gap-4"}">
      <${xr}
        wallboard=${e}
        stickyTone=${P}
        heroTitle=${ns}
        heroSummary=${rs}
        swarmHasEvidence=${l}
        swarm=${a}
        selectedSession=${o}
        activeLane=${Re}
        activeSummary=${B}
        guidanceLayer=${W}
        fullscreenActive=${os}
        workerJoined=${se}
        workerExpected=${G}
        workerCardCount=${m.length}
        blockersCount=${E.length}
        pendingApprovals=${v}
        pendingConfirmTotal=${C}
        pendingConfirmVisible=${u}
        pendingConfirmHidden=${L}
        residentRuntime=${q}
        latestSignal=${A}
        latestMessage=${w}
        latestTrace=${k}
        chainOverlay=${i}
        onRefresh=${ds}
        onToggleFullscreen=${ls}
      />
      <${Wr}
        wallboard=${e}
        liveLanes=${J}
        selectedSession=${o}
        chainOverlay=${i}
        linkedAutoresearch=${d}
        workers=${m}
        feedItems=${ss}
        swarm=${a}
        agentViews=${ts}
        keeperViews=${as}
        swarmHasEvidence=${l}
        blockers=${E}
        pendingApprovals=${v}
        pendingConfirmTotal=${C}
        pendingConfirmVisible=${u}
        pendingConfirmHidden=${L}
        pendingConfirms=${$}
        activeLane=${Re}
      />
    </div>
  `}function fa(e){switch((e??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(e==null?void 0:e.trim())||"확인 필요"}}function zr({source:e}){const t=Ie(null),[a,n]=ht(null);return H(()=>{let r=!1;const o=t.current;return o?(o.textContent="",n(null),(async()=>{try{const d=await on(),{svg:l}=await d.render(`command-chain-${ln()}`,e);if(r||!t.current)return;const m=new DOMParser().parseFromString(l,"image/svg+xml").documentElement;m instanceof SVGElement&&(t.current.textContent="",t.current.appendChild(m))}catch(d){if(r)return;n(d instanceof Error?d.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{r=!0,t.current&&(t.current.textContent="")}):void 0},[e]),s`
    <div class="mt-3 min-h-[160px]">
      ${a?s`<${M} message=${a} compact />`:null}
      <div class="overflow-auto rounded-[10px] p-3 bg-[rgba(9,12,20,0.7)] cmd-chain-graph" ref=${t}></div>
    </div>
  `}function Xr({overlay:e,selected:t,onSelect:a}){const n=e.operation.chain,r=e.runtime;return s`
    <button class="w-full text-left text-inherit font-[inherit] cursor-pointer bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-chain-item ${t?"selected":""}" onClick=${a}>
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="cmd-card rounded-xl-sub">${e.operation.operation_id}</div>
        </div>
        <${g} label=${(n==null?void 0:n.status)??e.operation.status} tone=${ce(n==null?void 0:n.status)} />
      </div>
      <div class="cmd-tag rounded-full-row">
        <span class="cmd-tag rounded-full">${(n==null?void 0:n.kind)??"chain_dsl"}</span>
        ${n!=null&&n.chain_id?s`<span class="cmd-tag rounded-full">${n.chain_id}</span>`:null}
        ${r?s`<span class="cmd-tag rounded-full ${ce(n==null?void 0:n.status)}">${je(r.progress)} progress</span>`:null}
      </div>
      <div class="cmd-card rounded-xl-sub">${lt(e.history)}</div>
    </button>
  `}function Dr({item:e}){return s`
    <article class="cmd-chain-history-row text-red-300">
      <div class="flex justify-between gap-3 items-start">
        <strong>${e.chain_id??"알 수 없는 체인"}</strong>
        <${g} label=${e.event} tone=${ce(e.event)} />
      </div>
      <div class="cmd-card rounded-xl-sub">${T(e.timestamp)}</div>
      <div class="cmd-card rounded-xl-sub">${lt(e)}</div>
    </article>
  `}function Vr({node:e}){return s`
    <article class="p-3 rounded-[10px] bg-[rgba(9,12,20,0.5)] border border-solid border-[var(--white-6)]">
      <div class="flex justify-between gap-3 items-start">
        <strong>${e.id}</strong>
        <${g} label=${e.status??"확인 필요"} tone=${ce(e.status)} />
      </div>
      <div class="cmd-card rounded-xl-sub">
        ${e.type??"노드"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?s`<div class="cmd-card rounded-xl-sub text-red-300">${e.error}</div>`:null}
    </article>
  `}function Kr({card:e}){const t=e.operation,a=`pause:${t.operation_id}`,n=`resume:${t.operation_id}`,r=`recall:${t.operation_id}`,o=t.chain,i=(o==null?void 0:o.run_id)??null;return s`
    <article class="cmd-card rounded-xl">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="cmd-card rounded-xl-sub">${t.operation_id}</div>
        </div>
        <${g} label=${fa(t.status)} tone=${h(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>트레이스</span><span class="font-mono">${t.trace_id}</span>
        <span>자율성</span><span>${t.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${t.budget_class??"standard"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>최근 갱신</span><span>${T(t.updated_at)}</span>
      </div>
      ${o?s`
            <div class="cmd-tag rounded-full-row">
              <span class="cmd-tag rounded-full">${o.kind}</span>
              <span class="cmd-tag rounded-full ${ce(o.status)}">${fa(o.status)}</span>
              ${o.chain_id?s`<span class="cmd-tag rounded-full">${o.chain_id}</span>`:null}
              ${o.run_id?s`<span class="cmd-tag rounded-full">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?s`<div class="cmd-card rounded-xl-foot">체크포인트 ${t.checkpoint_ref}</div>`:null}
      <div class="flex gap-3 flex-wrap mt-3">
        <${z}
          variant="ghost"
          onClick=${()=>{te("swarm"),ee("operations",{...be("swarm"),operation_id:t.operation_id,...i?{run_id:i}:{}})}}
        >
          스웜 실시간 보기
        <//>
        ${o?s`
              <${z}
                variant="ghost"
                onClick=${()=>{ft(t.operation_id),te("chains"),ee("operations",{...be("chains"),operation:t.operation_id})}}
              >
                체인 열기
              <//>
            `:null}
        ${t.source==="managed"&&t.status==="active"?s`
              <${z} variant="ghost" disabled=${V(a)} onClick=${()=>de(()=>Es(t.operation_id))}>
                ${V(a)?"일시정지 중…":"일시정지"}
              <//>
              <${z} variant="ghost" disabled=${V(r)} onClick=${()=>de(()=>Ls(t.operation_id))}>
                ${V(r)?"회수 중…":"회수"}
              <//>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?s`
              <${z} variant="ghost" disabled=${V(n)} onClick=${()=>de(()=>As(t.operation_id))}>
                ${V(n)?"재개 중…":"재개"}
              <//>
            `:null}
      </div>
    </article>
  `}function Hr({card:e}){var a;const t=e.detachment;return s`
    <article class="cmd-card rounded-xl p-3">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${t.detachment_id}</strong>
          <div class="cmd-card rounded-xl-sub">${((a=e.operation)==null?void 0:a.objective)??t.operation_id}</div>
        </div>
        <${g} label=${t.status??"active"} tone=${h(t.status)} />
      </div>
      <div class="cmd-card rounded-xl-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>리더</span><span>${t.leader_id??"미지정"}</span>
        <span>편성</span><span>${t.roster.length}</span>
        <span>세션</span><span>${t.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${t.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${t.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${T(t.last_progress_at)}</span>
        <span>하트비트</span><span>${Ia(t.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${T(t.updated_at)}</span>
      </div>
      <div class="cmd-tag rounded-full-row">
        ${t.heartbeat_deadline?s`<span class="cmd-tag rounded-full ${vn(t.heartbeat_deadline)}">
              기한 ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Gr(){const e=_e.value;return s`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="${F} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">작전</h3>
        </div>
        ${e&&e.operations.operations.length>0?s`<div class="cmd-card rounded-xl-stack">
              ${e.operations.operations.map(t=>s`<${Kr} card=${t} />`)}
            </div>`:s`<${M} message="관리형 또는 투영된 작전이 없습니다." compact />`}
      </section>
      <section class="${F} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">분견대</h3>
        </div>
        ${e&&e.detachments.detachments.length>0?s`<div class="cmd-card rounded-xl-stack">
              ${e.detachments.detachments.map(t=>s`<${Hr} card=${t} />`)}
            </div>`:s`<${M} message="투영된 분견대가 없습니다." compact />`}
      </section>
    </div>
  `}function Ur(){var d,l,p,x,m,_,f,y,v,b,$,C,u,L,E,c;const e=bt.value,t=(e==null?void 0:e.operations)??[],a=Ps.value,n=t.find(S=>S.operation.operation_id===a)??t[0]??null,r=((d=n==null?void 0:n.operation.chain)==null?void 0:d.run_id)??null,o=((l=sa.value)==null?void 0:l.run)??(n==null?void 0:n.preview_run)??null,i=!((p=sa.value)!=null&&p.run)&&!!(n!=null&&n.preview_run);return H(()=>{r?js(r):Rs()},[r]),s`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="${F} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">Chains</h3>
        </div>
        <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${ce(e==null?void 0:e.connection.status)}">
          <div class="flex justify-between gap-3 items-start">
            <strong>native chain 연결</strong>
            <${g} label=${(e==null?void 0:e.connection.status)??"disconnected"} tone=${ce(e==null?void 0:e.connection.status)} />
          </div>
          <p>${(e==null?void 0:e.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="cmd-card rounded-xl-grid">
            <span>기준 URL</span><span>${(e==null?void 0:e.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((x=e==null?void 0:e.summary)==null?void 0:x.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((m=e==null?void 0:e.summary)==null?void 0:m.active_chains)??0}</span>
            <span>최근 실패</span><span>${((_=e==null?void 0:e.summary)==null?void 0:_.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${T((f=e==null?void 0:e.summary)==null?void 0:f.last_history_event_at)}</span>
          </div>
        </article>

        ${na.value?s`<${M} message=${na.value} compact />`:null}

        ${Ts.value&&!e?s`<${M} message="체인 오버레이 불러오는 중…" compact />`:t.length>0?s`
                <div class="flex flex-col gap-3 mt-3.5">
                  ${t.map(S=>s`
                    <${Xr}
                      overlay=${S}
                      selected=${(n==null?void 0:n.operation.operation_id)===S.operation.operation_id}
                      onSelect=${()=>ft(S.operation.operation_id)}
                    />
                  `)}
                </div>
              `:s`<${M} message="체인 기반 작전이 아직 없습니다." compact />`}

        <div class="flex flex-col gap-3 mt-3.5">
          <div class="flex justify-between gap-3 items-start">
            <strong>최근 이력</strong>
            <${g} label=${String((e==null?void 0:e.recent_history.length)??0)} />
          </div>
          ${e&&e.recent_history.length>0?s`
                <div class="cmd-card rounded-xl-stack">
                  ${e.recent_history.slice(0,6).map(S=>s`<${Dr} item=${S} />`)}
                </div>
              `:s`<${M} message="최근 체인 이력이 없습니다." compact />`}
        </div>
      </section>

      <section class="${F} min-h-[240px]">
        <div class="pb-2 border-b border-[var(--card-border)] mb-3">
          <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider">체인 상세</h3>
        </div>
        ${n?s`
              <article class="cmd-card rounded-xl">
                <div class="cmd-card rounded-xl-head">
                  <div>
                    <strong>${n.operation.objective}</strong>
                    <div class="cmd-card rounded-xl-sub">${n.operation.operation_id}</div>
                  </div>
                  <${g} label=${((y=n.operation.chain)==null?void 0:y.status)??n.operation.status} tone=${ce((v=n.operation.chain)==null?void 0:v.status)} />
                </div>
                <div class="cmd-card rounded-xl-grid">
                  <span>종류</span><span>${((b=n.operation.chain)==null?void 0:b.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${(($=n.operation.chain)==null?void 0:$.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${r??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${je((C=n.runtime)==null?void 0:C.progress)}</span>
                  <span>경과</span><span>${ke((u=n.runtime)==null?void 0:u.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${T(((L=n.operation.chain)==null?void 0:L.last_sync_at)??n.operation.updated_at)}</span>
                </div>
                ${(E=n.operation.chain)!=null&&E.goal?s`<div class="cmd-card rounded-xl-foot">${n.operation.chain.goal}</div>`:null}
              </article>

              ${n.mermaid?s`
                    <div class="mt-3.5 p-4 bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl">
                      <div class="flex justify-between gap-3 items-start">
                        <strong>Mermaid 그래프</strong>
                        <${g} label=${((c=n.operation.chain)==null?void 0:c.chain_id)??"graph"} />
                      </div>
                      <${zr} source=${n.mermaid} />
                    </div>
                  `:s`<${M} message="기록된 Mermaid 그래프가 아직 없습니다." compact />`}

              <div class="mt-3.5 p-4 bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl">
                <div class="flex justify-between gap-3 items-start">
                  <strong>실행 상세</strong>
                  <${g} label=${o?o.success===!1?"실패":i?"미리보기":"기록됨":"대기 중"} tone=${(o==null?void 0:o.success)===!1?"bad":"ok"} />
                </div>
                ${Is.value?s`<${M} message="실행 상세 불러오는 중…" compact />`:ra.value?s`<${M} message=${ra.value} compact />`:o&&o.nodes.length>0?s`
                          <div class="cmd-card rounded-xl-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${i?s`<div class="cmd-card rounded-xl-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="cmd-card rounded-xl-stack">
                            ${o.nodes.map(S=>s`<${Vr} node=${S} />`)}
                          </div>
                        `:s`<${M} message="이 작전의 run-store 상세는 아직 없습니다." compact />`}
              </div>
            `:s`<${M} message="그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요." compact />`}
      </section>
    </div>
  `}function Jr(e){switch((e??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Zr({decision:e}){const t=`approve:${e.decision_id}`,a=`deny:${e.decision_id}`,n=e.source==="projected_operator";return s`
    <article class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] ${h(e.status)}">
      <div class="flex justify-between items-start gap-3 mb-2">
        <div>
          <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${e.requested_action}</strong>
          <div class="text-[11px] text-[var(--text-muted)] mt-0.5">${e.scope_type}:${e.scope_id}</div>
        </div>
        <${g} label=${Jr(e.status??"pending")} tone=${h(e.status)} />
      </div>
      <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-[12px] mt-2">
        <span class="text-[var(--text-muted)]">결정 ID</span><span class="text-[var(--text-body)]">${e.decision_id}</span>
        <span class="text-[var(--text-muted)]">요청자</span><span class="text-[var(--text-body)]">${e.requested_by??"알 수 없음"}</span>
        <span class="text-[var(--text-muted)]">출처</span><span class="text-[var(--text-body)]">${e.source??"managed"}</span>
        <span class="text-[var(--text-muted)]">트레이스</span><span class="font-mono text-[var(--text-body)]">${e.trace_id}</span>
        <span class="text-[var(--text-muted)]">생성 시각</span><span class="text-[var(--text-body)]">${T(e.created_at)}</span>
        <span class="text-[var(--text-muted)]">이유</span><span class="text-[var(--text-body)]">${e.reason??"정보 없음"}</span>
      </div>
      ${e.status==="pending"&&!n?s`
            <div class="flex gap-3 flex-wrap mt-3">
              <button class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${V(t)} onClick=${()=>de(()=>Ns(e.decision_id))}>
                ${V(t)?"승인 중…":"승인"}
              </button>
              <button class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${V(a)} onClick=${()=>de(()=>Bs(e.decision_id))}>
                ${V(a)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${n?s`<div class="mt-2 text-[12px] text-[var(--text-muted)] border-t border-[var(--white-4)] pt-2">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function Qr({row:e}){var d,l,p;const t=e.unit,a=`freeze:${t.unit_id}`,n=`kill:${t.unit_id}`,r=!!((d=t.policy)!=null&&d.frozen),o=!!((l=t.policy)!=null&&l.kill_switch),i=Math.round((e.utilization??0)*100);return s`
    <article class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <div class="flex justify-between items-start gap-3 mb-2">
        <div>
          <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${t.label}</strong>
          <div class="text-[11px] text-[var(--text-muted)] mt-0.5">${t.unit_id}</div>
        </div>
        <${g} label=${`${i}%`} tone=${h(i>100?"bad":i>70?"warn":"ok")} />
      </div>
      <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5 text-[12px] mt-2">
        <span class="text-[var(--text-muted)]">편성</span><span class="text-[var(--text-body)]">${e.roster_live??0}/${e.roster_total??0}</span>
        <span class="text-[var(--text-muted)]">정원</span><span class="text-[var(--text-body)]">${e.headcount_cap??0}</span>
        <span class="text-[var(--text-muted)]">작전</span><span class="text-[var(--text-body)]">${e.active_operations??0}/${e.active_operation_cap??0}</span>
        <span class="text-[var(--text-muted)]">자율성</span><span class="text-[var(--text-body)]">${((p=t.policy)==null?void 0:p.autonomy_level)??"정보 없음"}</span>
        <span class="text-[var(--text-muted)]">동결</span><span class="text-[var(--text-body)]">${r?"예":"아니오"}</span>
        <span class="text-[var(--text-muted)]">킬 스위치</span><span class="text-[var(--text-body)]">${o?"켜짐":"꺼짐"}</span>
      </div>
      <div class="flex gap-3 flex-wrap mt-3">
        <button class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${V(a)} onClick=${()=>de(()=>Ys(t.unit_id,!r))}>
          ${V(a)?"적용 중…":r?"동결 해제":"동결"}
        </button>
        <button class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]" disabled=${V(n)} onClick=${()=>de(()=>Fs(t.unit_id,!o))}>
          ${V(n)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function eo(){const e=_e.value;return s`
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="${F} min-h-[240px]">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)] mb-3">승인 대기</h3>
        ${e&&e.decisions.decisions.length>0?s`<div class="flex flex-col gap-3">
              ${e.decisions.decisions.map(t=>s`<${Zr} decision=${t} />`)}
            </div>`:s`<${M} message="지금 승인 대기 항목은 없습니다." compact />`}
      </section>

      <section class="${F} min-h-[240px]">
        <h3 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider pb-2 border-b border-[var(--card-border)] mb-3">유닛 제어</h3>
        ${e&&e.capacity.capacity.length>0?s`<div class="flex flex-col gap-3">
              ${e.capacity.capacity.map(t=>s`<${Qr} row=${t} />`)}
            </div>`:s`<${M} message="제어할 용량 행이 아직 없습니다." compact />`}
      </section>
    </div>
  `}function to(){return s`
    <div class="cmd-surface-tabs flex-col gap-3">
      ${pn.map(e=>s`
        <div class="flex flex-col gap-1.5" key=${e.id}>
          <span class="text-[11px] font-semibold text-[var(--white-40)] uppercase tracking-[0.04em] pl-1">${e.label}</span>
          <div class="flex flex-wrap gap-2">
            ${un.filter(t=>t.group===e.id).map(t=>s`
                <button
                  class="border border-[var(--white-12)] bg-[var(--white-4)] text-[var(--white-72)] p-[8px_14px] capitalize rounded-full cmd-surface-tab ${O.value===t.id?"active":""}"
                  onClick=${()=>{te(t.id),ee("operations",be(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function ao({wallboard:e=!1}){if(O.value==="warroom")return s`<${qr} wallboard=${e} />`;if(O.value==="summary")return s`<${Dn} />`;if(O.value==="orchestra")return s`<${rr} />`;if(O.value==="swarm")return s`<${Nr} />`;if(!_e.value)return s`<${Vn} />`;switch(O.value){case"chains":return s`<${Ur} />`;case"topology":return s`<${Ir} />`;case"alerts":return s`<${Er} />`;case"trace":return s`<${Lr} />`;case"control":return s`<${eo} />`;case"operations":default:return s`<${Gr} />`}}function so(){const e=O.value==="warroom"&&j.value.params.presentation==="wallboard";return H(()=>{De(),et(),Os(),ye(),Ve()},[]),H(()=>{if(j.value.tab!=="command"||j.value.params.section!=="warroom")return;const t=j.value.params.surface,a=j.value.params.operation,n=qe(j.value);if(da(t))te(t);else if(n){const r=Ws(n);da(r)&&te(r)}else t||te("warroom");a&&ft(a),(t==="swarm"||t==="warroom"||t==="orchestra"||O.value==="warroom"||O.value==="orchestra")&&ye(),(t==="orchestra"||O.value==="orchestra")&&Ve(),(t==="warroom"||O.value==="warroom")&&ie()},[j.value.tab,j.value.params.section,j.value.params.surface,j.value.params.operation,j.value.params.operation_id,j.value.params.run_id,j.value.params.source,j.value.params.action_type,j.value.params.target_type,j.value.params.target_id,j.value.params.focus_kind]),H(()=>{let t=null;const a=()=>{t||(t=window.setTimeout(()=>{t=null,De(),et(),(O.value==="swarm"||O.value==="warroom"||O.value==="orchestra")&&ye(),O.value==="orchestra"&&Ve(),O.value==="warroom"&&ie()},250))},n=new EventSource(dn()),r=cn.map(o=>{const i=()=>a();return n.addEventListener(o,i),{type:o,handler:i}});return n.onerror=()=>{a()},()=>{r.forEach(({type:o,handler:i})=>{n.removeEventListener(o,i)}),n.close(),t&&window.clearTimeout(t)}},[]),H(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const a=O.value;a!=="swarm"&&a!=="warroom"&&a!=="orchestra"||(De(),ye(),a==="orchestra"&&Ve(),a==="warroom"&&ie())},3e4);return()=>{window.clearInterval(t)}},[]),s`
    <section class="flex flex-col gap-[18px] ${e?"p-4 rounded-[18px] cmd-plane-view wallboard":""}">
      ${e?null:s`
        <div class="${F} flex justify-between gap-4 items-start max-[880px]:flex-col">
          <div>
            <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-1">지휘면</h2>
            <p class="text-[13px] text-[var(--text-muted)] leading-relaxed max-w-[62ch]">기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
          </div>
          <div class="flex gap-3 flex-wrap">
            <button
              class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
              onClick=${()=>{de(()=>qs())}}
              disabled=${V("dispatch:tick")}
            >
              ${V("dispatch:tick")?"정리 중...":"Tick 실행"}
            </button>
            <button
              class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
              onClick=${()=>{ya(),De(),et(),ye(),O.value==="warroom"&&ie()}}
              disabled=${oa.value}
            >
              ${oa.value?"새로고침 중...":"새로고침"}
            </button>
            <button
              class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
              onClick=${()=>{te("warroom"),ee("operations",{...be("warroom"),presentation:"wallboard"})}}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${ia.value?s`<${M} message=${ia.value} compact />`:null}
      ${la.value?s`<${M} message=${la.value} compact />`:null}
      ${e?null:s`<${ja} />`}
      ${e?null:s`<${On} />`}
      ${e||O.value==="warroom"?null:s`<${Wn} />`}
      ${e?null:s`<${to} />`}
      <${ao} wallboard=${e} />
    </section>
  `}function no(){const e=j.value.params.section;return e==="warroom"||e==="governance"?e:"intervene"}function $o(){const e=no();return s`
    <div class="flex flex-col gap-6">
      <div class="transition-opacity duration-300">
        ${e==="governance"?s`<${mn} />`:e==="warroom"?s`<${so} />`:s`<${Fn} />`}
      </div>
    </div>
  `}export{$o as Operations};
