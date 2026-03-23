import{m as a,C as k,E as h,bp as B,bq as K,am as C,br as ge,bs as F,bt as Ve,bu as Xe,bv as pe,bw as Ce,bx as mt,by as gt,aC as Je,bz as ft,aJ as Ye,bA as fe,bB as ze,bC as Ze,bD as et,bE as bt,bF as _t,bG as ht,bH as yt,bI as tt,bJ as kt,bK as Re,bL as U,bM as W,bN as wt,bO as Ct,bP as St,bQ as At,bR as Tt,bS as It,bT as re,bU as Lt,q as se,y as q,l as ve,bV as Et,bW as st,z as at,bX as nt,T as I,bY as lt,A as J,bZ as jt,G as be,Z as Q,Y as Be,b_ as Rt,a9 as $e,b$ as Bt,c0 as Mt,c1 as Nt,c2 as Ot,aR as Kt,c3 as Dt,c4 as Pt,c5 as rt,c6 as it,c7 as Ft,c8 as Ht,c9 as qt,ca as Gt,cb as Ut,cc as Wt,r as _e,cd as ot,ce as ct,cf as Qt,cg as Vt,ch as Xt}from"./index-BB0zaaHQ.js";import{y as O,d as Me,A as dt,T as Ne,c as _,b as Se}from"./vendor-Chwn_OlE.js";import{L as ut}from"./feedback-state-DiW1_ueY.js";import{t as w,b as pt}from"./input-DWPrIiMN.js";import{a as ae,p as Ae,s as M,i as Te,H as Ie,b as j,c as R,q as Jt,d as Yt,e as zt,g as Zt,h as es,j as ts,R as ss}from"./shared-ajMFPXbw.js";import{S}from"./status-chip-B-Vgmq3f.js";import{S as Oe}from"./stat-tile-Dyk_8z2I.js";import{F as as}from"./filter-chips-Cu5kYIK3.js";import{ActivityGraphSurface as ns}from"./activity-graph-EaoTpPzs.js";const ls={"white-3":"bg-[var(--white-3)]","white-4":"bg-[var(--white-4)]"},rs={md:"text-lg",lg:"text-xl"};function y({label:e,value:s,detail:t,tone:l,size:r="md",bg:n="white-4",class:i}){return a`
    <div class="p-4 rounded-xl ${ls[n]} border border-[var(--white-6)] grid gap-1.5 ${l??""} ${i??""}">
      <span class="text-[10px] text-[var(--text-muted)] tracking-wider uppercase font-medium">${e}</span>
      <strong class="text-[var(--text-strong)] ${rs[r]} leading-tight tabular-nums">${s}</strong>
      ${t!=null?a`<small class="text-[var(--text-muted)] text-[10px] leading-relaxed">${t}</small>`:null}
    </div>
  `}function vt({children:e,onClick:s,class:t}){const l="px-2.5 py-1.5 rounded-full border border-[var(--white-8)] bg-[var(--white-4)] text-[rgba(255,255,255,0.76)] text-xs leading-tight";return s?a`<button class="${l} cursor-pointer ${t??""}" onClick=${s}>${e}</button>`:a`<span class="${l} ${t??""}">${e}</span>`}function P({title:e,subtitle:s,detail:t,onClick:l,class:r}){const n=`w-full p-4 rounded-xl border border-[var(--white-6)] bg-[var(--white-3)] grid gap-2.5 text-left text-inherit ${l?"cursor-pointer":"cursor-default"} ${r??""}`,i=a`
    <strong class="text-[var(--text-strong)]">${e}</strong>
    ${s!=null?a`<span class="text-[rgba(255,255,255,0.72)] leading-snug">${s}</span>`:null}
    ${t!=null?a`<small class="text-[rgba(255,255,255,0.72)] leading-snug">${t}</small>`:null}
  `;return l?a`<button class="${n}" onClick=${l}>${i}</button>`:a`<div class="${n}">${i}</div>`}function Le({children:e,class:s}){return a`
    <div class="flex gap-3 flex-wrap mt-3 ${s??""}">
      ${e}
    </div>
  `}function T({label:e,onClick:s,disabled:t}){return a`
    <button class="control-btn rounded-lg ghost" onClick=${s} disabled=${t}>
      ${e}
    </button>
  `}function is({brief:e,selected:s}){var d,x;const t=e.member_previews.slice(0,4),l=e.top_recommendation??null,r=e.top_attention??null,n=e.active_count??0,i=e.seen_count??n,v=e.planned_count??e.member_names.length;return a`
    <article class="mission-crew-card p-4 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(180deg,var(--white-5),var(--white-3))] grid gap-3 ${w(((d=e.top_attention)==null?void 0:d.severity)??e.health??e.status)} ${F(e.status,e.health)} ${s?"is-selected":""}">
      <button class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${()=>Ve(e.session_id)}>
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <div class="flex items-center gap-2">
              <div class="mission-status-dot ${F(e.status,e.health)} ${Xe(F(e.status,e.health))}"></div>
              <strong>${e.goal}</strong>
            </div>
            <div class="text-[var(--text-muted)] text-[13px] mt-1">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <${S} label=${C(e.status)} tone=${w(((x=e.top_attention)==null?void 0:x.severity)??e.health??e.status)} />
        </div>

        <div class="grid grid-cols-2 gap-3">
          <${y} label="멤버" value=${e.member_names.length} detail=${e.member_names.slice(0,3).join(", ")||"없음"} />
          <${y} label="가동 시간" value=${pe(e.elapsed_sec)} detail=${e.started_at?`${B(e.started_at)} 시작`:"시작 시각 없음"} />
          <${y} label="최근 흐름" value=${e.last_event_at?B(e.last_event_at):"기록 없음"} detail=${e.communication_summary??"요약 없음"} />
          <${y} label="충원 상태" value=${`${n}/${e.required_count||1}`} detail=${`live · seen ${i} · planned ${v}`} />
        </div>
      </button>

      ${e.blocker_summary?a`<div class="grid gap-1.5 px-1">막힘 · ${e.blocker_summary}</div>`:null}
      ${e.counts_basis?a`<div class="grid gap-1.5 px-1">관측 기준 · ${e.counts_basis}</div>`:null}

      <div class="grid gap-1.5 px-1">
        <span>최근 사건</span>
        <strong>${e.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${e.last_event_at?B(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?a`
            <div class="flex gap-3 flex-wrap">
              ${e.operation_badges.slice(0,3).map(o=>a`
                <${vt}>${o.operation_id} · ${C(o.status)}${o.stage?` · ${o.stage}`:""}<//>
              `)}
            </div>
          `:null}

      ${t.length>0?a`
            <div class="grid grid-cols-2 gap-3">
              ${t.map(o=>a`
                <${P}
                  title=${o.agent_name}
                  subtitle=${a`${o.current_work??"현재 작업 없음"}${o.is_live===!1?" · archived":o.is_live===!0?" · live":""}`}
                  detail=${o.recent_output_preview??o.recent_input_preview??"최근 입출력 없음"}
                  onClick=${()=>K(o.agent_name)}
                />
              `)}
            </div>
          `:null}

      <${Le}>
        <${T} label="세션 개입 열기" onClick=${()=>ge("intervene",e.session_id)} />
        <${T} label="세션 원인 보기" onClick=${()=>ge("command",e.session_id)} />
        ${l?a`<${T} label="추천 액션 열기" onClick=${()=>Ce(l,r,"상황판 세션 요약")} />`:null}
      <//>
    </article>
  `}function os({detail:e,loading:s,error:t}){if(s&&!e)return a`
      <${k} title="세션 상세" class="mission-list-card rounded-xl">
        <${ut}>세션 상세 불러오는 중...<//>
      <//>
    `;if(t&&!e)return a`
      <${k} title="세션 상세" class="mission-list-card rounded-xl">
        <${h} message=${t} compact />
      <//>
    `;if(!(e!=null&&e.session))return null;const l=e.session;return a`
    <${k} title="세션 상세" class="mission-list-card rounded-xl">
      <div class="grid gap-1.5 mb-4">
        <h3 class="m-0 text-[var(--text-strong)] text-lg">${l.goal}</h3>
        <p class="m-0 text-[var(--text-body)] leading-normal">${l.session_id}${l.room?` · ${l.room}`:""}</p>
      </div>

      ${t?a`<div class="grid gap-1.5">${t}</div>`:null}

      <div class="grid grid-cols-2 gap-5 mt-4">
        <div class="grid gap-3">
          <div class="flex justify-between gap-3 items-start flex-wrap">
            <strong>타임라인</strong>
            <${S} label=${String(e.timeline.length)} />
          </div>
          <div class="flex flex-col gap-3">
            ${e.timeline.length>0?e.timeline.map(r=>a`
                  <${P}
                    title=${r.summary}
                    subtitle=${r.timestamp?B(r.timestamp):"시각 없음"}
                    detail=${a`${r.actor?`${r.actor} · `:""}${r.event_type??"이벤트"}`}
                  />
                `):a`<${h} message="표시할 세션 이벤트가 없습니다." compact />`}
          </div>
        </div>

        <div class="grid gap-3">
          <div class="flex justify-between gap-3 items-start flex-wrap">
            <strong>참여자</strong>
            <${S} label=${String(e.participants.length)} />
          </div>
          <div class="flex flex-col gap-3">
            ${e.participants.length>0?e.participants.map(r=>a`
                  <${P}
                    title=${r.agent_name}
                    subtitle=${r.current_work??"현재 작업 없음"}
                    detail=${a`${r.recent_output_preview??r.recent_input_preview??"최근 입출력 없음"}${r.last_activity_at?` · ${B(r.last_activity_at)}`:""}`}
                    onClick=${()=>K(r.agent_name)}
                  />
                `):a`<${h} message="세션 참여자 미리보기가 없습니다." compact />`}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-2 gap-5 mt-4">
        <div class="grid gap-3">
          <div class="flex justify-between gap-3 items-start flex-wrap">
            <strong>연결된 작전</strong>
            <${S} label=${String(e.operations.length)} />
          </div>
          <div class="flex flex-col gap-3">
            ${e.operations.length>0?e.operations.map(r=>a`
                  <${P}
                    title=${r.operation_id}
                    subtitle=${a`${C(r.status)}${r.stage?` · ${r.stage}`:""}`}
                    detail=${r.detachment_status??r.objective??"분견대 정보 없음"}
                    onClick=${()=>ge("command",l.session_id)}
                  />
                `):a`<${h} message="연결된 작전이 없습니다." compact />`}
          </div>
        </div>

        <div class="grid gap-3">
          <div class="flex justify-between gap-3 items-start flex-wrap">
            <strong>연속성 관찰</strong>
            <${S} label=${String(e.keepers.length)} />
          </div>
          <div class="flex flex-col gap-3">
            ${e.keepers.length>0?e.keepers.map(r=>a`
                  <${P}
                    title=${r.name}
                    subtitle=${a`${C(r.status)}${r.generation!=null?` · 세대 ${r.generation}`:""}`}
                    detail=${r.current_work??"현재 작업 정보 없음"}
                  />
                `):a`<${h} message="직접 연결된 키퍼는 없습니다." compact />`}
          </div>
        </div>
      </div>
    <//>
  `}function cs({row:e}){var l,r,n,i,v,d,x,o,m,u,g,$,f;const s=[`세대 ${e.brief.generation??((l=e.keeper)==null?void 0:l.generation)??0}`,e.brief.context_ratio!=null?`컨텍스트 ${Math.round(e.brief.context_ratio*100)}%`:((r=e.keeper)==null?void 0:r.context_ratio)!=null?`컨텍스트 ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(e.brief.last_turn_ago_s)}초 전`:null].filter(b=>b!==null).join(" · "),t=e.recentTools.length>0?e.recentTools.join(", "):mt(gt(e.keeper));return a`
    <article class="w-full p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 text-inherit text-left cursor-pointer ${w(e.brief.status??((n=e.keeper)==null?void 0:n.status))} ${F(e.brief.status,(i=e.keeper)==null?void 0:i.status)}">
      <button class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${()=>{const b=e.keeper??{name:e.brief.name,agent_name:e.brief.agent_name??e.brief.name,status:e.brief.status??"unknown",context_ratio:e.brief.context_ratio??null};Je(b)}}>
        <div class="flex justify-between gap-3 items-start">
          <div class="flex gap-3 items-start">
            <div class="mission-status-dot ${F(e.brief.status,(v=e.keeper)==null?void 0:v.status)} ${Xe(F(e.brief.status,(d=e.keeper)==null?void 0:d.status))}"></div>
            <span class="agent-emoji">${((x=e.keeper)==null?void 0:x.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(o=e.keeper)!=null&&o.koreanName?a`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <${S} label=${C(e.brief.status??((m=e.keeper)==null?void 0:m.status))} tone=${w(e.brief.status??((u=e.keeper)==null?void 0:u.status))} />
        </div>

        <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug">
          <span>최근 하트비트 · ${(g=e.keeper)!=null&&g.last_heartbeat?B(e.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${s||"연속성 정보 없음"}</span>
        </div>

        <div class="grid gap-1.5">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${($=e.keeper)!=null&&$.skill_reason?a`<small>판단 요약 · ${ft(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="pt-2 border-t border-[var(--white-6)]">
        <summary>연속성 상세</summary>
        <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug mt-3">
          <span>에이전트 · ${e.brief.agent_name??((f=e.keeper)==null?void 0:f.agent_name)??"기록 없음"}</span>
          ${e.recentEvent?a`<span>최근 일 · ${e.recentEvent}</span>`:null}
        </div>
        <details class="pt-2 border-t border-[var(--white-6)] mt-3">
          <summary>입력 · 응답 · 도구</summary>
          <div class="grid grid-cols-2 gap-3 mt-3">
            <${y} label="최근 입력" value=${e.recentInput??"표시 가능한 최근 입력이 없습니다"} bg="white-3" />
            <${y} label="최근 응답" value=${e.recentOutput??"표시 가능한 최근 응답이 없습니다"} bg="white-3" />
          </div>
          <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug mt-3">
            <span>최근 도구 · ${t}</span>
          </div>
        </details>
      </details>
    </article>
  `}function ds({item:e}){const s=e.action??null,t=e.attention??null;return a`
    <article class="p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 ${w(e.severity)}">
      <div class="flex justify-between gap-3 items-start flex-wrap">
        <${S} label=${e.signal_type==="action"&&s?Ye(s.action_type):(t==null?void 0:t.kind)??"내부 신호"} tone=${w(e.severity)} />
        <span class="text-[var(--text-muted)] text-[13px]">${fe(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p class="m-0 text-[rgba(255,255,255,0.8)] leading-normal">${e.summary}</p>
      ${s?a`<div class="py-3 px-4 rounded-xl bg-[var(--white-5)] border border-[var(--white-8)] text-[var(--text-strong)] leading-snug">${s.reason}</div>`:null}
      <${Le}>
        ${s?a`
              <${T} label="이 액션으로 개입 열기" onClick=${()=>Ce(s,t,"상황판 내부 신호")} />
              <${T} label="이 이슈의 원인 보기" onClick=${()=>ze(s,t,"상황판 내부 신호")} />
            `:t?a`
                <${T} label="이 이슈로 개입 열기" onClick=${()=>Ze(t)} />
                <${T} label="이 이슈의 원인 보기" onClick=${()=>et(t)} />
              `:null}
      <//>
    </article>
  `}function us({item:e,selected:s,sessionLookup:t}){const l=bt(e),r=e.related_session_ids.map(i=>t.get(i)).filter(i=>i!=null),n=e.top_action??null;return a`
    <article class="mission-attention-card p-4 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(180deg,var(--white-6),var(--white-3))] grid gap-3 ${w((n==null?void 0:n.severity)??e.severity)} ${s?"is-selected":""}">
      <button class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${()=>_t(e.id)}>
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <strong>${e.summary}</strong>
            <div class="text-[var(--text-muted)] text-[13px] mt-1">${fe(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <${S} label=${n?ht(n):e.severity} tone=${w((n==null?void 0:n.severity)??e.severity)} />
        </div>

        <div class="grid grid-cols-2 gap-3">
          <${y} label="영향 세션" value=${e.related_session_ids.length} detail=${e.related_session_ids.slice(0,2).join(", ")||"없음"} />
          <${y} label="영향 에이전트" value=${e.related_agent_names.length} detail=${e.related_agent_names.slice(0,3).join(", ")||"없음"} />
          <${y} label="최근 신호" value=${e.last_seen_at?B(e.last_seen_at):"기록 없음"} detail=${fe(e.target_type)} />
          <${y} label="다음 액션" value=${n?Ye(n.action_type):"판단 필요"} detail=${n?yt(n):"추천 액션 없음"} />
        </div>
      </button>

      ${n?a`<div class="grid gap-1.5 px-1">${n.reason}</div>`:null}

      <details class="pt-2 border-t border-[var(--white-6)]">
        <summary>연결된 흐름 보기</summary>
        ${r.length>0?a`
              <div class="flex flex-col gap-3 mt-3">
                ${r.slice(0,4).map(i=>a`
                  <${P}
                    title=${i.goal}
                    subtitle=${a`${C(i.status)} · ${i.last_event_summary??"최근 사건 없음"}`}
                    onClick=${()=>Ve(i.session_id)}
                  />
                `)}
              </div>
            `:a`<${h} message="직접 연결된 세션이 아직 없습니다." compact />`}

        ${e.related_agent_names.length>0?a`
              <div class="flex gap-3 flex-wrap mt-3">
                ${e.related_agent_names.slice(0,8).map(i=>a`
                  <${vt} onClick=${()=>K(i)}>${i}<//>
                `)}
              </div>
            `:null}

        ${e.evidence_preview.length>0?a`
              <details class="pt-2 border-t border-[var(--white-6)] mt-3">
                <summary>근거 미리보기</summary>
                <div class="grid gap-3 mt-3">
                  ${e.evidence_preview.map(i=>a`<span>${i}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <${Le}>
        ${n?a`
              <${T} label="이 액션으로 개입 열기" onClick=${()=>Ce(n,l,"상황판 주의 신호")} />
              <${T} label="원인 보기" onClick=${()=>ze(n,l,"상황판 주의 신호")} />
            `:a`
              <${T} label="이 이슈로 개입 열기" onClick=${()=>Ze(l)} />
              <${T} label="이 이슈의 원인 보기" onClick=${()=>et(l)} />
            `}
      <//>
    </article>
  `}function ps({cluster:e,project:s,room:t,generatedAt:l}){return a`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3">
      <${y} label="프로젝트" value=${s??"확인 없음"} />
      <${y} label="방" value=${t??"기본 방"} />
      <${y} label="갱신 시각" value=${l?B(l):"기록 없음"} />
      ${e&&e!=="unknown"?a`<${y} label="배포 메타" value=${e} />`:null}
    </div>
  `}function ne({label:e,value:s,detail:t,tone:l}){return a`<${y} label=${e} value=${s} detail=${t} tone=${w(l)} size="lg" />`}function vs(){var A,p;const e=tt.value;if(kt.value&&!e)return a`<${ut}>상황판 스냅샷 불러오는 중...<//>`;if(Re.value&&!e)return a`<${h} message=${Re.value} compact />`;if(!e)return a`<${h} message="상황판 스냅샷이 아직 없습니다." compact />`;const s=e.sessions,t=U.value&&e.attention_queue.some(c=>c.id===U.value)?U.value:null,l=W.value&&s.some(c=>c.session_id===W.value)?W.value:null;O(()=>{U.value!==t&&(U.value=t),W.value!==l&&(W.value=l)},[t,l]);const r=e.attention_queue.find(c=>c.id===t)??null,n=(r==null?void 0:r.related_session_ids.find(c=>s.some(L=>L.session_id===c)))??null,i=l??n??((A=s[0])==null?void 0:A.session_id)??null,v=wt(),d=s.find(c=>c.session_id===i)??null,x=e.keeper_briefs.slice(0,6).map(Ct),o=e.attention_queue.filter(c=>c.related_session_ids.length>0).slice(0,6),m=e.internal_signals.slice(0,3),u=s.filter(c=>c.top_attention!=null||c.related_attention_count>0).length,g=s.filter(c=>!!c.blocker_summary).length,$=x.filter(c=>{const L=(c.brief.status??"").trim().toLowerCase();return L!==""&&L!=="ok"}).length,f=((d==null?void 0:d.member_previews)??[]).filter(c=>c.recent_output_preview),b=x.filter(c=>c.recentOutput).slice(0,4);return O(()=>{St(i)},[i]),a`
    <section class="flex flex-col gap-5">
      <!-- Header -->
      <div class="flex items-start justify-between gap-4 flex-wrap">
        <div>
          <h2 class="m-0 text-lg font-semibold text-[var(--text-strong)]">상황판</h2>
          <p class="m-0 mt-1 text-xs text-[var(--text-muted)] leading-relaxed">세션, 에이전트, 키퍼 현황.</p>
        </div>
        <div class="flex gap-2 flex-wrap items-center">
          <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[10px] font-medium border border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-body)]">
            <span class="w-1.5 h-1.5 rounded-full ${w(e.summary.room_health)==="ok"?"bg-[var(--ok)]":w(e.summary.room_health)==="warn"?"bg-[var(--warn)]":"bg-[var(--bad)]"}"></span>
            ${C(e.summary.room_health)}
          </span>
          <span class="text-[10px] text-[var(--text-muted)]">${e.generated_at?B(e.generated_at):""}</span>
        </div>
      </div>

      <${ps}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <!-- Summary stats row -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3">
        <${ne}
          label="세션"
          value=${s.length}
          detail="진행 중"
          tone=${((p=d==null?void 0:d.top_attention)==null?void 0:p.severity)??(d==null?void 0:d.health)??"ok"}
        />
        <${ne}
          label="주의"
          value=${u}
          detail="attention"
          tone=${u>0?"warn":"ok"}
        />
        <${ne}
          label="막힘"
          value=${g}
          detail="blocker"
          tone=${g>0?"warn":"ok"}
        />
        <${ne}
          label="키퍼 주의"
          value=${$}
          detail=${`${x.length}명 중`}
          tone=${$>0?"warn":"ok"}
        />
      </div>

      <!-- Jump nav -->
      <nav class="flex gap-2 flex-wrap">
        ${[{id:"mission-sessions",label:"세션",count:s.length},{id:"mission-keepers",label:"키퍼",count:x.length},{id:"mission-output",label:"활동",count:f.length+b.length},{id:"mission-attention",label:"우선순위",count:o.length}].map(c=>a`
          <button
            key=${c.id}
            class="px-2.5 py-1 rounded-full border border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-body)] cursor-pointer hover:bg-[var(--white-8)] transition-colors"
            onClick=${L=>{var G;L.preventDefault(),(G=document.getElementById(c.id))==null||G.scrollIntoView({behavior:"smooth"})}}
          >${c.label} ${c.count}</button>
        `)}
      </nav>

      <!-- Focus session indicator -->
      ${i?a`
            <div class="flex items-center justify-between gap-3 px-4 py-2.5 rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] text-xs text-[var(--text-body)]">
              <span class="truncate">관찰 세션: ${(d==null?void 0:d.goal)??i}${r?` / ${r.summary}`:""}</span>
              <button class="shrink-0 px-2 py-1 rounded border border-[var(--card-border)] bg-transparent text-[10px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]" onClick=${Lt}>해제</button>
            </div>
          `:null}

      <!-- Sessions -->
      <${k} title="진행중인 세션" class="mission-list-card rounded-lg" id="mission-sessions">
        <div class="mb-4">
          <h3 class="m-0 text-sm font-semibold text-[var(--text-strong)]">세션 목록</h3>
          <p class="m-0 mt-1 text-xs text-[var(--text-muted)]">세션 기준 목표, 최근 흐름, 막힘 상태.</p>
          <${ae} items=${[{kind:"truth"}]} />
        </div>
        <div class="flex flex-col gap-3">
          ${s.length>0?s.map(c=>a`<${is} key=${c.session_id} brief=${c} selected=${i===c.session_id} />`):a`<div class="text-xs text-[var(--text-muted)] py-4 text-center">세션 없음.</div>`}
        </div>
      <//>

      <${os}
        detail=${At.value}
        loading=${Tt.value}
        error=${It.value}
      />

      <!-- Keepers -->
      <details open id="mission-keepers" class="rounded-lg border border-[var(--card-border)] overflow-hidden">
        <summary class="mission-collapsible-summary flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)]">
          키퍼 연속성
          <${re}>${x.length}<//>
          ${$>0?a`<span class="text-[10px] px-1.5 py-px rounded bg-[var(--warn-12)] text-[var(--warn)] tabular-nums">${$} 주의</span>`:null}
        </summary>
        <div class="p-4 pt-0">
          <div class="mb-3">
            <p class="m-0 text-xs text-[var(--text-muted)]">키퍼는 세션과 별개로 보고, 연속성과 장기 행위자 상태를 관찰합니다.</p>
            <${ae} items=${[{kind:"truth"}]} />
          </div>
          <div class="flex flex-col gap-3">
            ${x.length>0?x.map(c=>a`<${cs} key=${c.brief.name} row=${c} />`):a`<div class="text-xs text-[var(--text-muted)] py-4 text-center">키퍼 없음.</div>`}
          </div>
          <div class="flex gap-2 flex-wrap mt-3">
            <button class="px-2.5 py-1 rounded border border-[var(--card-border)] bg-transparent text-[10px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]" onClick=${()=>se("status",{section:"sessions"})}>세션 보기</button>
            <button class="px-2.5 py-1 rounded border border-[var(--card-border)] bg-transparent text-[10px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]" onClick=${()=>se("operations",{section:"command"})}>지휘 진단면</button>
          </div>
        </div>
      </details>

      <!-- Activity -->
      <details open id="mission-output" class="rounded-lg border border-[var(--card-border)] overflow-hidden">
        <summary class="mission-collapsible-summary flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)]">
          최근 활동
          <${re}>${f.length+b.length}<//>
        </summary>
        <div class="p-4 pt-0">
          <div class="mb-3">
            <p class="m-0 text-xs text-[var(--text-muted)]">선택된 세션과 연결된 행위자의 최근 출력.</p>
            <${ae} items=${[{kind:"truth"}]} />
          </div>
          <div class="flex flex-col gap-3">
            ${f.length>0?f.slice(0,4).map(c=>a`
                  <div class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--white-6)] bg-[var(--white-3)]">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium text-[var(--text-strong)]">${c.agent_name??"unknown"}</span>
                      ${c.role?a`<span class="text-[10px] text-[var(--text-muted)]">${c.role}</span>`:null}
                      ${c.status?a`<span class="text-[10px] text-[var(--text-muted)]">${C(c.status)}</span>`:null}
                    </div>
                    <div class="text-xs text-[var(--text-body)] leading-relaxed">${c.recent_output_preview}</div>
                  </div>
                `):a`<div class="text-xs text-[var(--text-muted)] py-3 text-center">최근 출력 없음.</div>`}
            ${b.length>0?b.map(c=>a`
                  <div class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--white-6)] bg-[var(--white-3)]">
                    <span class="text-xs font-medium text-[var(--text-strong)]">${c.brief.name}</span>
                    <div class="text-xs text-[var(--text-body)] leading-relaxed">${c.recentOutput}</div>
                  </div>
                `):null}
          </div>
        </div>
      </details>

      <!-- Attention queue -->
      <details open id="mission-attention" class="rounded-lg border border-[var(--card-border)] overflow-hidden">
        <summary class="mission-collapsible-summary flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)]">
          세션 우선순위
          <span class="text-[10px] px-1.5 py-px rounded ${o.length>0?"bg-[var(--warn-12)] text-[var(--warn)]":"bg-[var(--white-8)] text-[var(--text-muted)]"} tabular-nums">${o.length}</span>
        </summary>
        <div class="p-4 pt-0">
          <div class="mb-3">
            <p class="m-0 text-xs text-[var(--text-muted)]">주의 신호 기준 세션 집중 순서.</p>
            <${ae} items=${[{kind:"derived"}]} />
          </div>
          <div class="flex flex-col gap-3">
            ${o.length>0?o.map(c=>a`<${us} key=${c.id} item=${c} selected=${t===c.id} sessionLookup=${v} />`):a`<div class="text-xs text-[var(--text-muted)] py-3 text-center">주의 대기열 비어 있음.</div>`}
          </div>
        </div>
      </details>

      ${m.length>0?a`
        <details class="rounded-lg border border-[var(--card-border)] overflow-hidden">
          <summary class="flex items-center gap-2 px-4 py-3 cursor-pointer text-xs text-[var(--text-muted)]">
            내부 신호
            <${re}>${m.length}<//>
          </summary>
          <div class="flex flex-col gap-3 p-4 pt-0">
            ${m.map(c=>a`<${ds} key=${c.id} item=${c} />`)}
          </div>
        </details>
      `:null}
    </section>
  `}function N(e){if(!e)return"idle";const s=e.toLowerCase();return s==="active"||s==="busy"||s==="listening"||s==="working"?"active":s==="offline"||s==="inactive"?"offline":"idle"}function $s(e){return e?{active:"활성",busy:"처리 중",listening:"대기",working:"작업 중",idle:"유휴",offline:"오프라인",inactive:"비활성"}[e.toLowerCase()]??e:"(unknown)"}function xs(e){const s=N(e);return s==="active"?"roster-badge--active":s==="offline"?"roster-badge--offline":"roster-badge--idle"}function Ke(e,s,t){var l,r;for(const n of t)if(n.name===e||n.agent_name===e||e.includes(n.name)||(l=n.name)!=null&&l.includes(e))return n;for(const n of s)if(n.name===e||n.agent_name===e||e.includes(n.name)||(r=n.name)!=null&&r.includes(e))return n;return null}function ms({keeperFilter:e="all"}={}){const[s,t]=Me("all"),[l,r]=Me(""),n=q.value,i=ve.value,v=Et.value,d=st.value,x=new Map(v.map(u=>[u.agent_name,u])),o=n.filter(u=>{if(s!=="all"&&N(u.status)!==s||l&&!u.name.toLowerCase().includes(l.toLowerCase()))return!1;if(e!=="all"){const g=Ke(u.name,i,d)!=null;if(e==="keeper-only"&&!g||e==="agent-only"&&g)return!1}return!0}).sort((u,g)=>{const $={all:0,active:0,idle:1,offline:2},f=$[N(u.status)],b=$[N(g.status)];return f!==b?f-b:u.name.localeCompare(g.name)}),m={all:n.length,active:n.filter(u=>N(u.status)==="active").length,idle:n.filter(u=>N(u.status)==="idle").length,offline:n.filter(u=>N(u.status)==="offline").length};return a`
    <div class="p-[var(--space-lg,24px)] max-w-[1200px] agent-page">
      <div class="mb-6">
        <h2 class="text-[20px] font-semibold text-[var(--ff-gold-bright)] mb-[var(--space-md,16px)] tracking-[0.5px] [text-shadow:0_1px_4px_rgba(212,169,75,0.2)]">${e==="keeper-only"?"키퍼":"에이전트"} (${o.length})</h2>
        <p class="text-[13px] text-[var(--white-30)] mt-1">${e==="keeper-only"?"키퍼 런타임이 있는 에이전트":e==="agent-only"?"키퍼 런타임이 없는 에이전트":"등록된 에이전트 — keeper 런타임이 있으면 컨텍스트 게이지 표시"}</p>
        <div class="flex gap-4 items-center flex-wrap">
          <input
            type="text"
            class="py-1.5 px-3 border border-[var(--ff-border-subtle)] bg-[var(--ff-navy)] text-[var(--white-90)] text-base w-[200px] rounded transition-colors duration-200 focus:outline-none focus:border-[var(--ff-gold)] focus:shadow-[0_0_0_2px_var(--ff-gold-dim)] placeholder:text-[var(--white-25)]"
            placeholder="이름 검색..."
            value=${l}
            onInput=${u=>r(u.target.value)}
          />
          <div class="flex gap-1.5">
            ${["all","active","idle","offline"].map(u=>a`
              <button
                key=${u}
                class="px-2.5 py-1 text-[11px] rounded-xl border cursor-pointer transition-all duration-150 ${s===u?"border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]":"border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]"}"
                onClick=${()=>t(u)}
              >
                ${u==="all"?"전체":u==="active"?"활성":u==="idle"?"유휴":"오프라인"} ${m[u]}
              </button>
            `)}
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5">
        ${o.map(u=>{const g=x.get(u.name),$=Ke(u.name,i,d),f=$!=null,b=($==null?void 0:$.current_work)??(g==null?void 0:g.current_work)??u.current_task??null,A=($==null?void 0:$.last_turn_ago_s)??(g==null?void 0:g.last_activity_age_sec)??null,p=($==null?void 0:$.context_ratio)!=null?Math.round($.context_ratio*100):null;return a`
            <div
              class="group flex flex-col gap-3 p-5 bg-[var(--bg-1)] border border-[var(--card-border)] rounded-2xl hover:border-[var(--accent-soft)] hover:bg-[var(--bg-0)] transition-all duration-200 shadow-sm cursor-pointer relative overflow-hidden"
              key=${u.name}
              onClick=${()=>K(u.name)}
              role="button"
              tabindex="0"
            >
              ${f&&p!=null?a`<div class="absolute bottom-0 left-0 h-1 bg-linear-to-r from-[var(--accent)] to-[var(--ok)] transition-all duration-300 opacity-80 group-hover:opacity-100" style=${{width:p+"%"}}></div>`:null}
              
              <div class="flex items-start gap-4">
                <div class="shrink-0 relative">
                  <${at}
                    name=${u.name}
                    status=${u.status}
                    traits=${u.traits}
                    size="xl"
                    currentWork=${b}
                    activityAge=${A}
                  />
                  ${f?a`<div class="absolute -bottom-2 left-1/2 -translate-x-1/2 text-[9px] font-bold tracking-[0.1em] text-[var(--ff-gold)] bg-[rgba(20,20,30,0.95)] border border-[var(--ff-gold-20)] px-2 py-0.5 rounded-full shadow-md z-10 uppercase">KEEPER</div>`:null}
                </div>
                
                <div class="flex flex-col min-w-0 flex-1 justify-center py-1">
                  <div class="flex items-center gap-2 flex-wrap mb-1">
                    <strong class="text-lg text-[var(--text-strong)] font-semibold truncate leading-tight group-hover:text-[var(--accent)] transition-colors">${u.name}</strong>
                    <span class="roster-badge ${xs(u.status)}">${$s(u.status)}</span>
                  </div>
                  
                  <div class="flex items-center gap-1.5 flex-wrap">
                    ${$!=null&&$.model?a`<span class="font-mono text-[10px] text-[var(--text-muted)] bg-[var(--white-4)] border border-[var(--card-border)] px-1.5 py-px rounded">${$.model}</span>`:null}
                    ${($==null?void 0:$.generation)!=null?a`<span class="text-[11px] text-[var(--accent)] font-medium bg-[var(--accent-10)] px-1.5 py-px rounded border border-[rgba(71,184,255,0.15)]">Lv.${$.generation}</span>`:null}
                  </div>
                </div>
              </div>

              <div class="flex flex-col gap-2 mt-2 pt-3 border-t border-[var(--border-slate-12)]">
                <div class="flex justify-between items-center text-[10px] text-[var(--text-muted)]">
                  <div class="flex items-center gap-1.5 truncate max-w-[65%]">
                    ${b?a`<span class="text-[12px] text-[var(--accent)] bg-[var(--accent-soft)] px-2 py-0.5 rounded-md truncate font-medium border border-[rgba(71,184,255,0.1)] shadow-sm">${b}</span>`:a`<span class="text-[12px] text-[var(--text-dim)] italic px-2 py-0.5 bg-[var(--white-2)] rounded-md">대기 중</span>`}
                  </div>
                  
                  <div class="flex flex-col items-end gap-1">
                    ${A!=null?a`
                      <span class="flex items-center gap-1 text-[11px]">
                        ⚡ ${pe(A)} 전
                      </span>
                    `:a`<span></span>`}
                    ${f&&p!=null?a`
                      <span class="font-medium text-[11px]"><span class="text-[var(--ff-gold)] mr-1">CTX</span><span class="text-[var(--text-strong)]">${p}%</span></span>
                    `:null}
                  </div>
                </div>
              </div>
            </div>
          `})}
        ${o.length===0?a`
          <div class="py-[var(--space-xl,32px)] text-center text-[var(--white-20)] text-sm border border-dashed border-[var(--ff-border-subtle)] rounded-md col-span-full">조건에 맞는 에이전트가 없습니다.</div>
        `:null}
      </div>
    </div>
  `}function gs(e){return ve.value.find(s=>s.agent_name===e||s.name===e)??null}function fs(e){if(e==null)return"";const s=e*100;return s<50?"":s<70?"warn":"bad"}function bs({name:e}){const s=gs(e);if(!s)return null;const t=s.pipeline_stage,l=t??(s.last_turn_ago_s!=null&&s.last_turn_ago_s<600?"idle":t),r=s.context_ratio,n=r!=null?Math.round(r*100):null,i=s.generation,v=s.active_model??s.model??null,d=s.last_turn_ago_s;return a`
    <div class="agent-runtime-strip">
      <div class="flex items-center gap-1.5 text-[13px]">
        <${nt} stage=${l} />
      </div>

      ${n!=null?a`
        <div class="flex items-center gap-1.5 text-[13px]">
          <span class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider">CTX</span>
          <div class="w-16 h-1.5 bg-[#1a1a2e] rounded-full overflow-hidden">
            <div
              class="agent-runtime-ctx-fill rounded-full ${fs(r)}"
              style=${{width:`${n}%`}}
            ></div>
          </div>
          <span class="text-[13px] text-[var(--text-body)] tabular-nums">${n}%</span>
        </div>
      `:null}

      ${i!=null?a`
        <div class="flex items-center gap-1.5 text-[13px]">
          <span class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider">GEN</span>
          <span class="text-[13px] text-[var(--text-body)] tabular-nums">${i}</span>
        </div>
      `:null}

      ${v?a`
        <div class="flex items-center gap-1.5 text-[13px]">
          <span class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider">MODEL</span>
          <span class="text-[13px] text-[var(--text-body)] font-mono truncate max-w-[200px]">${v}</span>
        </div>
      `:null}

      ${d!=null?a`
        <div class="flex items-center gap-1.5 text-[13px]">
          <span class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider">TURN</span>
          <span class="text-[13px] text-[var(--text-body)] tabular-nums">${pe(d)} ago</span>
        </div>
      `:null}
    </div>
  `}const me=_("all"),D=_(!0),_s=[{key:"all",label:"All"},{key:"heartbeat",label:"Heartbeat"},{key:"turn",label:"Turn"},{key:"tool",label:"Tool"},{key:"error",label:"Error"},{key:"lifecycle",label:"Lifecycle"}];function hs(e,s){if(s==="all")return!0;const t=e.eventType??"unknown";switch(s){case"heartbeat":return t==="keeper_heartbeat"||t==="oas_keeper_snapshot";case"turn":return t==="broadcast"||t==="board_post"||t==="board_comment";case"tool":return e.text.toLowerCase().includes("tool");case"error":return t==="keeper_guardrail"||e.text.toLowerCase().includes("error");case"lifecycle":return t==="agent_joined"||t==="agent_left"||t==="keeper_handoff"||t==="keeper_compaction";default:return!0}}function ys(e){switch(e){case"keeper_heartbeat":case"oas_keeper_snapshot":return"agent-event-badge--heartbeat";case"agent_joined":case"agent_left":return"agent-event-badge--lifecycle";case"keeper_handoff":case"keeper_compaction":return"agent-event-badge--keeper";case"keeper_guardrail":return"agent-event-badge--error";case"broadcast":return"agent-event-badge--broadcast";case"task_update":return"agent-event-badge--task";case"board_post":case"board_comment":return"agent-event-badge--board";default:return"agent-event-badge--default"}}function ks(e){switch(e){case"keeper_heartbeat":return"HB";case"oas_keeper_snapshot":return"OAS";case"agent_joined":return"JOIN";case"agent_left":return"LEFT";case"keeper_handoff":return"HAND";case"keeper_compaction":return"COMP";case"keeper_guardrail":return"GUARD";case"broadcast":return"CAST";case"task_update":return"TASK";case"board_post":return"POST";case"board_comment":return"CMNT";case"unknown":return"SYS";default:return"EVT"}}function ws(e,s=120){const t=(e??"").replace(/\s+/g," ").trim();return t?t.length>s?`${t.slice(0,s-1)}...`:t:""}function Cs(e){const s=e.toLowerCase();return lt.value.filter(t=>{const l=t.text.toLowerCase();return t.agent.toLowerCase()===s||l.includes(s)||l.includes(`@${s}`)}).slice(0,50)}function Ss({name:e}){const s=dt(null),t=Cs(e),l=Ne(()=>{const n=me.value;return t.filter(i=>hs(i,n))},[t,me.value]),r=Ne(()=>{const i=Date.now()-6e4;return t.filter(d=>d.timestamp>i).length},[t]);return O(()=>{D.value&&s.current&&(s.current.scrollTop=0)},[l.length]),a`
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <${as} chips=${_s} active=${me} />
        <div class="flex items-center gap-2 text-[11px]">
          <span class="px-2 py-0.5 rounded-lg bg-[var(--white-4)] border border-[var(--white-8)] text-[var(--text-muted)] text-[10px]">${r}/min</span>
          <span class="text-[var(--text-muted)]">${l.length} events</span>
          <button
            class="px-2 py-0.5 rounded-lg text-[10px] border cursor-pointer transition-all duration-150 ${D.value?"border-[rgba(34,197,94,0.4)] text-[var(--ok)] bg-[var(--white-4)]":"border-[var(--white-10)] text-[var(--text-dim)] bg-[var(--white-4)]"}"
            onClick=${()=>{D.value=!D.value}}
            title=${D.value?"Auto-scroll ON":"Auto-scroll OFF"}
          >
            ${D.value?"AUTO":"MANUAL"}
          </button>
        </div>
      </div>

      <div class="flex flex-col gap-0.5 max-h-[320px] overflow-y-auto" ref=${s}>
        ${l.length===0?a`<${h} message="필터에 맞는 이벤트 없음" compact />`:l.map((n,i)=>a`
              <div class="flex items-baseline gap-1.5 py-1 px-2 text-[13px] transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${i}>
                <span class="agent-event-badge ${ys(n.eventType)}">
                  ${ks(n.eventType)}
                </span>
                <span class="flex-1 text-[#c8daf7] truncate">${ws(n.text)}</span>
                ${n.timestamp?a`
                  <span class="text-[var(--text-dim)] text-[11px] whitespace-nowrap"><${I} timestamp=${n.timestamp} /></span>
                `:null}
              </div>
            `)}
      </div>
    </div>
  `}const V=_([]),Y=_(""),z=_(!1),X=_(""),Z=_("");let H=null;function As(e){return e.type==="TEXT_MESSAGE_CONTENT"||e.type==="TEXT_DELTA"}function Ts(e){const s=Q(e);if(s)return s;if(Be(e)){const t=Be(e.error)?e.error:null,l=Q(e.message)??Q(e.error)??Q(t==null?void 0:t.message)??Q(t==null?void 0:t.error);if(l)return l}return"Stream error"}function Is(){H&&(H.abort(),H=null,z.value=!1)}async function De(e){const s=Y.value.trim();if(!(!s||z.value)){Y.value="",Z.value="",X.value="",V.value=[...V.value,{role:"user",content:s,timestamp:Date.now()}],z.value=!0,H=new AbortController;try{await jt(e,s,void 0,{signal:H.signal,onEvent:t=>{if(As(t)&&t.delta)X.value+=t.delta;else if(t.type==="RUN_FINISHED"){const l=X.value.trim()||"(no response)";V.value=[...V.value,{role:"assistant",content:l,timestamp:Date.now()}],X.value=""}else t.type==="RUN_ERROR"&&(Z.value=Ts(t.value))}})}catch(t){if(t instanceof DOMException&&t.name==="AbortError")return;const l=t instanceof Error?t.message:"Chat failed";Z.value=l,be(l,"error")}finally{z.value=!1,H=null}}}function Ls({name:e}){const s=dt(null),t=V.value,l=X.value,r=z.value;return O(()=>{s.current&&(s.current.scrollTop=s.current.scrollHeight)},[t.length,l]),a`
    <div class="keeper-chat">
      <div class="keeper-chat__header flex items-center justify-between py-2.5 px-3.5">
        <span class="keeper-chat__title">@${e} 대화</span>
        ${r?a`
          <${J} variant="ghost" class="keeper-chat__cancel" onClick=${Is}>중단<//>
        `:null}
      </div>

      <div class="keeper-chat__messages flex-1 min-h-[200px] max-h-[400px] overflow-y-auto py-3 px-3.5 flex flex-col gap-3" ref=${s}>
        ${t.length===0&&!r?a`
          <div class="text-[var(--white-20)] text-[var(--fs-base)] text-center py-10">keeper에게 메시지를 보내세요</div>
        `:null}

        ${t.map((n,i)=>a`
          <div key=${i} class="keeper-chat__msg flex flex-col gap-[3px] max-w-[85%] keeper-chat__msg--${n.role} ${n.role==="user"?"self-end":"self-start"}">
            <span class="keeper-chat__role text-[var(--fs-2xs)] text-[var(--white-35)] uppercase tracking-[0.5px]">${n.role==="user"?"You":e}</span>
            <div class="keeper-chat__text rounded-lg">${n.content}</div>
          </div>
        `)}

        ${r&&l?a`
          <div class="keeper-chat__msg flex flex-col gap-[3px] max-w-[85%] keeper-chat__msg--assistant keeper-chat__msg--streaming self-start">
            <span class="keeper-chat__role text-[var(--fs-2xs)] text-[var(--white-35)] uppercase tracking-[0.5px]">${e}</span>
            <div class="keeper-chat__text rounded-lg">${l}<span class="keeper-chat__cursor">|</span></div>
          </div>
        `:r?a`
          <div class="keeper-chat__msg flex flex-col gap-[3px] max-w-[85%] keeper-chat__msg--assistant keeper-chat__msg--streaming self-start">
            <span class="keeper-chat__role text-[var(--fs-2xs)] text-[var(--white-35)] uppercase tracking-[0.5px]">${e}</span>
            <div class="keeper-chat__text rounded-lg keeper-chat__text--thinking">thinking...</div>
          </div>
        `:null}
      </div>

      ${Z.value?a`<div class="keeper-chat__error">${Z.value}</div>`:null}

      <div class="keeper-chat__input-row flex gap-2 py-2.5 px-3.5">
        <${pt}
          class="flex-1"
          placeholder="메시지 입력..."
          value=${Y.value}
          onInput=${n=>{Y.value=n.target.value}}
          onKeyDown=${n=>{n.key==="Enter"&&!n.shiftKey&&De(e)}}
          disabled=${r}
        />
        <${J}
          class="shrink-0"
          onClick=${()=>{De(e)}}
          disabled=${r||Y.value.trim()===""}
        >
          ${r?"...":"전송"}
        <//>
      </div>
    </div>
  `}const Es="masc_dashboard_agent_name",ie=_(!1),oe=_(""),he=_([]),ce=_([]),de=_(null),ye=_(null),ee=_(""),te=_(!1);function js(e){return q.value.find(s=>s.name===e)??null}function $t(e){return Kt.value.filter(s=>s.assignee===e)}function xt(e){return ve.value.find(s=>s.agent_name===e||s.name===e)??null}function Rs(e){const s=tt.value;return s?s.agent_briefs.find(t=>t.agent_name===e)??null:null}function Bs(e){return rt.value.find(s=>s.agent_name===e||s.name===e)??null}function Ms(e){return it.value.find(s=>s.name===e)??null}function ke(e,s=160){const t=(e??"").replace(/\s+/g," ").trim();return t?t.length>s?`${t.slice(0,s-1)}…`:t:null}async function we(e){ie.value=!0,oe.value="",he.value=[],ce.value=[],de.value=null,ye.value=null;try{const[s,t,l]=await Promise.all([Bt(80),Mt(e,4,20).catch(()=>null),Nt(e).catch(()=>null)]);ye.value=l,he.value=s.filter(n=>n.includes(e)).slice(0,20),de.value=t;const r=$t(e).slice(0,6);if(r.length>0){const n=await Promise.all(r.map(async i=>{try{const v=await Ot(i.id,25);return{taskId:i.id,text:v.trim()}}catch(v){const d=v instanceof Error?v.message:"load failed";return{taskId:i.id,text:`Failed: ${d}`}}}));ce.value=n}}catch(s){oe.value=s instanceof Error?s.message:"Failed to load profile"}finally{ie.value=!1}}async function Pe(e){var l;const s=ee.value.trim();if(!e||!s)return;const t=((l=localStorage.getItem(Es))==null?void 0:l.trim())||"dashboard";te.value=!0;try{await Pt(t,`@${e} ${s}`),ee.value="",be(`${e}에게 전송`,"success"),we(e)}catch(r){be(r instanceof Error?r.message:"Failed","error")}finally{te.value=!1}}function Fe(e){if(e==null)return"";const s=e*100;return s<50?"":s<70?"warn":"bad"}function Ns(e){switch(e){case"joined":return"참가";case"task_claimed":return"수임";case"task_started":return"시작";case"task_completed":return"완료";case"task_cancelled":return"취소";case"broadcast":return"방송";default:return e}}function Os({name:e}){const s=js(e),t=xt(e),l=Rs(e),r=Bs(e),n=Ms(e),i=(l==null?void 0:l.display_name)??(t==null?void 0:t.name)??e,v=(s==null?void 0:s.koreanName)??(t==null?void 0:t.koreanName),d=(t==null?void 0:t.status)??(s==null?void 0:s.status)??(l==null?void 0:l.status)??"unknown",x=(s==null?void 0:s.emoji)??(t==null?void 0:t.emoji),o=(l==null?void 0:l.current_work)??(s==null?void 0:s.current_task)??null,m=(s==null?void 0:s.last_seen)??(l==null?void 0:l.last_activity_at)??null,u=(t==null?void 0:t.last_turn_ago_s)??(l==null?void 0:l.last_activity_age_sec)??null,g=t==null?void 0:t.context_ratio,$=g!=null?Math.round(g*100):null,f=t==null?void 0:t.generation,b=t==null?void 0:t.autonomy_level,A=(s==null?void 0:s.model)??(t==null?void 0:t.model)??null,p=Dt(t==null?void 0:t.name,t==null?void 0:t.agent_name),c=l==null?void 0:l.signal_truth,L=ke(r==null?void 0:r.continuity_summary)??ke(r==null?void 0:r.skill_route_summary)??null,G=t!=null,Ee=n==null?void 0:n.state,je=n==null?void 0:n.focus,xe=de.value,E=xe==null?void 0:xe.summary;return a`
    <div class="ff-plate">
      <div class="flex flex-col items-center gap-1.5">
        <${at}
          name=${e}
          status=${d}
          traits=${s==null?void 0:s.traits}
          size="xl"
          currentWork=${o}
          activityAge=${u}
          signalTruth=${c}
        />
        ${G?a`<div class="text-[9px] font-bold tracking-[1.5px] text-[var(--ff-gold)] uppercase text-center">KEEPER</div>`:null}
      </div>

      <div class="flex flex-col gap-1.5 min-w-0">
        <div class="flex items-baseline gap-2 flex-wrap">
          <h2 class="m-0 text-[20px] text-[var(--ff-gold)] flex items-center gap-1.5">
            ${x?a`<span class="text-[1.4em]">${x}</span>`:""}
            ${i}
          </h2>
          ${v?a`<span class="text-base text-[var(--text-muted)]">(${v})</span>`:""}
          ${f!=null?a`<span class="text-sm font-bold text-[var(--accent)] bg-[var(--accent-10)] border border-[rgba(71,184,255,0.25)] px-1.5 py-px tabular-nums rounded">Lv.${f}</span>`:null}
        </div>

        <div class="flex items-center gap-1.5 flex-wrap">
          <${$e} status=${d} />
          ${A?a`<span class="font-[family-name:'IBM_Plex_Mono',monospace] text-[11px] text-[var(--text-muted)] bg-[var(--accent-8)] border border-[rgba(71,184,255,0.15)] px-[5px] py-px rounded">${A}</span>`:null}
          ${b?a`<span class="text-[11px] text-[var(--ff-gold)] bg-[var(--ff-gold-10)] border border-[var(--ff-gold-20)] px-[5px] py-px rounded">${b}</span>`:null}
          ${c?a`<span class="ff-plate__signal rounded ff-plate__signal--${c}">${c}</span>`:null}
        </div>

        ${$!=null?a`
          <div class="flex items-center gap-2 mt-0.5">
            <span class="text-[11px] font-bold text-[var(--ff-gold)] tracking-[1px] w-7">CTX</span>
            <div class="h-1.5 mt-1.5 rounded-full overflow-hidden bg-[var(--white-10)]" style="flex:1">
              <div class="h-full rounded-full transition-[width] duration-[250ms] ease-[ease] motion-reduce:transition-none ${Fe(g)==="warn"?"bg-linear-to-r from-[var(--warn)] to-[var(--warn-bright)]":Fe(g)==="bad"?"bg-linear-to-r from-[var(--bad)] to-[var(--warn-bright)]":"bg-linear-to-r from-[var(--accent)] to-[var(--ok)]"}" style=${{width:`${$}%`}}></div>
            </div>
            <span class="text-[13px] tabular-nums text-[var(--text-strong)] min-w-9 text-right">${$}%</span>
          </div>
        `:null}

        <div class="flex gap-2 items-center flex-wrap">
          ${o?a`<span class="text-base text-[#c8daf7]">${o}</span>`:a`<span class="text-base text-[#6b7fa0] italic">대기 중</span>`}
          ${Ee?a`<span class="text-[11px] text-[var(--accent)] bg-[var(--accent-8)] px-[5px] py-px rounded-[3px]">${Ee}</span>`:null}
          ${je?a`<span class="text-[11px] text-[#9ab3de]">${je}</span>`:null}
        </div>

        ${m||u!=null?a`
          <div class="flex gap-3 flex-wrap text-[13px] text-[var(--text-muted)]">
            ${m?a`<span>마지막 확인: <${I} timestamp=${m} /></span>`:null}
            ${u!=null?a`<span>${pe(u)} 전 활동</span>`:null}
          </div>
        `:null}

        ${p||L||l!=null&&l.related_session_id?a`
          <div class="flex gap-3 flex-wrap text-[13px] text-[var(--text-muted)]">
            ${p?a`<span>${p}</span>`:null}
            ${l!=null&&l.related_session_id?a`<span>세션 ${l.related_session_id}</span>`:null}
            ${L?a`<span>${L}</span>`:null}
          </div>
        `:null}
      </div>

      <div class="w-full mt-2">
        ${G?a`
          <${Oe} cols=${4} items=${[{label:"CTX",value:$!=null?`${$}%`:"N/A",variant:"gold"},{label:"세대",value:f??0,variant:"gold"},{label:"턴",value:t.turn_count??0,variant:"gold"},{label:"행동",value:t.autonomous_action_count??0,variant:"gold"}]} />
        `:a`
          <${Oe} cols=${4} items=${[{label:"완료",value:E?E.tasks_completed:"N/A",variant:"gold"},{label:"수임",value:E?E.tasks_claimed:"N/A",variant:"gold"},{label:"메시지",value:E?E.messages_sent:"N/A",variant:"gold"},{label:"활동",value:E&&E.active_duration_minutes>0?`${Math.round(E.active_duration_minutes)}m`:E?"0m":"N/A",variant:"gold"}]} />
        `}
      </div>
    </div>
  `}function Ks({name:e}){O(()=>{we(e)},[e]);const s=$t(e),t=he.value,l=de.value,r=xt(e),n=r!=null;return a`
    <div class="px-1 ${n?"ff-profile--keeper":""}">
      <div class="flex gap-2 mb-3">
        <${J} variant="ghost" onClick=${()=>se("status",{section:"agents"})}>← 목록<//>
        <${J} variant="ghost" onClick=${()=>{we(e)}} disabled=${ie.value}>
          ${ie.value?"...":"새로고침"}
        <//>
      </div>

      ${oe.value?a`<div class="council-error rounded-lg">${oe.value}</div>`:null}

      <${Os} name=${e} />

      <${bs} name=${e} />

      ${n&&r?a`
        <div class="ff-profile__keeper-panels">
          <${Rt} keeper=${r} />
        </div>
      `:null}

      <div class="grid grid-cols-2 gap-4 mb-4">
        ${n?null:a`
        <${k} title="태스크 (${s.length})" class="ff-card rounded-xl">
          ${s.length===0?a`<${h} message="할당된 태스크 없음" compact />`:a`<div class="flex flex-col gap-2">${s.map(i=>a`
                <div class="flex items-center gap-2 border border-[var(--card-border)] bg-[var(--white-3)] px-2.5 py-2 rounded-lg" key=${i.id}>
                  <span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${i.id}</span>
                  <span class="flex-1 text-[#d7e7ff]">${i.title}</span>
                  <${$e} status=${i.status} />
                </div>
              `)}</div>`}
        <//>
        `}

        ${(()=>{const i=ye.value;if(!i)return null;const v=i.collaborators??[],d=i.interests??[];return v.length>0||d.length>0?a`
            <${k} title="관계 (${v.length})" class="ff-card rounded-xl">
              ${v.length>0?a`
                <div class="flex flex-col gap-1">
                  ${v.map(o=>a`
                    <div class="flex items-center gap-2 px-2 py-1.5 transition-colors duration-150 hover:bg-[rgba(255,215,0,0.08)] rounded" key=${o.name}
                      onClick=${()=>se("status",{section:"agents",agent:o.name})}
                      style="cursor:pointer;"
                    >
                      <span class="text-[var(--ff-gold)] font-semibold text-base flex-1">${o.name}</span>
                      <span class="text-[var(--white-50)] text-[13px] tabular-nums">${o.collaborations}회</span>
                      ${o.last_collab?a`<span class="ff-relation-time"><${I} timestamp=${o.last_collab} /></span>`:null}
                    </div>
                  `)}
                </div>
              `:null}
              ${d.length>0?a`
                <div class="border-t border-[var(--white-6)] pt-2 mt-2">
                  <span class="ff-interests-label">관심사</span>
                  <div class="flex flex-wrap gap-1 mt-1.5">
                    ${d.slice(0,12).map(o=>a`<span class="bg-[rgba(255,215,0,0.1)] text-[var(--white-70)] px-2 py-0.5 rounded-[3px] text-[11px] border border-[rgba(255,215,0,0.15)]" key=${o}>${o}</span>`)}
                    ${d.length>12?a`<span class="bg-[rgba(255,215,0,0.1)] text-[var(--white-70)] px-2 py-0.5 rounded-[3px] text-[11px] border border-[rgba(255,215,0,0.15)]">+${d.length-12}</span>`:null}
                  </div>
                </div>
              `:null}
            <//>
          `:null})()}

        <${k} title="타임라인" class="ff-card rounded-xl">
          ${!l||(l.events??[]).length===0?a`<${h} message="이벤트 없음" compact />`:a`<div class="flex flex-col gap-0.5 max-h-[300px] overflow-y-auto">${(l.events??[]).map((i,v)=>{const d=i.detail,x=d.title??d.content??"";return a`
                  <div class="agent-timeline-event flex items-baseline gap-1.5 py-1 px-2 text-[13px] transition-[background] duration-100 rounded hover:bg-[var(--white-4)]" key=${v}>
                    <span class="text-[11px] font-semibold text-[var(--ff-gold)] min-w-8">${Ns(i.type)}</span>
                    ${x?a`<span class="flex-1 text-[13px] text-[#c8daf7]">${ke(x,80)}</span>`:null}
                    ${i.ts?a`<${I} timestamp=${i.ts} />`:null}
                  </div>
                `})}</div>`}
        <//>

        <${k} title="실시간" class="ff-card rounded-xl">
          <${Ss} name=${e} />
        <//>

        <${k} title="Room 활동" class="ff-card rounded-xl">
          ${t.length===0?a`<${h} message="관련 활동 없음" compact />`:a`<div class="max-h-[210px] overflow-y-auto flex flex-col gap-1.5">${t.map((i,v)=>a`<div key=${v} class="border border-[var(--card-border)] bg-[var(--white-3)] px-2.5 py-2 font-[family-name:'IBM_Plex_Mono','Fira_Code',monospace] text-[13px] text-[#c8daf7] leading-[1.4] rounded-lg">${i}</div>`)}</div>`}
        <//>

        ${ce.value.length>0?a`
          <${k} title="태스크 이력" class="ff-card rounded-xl col-span-full">
            <div class="agent-history-list">${ce.value.map(i=>a`
              <div class="border border-[var(--card-border)] rounded-[10px] bg-[var(--white-2)] p-2.5" key=${i.taskId}>
                <div class="mb-2"><span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${i.taskId}</span></div>
                <pre class="m-0 whitespace-pre-wrap text-[13px] leading-[1.5] text-[#cfe0ff] font-[family-name:'IBM_Plex_Mono','Fira_Code',monospace]">${i.text||"No history yet"}</pre>
              </div>
            `)}</div>
          <//>
        `:null}
      </div>

      ${n?a`
        <${Ls} name=${e} />
      `:a`
        <div class="flex gap-2 items-center px-3.5 py-2.5 bg-[rgba(10,22,40,0.8)] border border-[var(--ff-gold-15)] rounded-lg">
          <span class="text-[13px] font-semibold text-[var(--ff-gold)] whitespace-nowrap">@${e}</span>
          <${pt}
            placeholder="메시지 입력..."
            value=${ee.value}
            onInput=${i=>{ee.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&Pe(e)}}
            disabled=${te.value}
          />
          <${J}
            onClick=${()=>{Pe(e)}}
            disabled=${te.value||ee.value.trim()===""}
          >
            ${te.value?"...":"전송"}
          <//>
        </div>
      `}
    </div>
  `}function He({item:e,selected:s}){const t=Te(e.status);return a`
    <button
      class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer ${s?"active":""} ${t?"terminated":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{M.value=s?null:e.id,j.value=null,R.value=null}}
    >
      <div class="flex justify-between gap-2 items-start flex-wrap">
        <div>
          <div class="text-[var(--text-muted)] text-[13px]">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card rounded-xl-title">${e.summary}</div>
        </div>
        <${S} label=${C(e.status??e.severity)} tone=${t?"muted":w(e.severity)} />
      </div>
      <div class="mission-card rounded-xl-meta">
        <span>${Jt(e.kind)}</span>
        ${e.linked_operation_id?a`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?a`<span><${I} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${Ie}
        intervene=${t?null:e.intervene_handoff}
        command=${e.command_handoff}
      />
    </button>
  `}function Ds({queueRows:e}){const[s,t]=Ae(e,n=>n.status),l=s.length>0,r=t.length>0;return a`
    <div class="mb-4">
      <h2 class="monitor-headline">개입이 필요한 실행</h2>
      <p class="monitor-subheadline">진행 중인 세션과 작전 중 막힌 항목을 보여줍니다.${r?" 종료된 항목은 하단에 접혀 있습니다.":""}</p>
    </div>
    <div class="flex flex-col gap-3">
      ${l?s.map(n=>a`<${He} key=${n.id} item=${n} selected=${M.value===n.id} />`):a`<${h} message="지금은 개입이 필요한 실행이 없습니다." compact />`}
    </div>
    ${r?a`
          <details class="mt-1" data-testid="execution.queue-terminal">
            <summary class="runtime-summary">종료된 항목 ${t.length}건</summary>
            <div class="flex flex-col gap-3">
              ${t.map(n=>a`<${He} key=${n.id} item=${n} selected=${M.value===n.id} />`)}
            </div>
          </details>
        `:null}
  `}function qe({brief:e,selected:s}){const t=Te(e.status),l=e.active_count??0,r=e.seen_count??l,n=e.planned_count??e.member_names.length;return a`
    <button
      class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer ${s?"active":""} ${t?"terminated":""}"
      data-testid="execution.session-card"
      onClick=${()=>{j.value=s?null:e.session_id,R.value=null}}
    >
      <div class="flex justify-between gap-2 items-start flex-wrap">
        <div>
          <div class="text-[var(--text-muted)] text-[13px]">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card rounded-xl-title">${e.goal}</div>
        </div>
        <${S} label=${C(e.status)} tone=${t?"muted":w(e.health??e.status)} />
      </div>
      <div class="mission-card rounded-xl-meta">
        <span>건강도 · ${C(e.health??"ok")}</span>
        <span>live ${l} · seen ${r} · planned ${n}</span>
        ${e.linked_operation_id?a`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?a`<span><${I} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?a`<div class="mission-card rounded-xl-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?a`<div class="mission-card rounded-xl-detail">${e.last_activity_summary}</div>`:null}
      <div class="monitor-footnote">
        ${e.worker_gap_summary??`관측 기준 · ${e.counts_basis??"recent_turns"}`}
      </div>
      <${Ie}
        intervene=${t?null:e.intervene_handoff}
        command=${e.command_handoff}
      />
    </button>
  `}function Ps({sessionRows:e}){const[s,t]=Ae(e,n=>n.status),l=s.length>0,r=t.length>0;return a`
    <div class="mb-4">
      <h2 class="monitor-headline">영향받는 세션</h2>
      <p class="monitor-subheadline">대기열에서 고른 실행이 어떤 세션 목표와 실행 막힘을 갖는지 요약합니다.</p>
    </div>
    <div class="flex flex-col gap-3">
      ${l?s.map(n=>a`<${qe} key=${n.session_id} brief=${n} selected=${j.value===n.session_id} />`):a`<${h} message=${r?"진행 중인 세션이 없습니다.":"선택된 실행과 연결된 세션이 없습니다."} compact />`}
    </div>
    ${r?a`
          <details class="mt-1" data-testid="execution.sessions-terminal">
            <summary class="runtime-summary">종료된 세션 ${t.length}건</summary>
            <div class="flex flex-col gap-3">
              ${t.map(n=>a`<${qe} key=${n.session_id} brief=${n} selected=${j.value===n.session_id} />`)}
            </div>
          </details>
        `:null}
  `}function Ge({brief:e,selected:s}){const t=Te(e.status);return a`
    <button
      class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer ${s?"active":""} ${t?"terminated":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{R.value=s?null:e.operation_id,j.value=e.linked_session_id??null}}
    >
      <div class="flex justify-between gap-2 items-start flex-wrap">
        <div>
          <div class="text-[var(--text-muted)] text-[13px]">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card rounded-xl-title">${e.objective}</div>
        </div>
        <${S} label=${C(e.status)} tone=${t?"muted":w(e.blocker_summary?"warn":e.status)} />
      </div>
      <div class="mission-card rounded-xl-meta">
        ${e.stage?a`<span>단계 · ${e.stage}</span>`:null}
        ${e.linked_session_id?a`<span>세션 · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?a`<span><${I} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?a`<div class="mission-card rounded-xl-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?a`<div class="monitor-footnote">다음 도구 · ${e.next_tool}</div>`:null}
      <${Ie} command=${e.command_handoff} />
    </button>
  `}function Fs({operationRows:e}){const[s,t]=Ae(e,n=>n.status),l=s.length>0,r=t.length>0;return a`
    <div class="mb-4">
      <h2 class="monitor-headline">영향받는 작전</h2>
      <p class="monitor-subheadline">지휘 평면 작전의 막힘과 다음 도구만 얇게 보여주고, 자세한 근거는 원인 화면으로 넘깁니다.</p>
    </div>
    <div class="flex flex-col gap-3">
      ${l?s.map(n=>a`<${Ge} key=${n.operation_id} brief=${n} selected=${R.value===n.operation_id} />`):a`<${h} message=${r?"진행 중인 작전이 없습니다.":"선택된 실행과 연결된 작전이 없습니다."} compact />`}
    </div>
    ${r?a`
          <details class="mt-1" data-testid="execution.operations-terminal">
            <summary class="runtime-summary">종료된 작전 ${t.length}건</summary>
            <div class="flex flex-col gap-3">
              ${t.map(n=>a`<${Ge} key=${n.operation_id} brief=${n} selected=${R.value===n.operation_id} />`)}
            </div>
          </details>
        `:null}
  `}function Hs({ratio:e,size:s=40,stroke:t=4}){if(e==null)return null;const l=(s-t)/2,r=s/2,n=2*Math.PI*l,i=n*((100-e*100)/100);let v="mitosis-safe";return e>=.8?v="mitosis-critical":e>=.5&&(v="mitosis-warn"),a`
    <div class="relative inline-flex items-center justify-center ml-auto mr-2.5" title="Mitosis Context Load: ${Math.round(e*100)}%">
      <svg class="mitosis-ring" width="${s}" height="${s}" viewBox="0 0 ${s} ${s}">
        <circle class="mitosis-ring-bg" cx="${r}" cy="${r}" r="${l}" stroke-width="${t}" />
        <circle 
          class="mitosis-ring-fg ${v}" 
          cx="${r}" cy="${r}" r="${l}" 
          stroke-width="${t}" 
          stroke-dasharray="${n}" 
          stroke-dashoffset="${i}" 
        />
      </svg>
      <span class="absolute text-[0.65rem] font-bold ${v}">${Math.round(e*100)}%</span>
    </div>
  `}function qs(e){return typeof e!="number"||Number.isNaN(e)?"N/A":`${Math.round(e*100)}%`}function Ue(e,s="없음"){return!e||e.length===0?s:e.slice(0,4).join(", ")}function Gs({model:e,onClick:s,variant:t,testId:l}){var d,x,o,m;const r=!!e.recentEvent||!!e.recentInput||!!e.recentOutput||!!e.routeSummary||!!e.auditSource||!!e.auditAt||(((d=e.recentTools)==null?void 0:d.length)??0)>0||(((x=e.allowedTools)==null?void 0:x.length)??0)>0,n=e.tone??"",i=t==="mission"?`w-full p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 text-inherit text-left cursor-pointer ${n}`:"keeper-canonical-card",v=t==="mission"?"w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer":`monitor-row p-4 ${n}${e.stateClass?` state-${e.stateClass}`:""}${e.stateClass==="offline"?" opacity-35 border-[rgba(85,85,85,0.15)] bg-[rgba(0,0,0,0.08)] hover:opacity-55":""}`;return a`
    <article class=${i}>
      <button class=${v} data-testid=${l} onClick=${s}>
        <div class=${t==="mission"?"flex justify-between gap-3 items-start":"monitor-row-header"}>
          <div class=${t==="mission"?"flex gap-3 items-start":"min-w-0"}>
            <span class="agent-emoji ${e.stateClass==="offline"?"grayscale":""}">${e.emoji??""}</span>
            <div>
              <div class=${t==="mission"?"":"monitor-name-line"}>
                <strong class=${t==="mission"?"":"monitor-title"}>${e.name}</strong>
                ${e.koreanName?a`<span class=${t==="mission"?"":"monitor-sub"}>${e.koreanName}</span>`:null}
              </div>
              ${e.runtimeLabel?a`<div class=${t==="mission"?"":"monitor-sub"}>${e.runtimeLabel}</div>`:null}
              ${e.note?a`<div class=${t==="mission"?"":"monitor-note"}>${e.note}</div>`:null}
            </div>
          </div>
          ${t==="execution"?a`
                <${Hs} ratio=${e.contextRatio??0} size=${34} stroke=${4} />
                <${$e} status=${e.statusRaw??"unknown"} />
                ${e.pipelineStage?a`<${nt} stage=${e.pipelineStage} />`:null}
                ${e.stateLabel?a`<span class="monitor-pill ${n} inline-flex items-center rounded-full px-2 py-[3px] text-[length:var(--fs-xs)] uppercase tracking-[0.06em]">${e.stateLabel}</span>`:null}
              `:a`<${S} label=${e.statusLabel} tone=${n} />`}
        </div>

        <div class=${t==="mission"?"flex flex-wrap gap-3 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]":"monitor-meta"}>
          ${e.lastActivityAt?a`<span>최근 활동 <${I} timestamp=${e.lastActivityAt} /></span>`:a`<span>${e.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${e.relatedSessionId?a`<span>세션 · ${e.relatedSessionId}</span>`:null}
          ${e.continuity?a`<span>${e.continuity}</span>`:null}
          ${e.lifecycle?a`<span>생애주기 ${e.lifecycle}</span>`:null}
          <span>컨텍스트 ${qs(e.contextRatio)}</span>
        </div>

        <div class=${t==="mission"?"grid gap-1.5":"monitor-focus"}>
          ${t==="mission"?a`
                <span>무엇을</span>
                <strong>${e.focus}</strong>
              `:a`${e.focus}`}
        </div>

        ${e.summary?a`<div class=${t==="mission"?"grid gap-1.5":"monitor-footnote"}>${e.summary}</div>`:null}
      </button>

      ${r?a`
            <details class="pt-3 border-t border-[var(--white-6)] mt-4">
              <summary>${e.disclosureLabel??"세부 정보"}</summary>
              <div class="flex flex-wrap gap-3 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]">
                ${e.recentEvent?a`<span>최근 일 · ${e.recentEvent}</span>`:null}
                ${e.routeSummary?a`<span>route · ${e.routeSummary}</span>`:null}
                ${e.auditSource?a`<span>audit · ${e.auditSource}</span>`:null}
                ${e.auditAt?a`<span><${I} timestamp=${e.auditAt} /></span>`:null}
              </div>
              ${e.recentInput||e.recentOutput?a`
                    <div class="grid grid-cols-2 gap-3">
                      <${y} label="최근 입력" value=${e.recentInput??"표시 가능한 최근 입력이 없습니다"} bg="white-3" />
                      <${y} label="최근 응답" value=${e.recentOutput??"표시 가능한 최근 응답이 없습니다"} bg="white-3" />
                    </div>
                  `:null}
              ${(((o=e.recentTools)==null?void 0:o.length)??0)>0||(((m=e.allowedTools)==null?void 0:m.length)??0)>0?a`
                    <div class="flex flex-wrap gap-3 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]">
                      <span>최근 도구 · ${Ue(e.recentTools)}</span>
                      <span>허용 도구 · ${Ue(e.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}function We({row:e,testId:s}){const t=e.state==="offline"?"offline":e.status??"unknown";return a`
    <button class="monitor-row rounded-xl p-4 ${e.tone} state-${e.state} ${e.state==="offline"?"opacity-35 border-[rgba(85,85,85,0.15)] bg-[rgba(0,0,0,0.08)] hover:opacity-55":""}" data-testid=${s} onClick=${()=>K(e.name)}>
      <div class="monitor-row rounded-xl-header">
        <span class="agent-emoji ${e.state==="offline"?"grayscale":""}">${e.emoji??""}</span>
        <div class="min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?a`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${$e} status=${t} />
        ${e.state!=="offline"||t!=="offline"?a`<span class="monitor-pill ${e.tone} state-${e.state} inline-flex items-center rounded-full px-2 py-[3px] text-[11px] uppercase tracking-[0.06em] ${e.state==="offline"?"bg-[rgba(85,85,85,0.2)] text-[var(--text-dim)] line-through":""}">${Yt(e.state)}</span>`:null}
      </div>

      <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]">
        ${e.last_signal_at?a`<span>신호 <${I} timestamp=${e.last_signal_at} /></span>`:a`<span>최근 신호 없음</span>`}
        <span>${zt(e.signal_truth)} · ${Zt(e.evidence_source)}</span>
        ${typeof e.last_signal_age_sec=="number"?a`<span>${e.last_signal_age_sec}s ago</span>`:null}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?a`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?a`<span>작전 · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?a`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function Us({row:e}){const s=es(e),t=()=>{Je(s)},l=Ft(e.name,e.agent_name),r={name:e.name,koreanName:e.korean_name??null,runtimeLabel:l,emoji:e.emoji??null,tone:e.tone,statusRaw:e.status??null,statusLabel:C(e.status),stateClass:e.state,stateLabel:ts(e.state),pipelineStage:s.pipeline_stage??null,contextRatio:e.context_ratio??null,note:e.note,focus:e.focus,lastActivityAt:e.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:e.related_session_id??null,continuity:e.continuity??null,lifecycle:e.lifecycle??null,summary:e.continuity_summary??e.recent_output_preview??null,recentInput:e.recent_input_preview??null,recentOutput:e.recent_output_preview??null,recentTools:e.recent_tool_names??[],allowedTools:e.allowed_tool_names??[],routeSummary:e.skill_route_summary??null,auditSource:e.tool_audit_source??null,auditAt:e.tool_audit_at??null,disclosureLabel:"연속성 상세"};return a`<${Gs}
    variant="execution"
    model=${r}
    onClick=${t}
    testId="execution.continuity-card"
  />`}function Ws(){const e=Ht.value,s=qt.value,t=Gt.value,l=it.value,r=rt.value,n=Ut.value,i=M.value&&e.some(p=>p.id===M.value)?M.value:null,v=j.value&&s.some(p=>p.session_id===j.value)?j.value:null,d=R.value&&t.some(p=>p.operation_id===R.value)?R.value:null;O(()=>{M.value!==i&&(M.value=i),j.value!==v&&(j.value=v),R.value!==d&&(R.value=d)},[i,v,d]);const x=i?e.find(p=>p.id===i)??null:null,o=v||(x?x.kind==="session"?x.target_id:x.linked_session_id??null:null),m=d||(x?x.kind==="operation"?x.target_id:x.linked_operation_id??null:null),u=o?s.filter(p=>p.session_id===o):m?s.filter(p=>p.linked_operation_id===m):s,g=m?t.filter(p=>p.operation_id===m):o?t.filter(p=>{var c;return p.linked_session_id===o||p.operation_id===((c=u[0])==null?void 0:c.linked_operation_id)}):t,$=o||m?l.filter(p=>(o?p.related_session_id===o:!1)||(m?p.related_operation_id===m:!1)):l,f=o?r.filter(p=>p.related_session_id===o||p.tone!=="ok"):r,b=o||m?n.filter(p=>(o?p.related_session_id===o:!1)||(m?p.related_operation_id===m:!1)||p.tone!=="ok"):n,A=Wt.value&&e.length===0&&s.length===0&&t.length===0;return a`
    <div class="flex flex-col gap-5">
      <${ss} />
      <${k}
        title="주의 항목"
        class="section mb-4"
       
        testId="execution.queue"
      >
        ${A?a`
              <div class="text-center border border-dashed border-[var(--ok-30)] rounded-[10px] py-[22px] px-4 text-[var(--text-muted)]" data-testid="execution.all-clear">
                정상 운영 중. 주의가 필요한 항목이 없습니다.
              </div>
            `:a`<${Ds} queueRows=${e} />`}
      <//>

      <div class="grid grid-cols-[minmax(0,1.08fr)_minmax(0,0.96fr)_minmax(0,0.88fr)] gap-4">
        <${k}
          title="관련 세션"
          class="section mb-4"
         
          testId="execution.session-briefs"
        >
          <${Ps} sessionRows=${u} />
        <//>

        <${k}
          title="관련 작업"
          class="section mb-4"
         
          testId="execution.operation-briefs"
        >
          <${Fs} operationRows=${g} />
        <//>

        <${k}
          title="참여 에이전트"
          class="section mb-4"
         
          testId="execution.worker-support"
        >
          <div class="flex flex-col gap-3">
            ${$.length===0?a`<${h} message="참여 에이전트가 없습니다." compact />`:$.map(p=>a`<${We} key=${p.name} row=${p} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${k}
          title="키퍼 연속성"
          class="section mb-4"
         
          testId="execution.continuity"
        >
          <div class="flex flex-col gap-3">
            ${f.length===0?a`<${h} message="연속성 경고 없음" compact />`:f.map(p=>a`<${Us} key=${p.name} row=${p} />`)}
          </div>
        <//>

        <${k}
          title="오프라인 에이전트"
          class="section mb-4"
         
          testId="execution.offline-workers"
        >
          <div class="flex flex-col gap-3">
            ${b.length===0?a`<${h} message="오프라인 에이전트 없음" compact />`:b.map(p=>a`<${We} key=${p.name} row=${p} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const le=_("all");function Qs(){const e=new Set;for(const s of ve.value){const t=s.name??s.agent_name;t&&e.add(t)}for(const s of st.value){const t=s.name??s.agent_name;t&&e.add(t)}return e}const Vs=[{id:"all",label:"전체"},{id:"agents",label:"에이전트"},{id:"keepers",label:"키퍼"},{id:"sessions",label:"실행"}];function Xs(){const e=_e.value.params.agent;if(e)return a`<${Ks} name=${e} />`;const s=_e.value.params.view,t=s==="sessions"||s==="keepers"||s==="agents"?s:null,l=t??le.value;O(()=>{t&&le.value!==t&&(le.value=t)},[t]);const r=Qs(),n=q.value,i=n.length,v=n.filter(o=>r.has(o.name)).length,d=i-v;function x(o){return o==="all"?i:o==="agents"?d:o==="keepers"?v:null}return a`
    <div class="flex flex-col gap-4">
      <div class="flex gap-1 p-1 bg-[var(--white-3)] rounded-lg w-fit">
        ${Vs.map(o=>a`
          <button
            key=${o.id}
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all cursor-pointer border-0 ${l===o.id?"bg-[var(--accent-soft)] text-[var(--accent)]":"bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)]"}"
            onClick=${()=>{le.value=o.id,se("status",o.id==="all"?{section:"agents"}:{section:"agents",view:o.id})}}
          >
            ${o.label}
            ${x(o.id)!=null?a`<${re}>${x(o.id)}<//>`:null}
          </button>
        `)}
      </div>

      ${l==="sessions"?a`<${Ws} />`:a`<${ms}
            keeperFilter=${l==="keepers"?"keeper-only":l==="agents"?"agent-only":"all"}
          />`}
    </div>
  `}const ue=_(new Set(["broadcast","tasks","keepers","system"]));function Js(e){const s=new Set(ue.value);s.has(e)?s.delete(e):s.add(e),ue.value=s}_(null);function Ys(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const zs=Se(()=>{const e=ue.value;return lt.value.filter(s=>e.has(Ys(s)))}),Zs=12e4,ea=Se(()=>{const e=ot.value,s=Date.now();return q.value.map(t=>{const l=t.name.trim().toLowerCase(),r=e.get(l)??null;let n="idle";if(t.status==="active"||t.status==="busy"){const i=r==null?void 0:r.lastActivityAt;i?n=s-new Date(i).getTime()>Zs?"stale":"working":n="working"}else(t.status==="offline"||t.status==="inactive")&&(n="stale");return{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,state:n,currentTask:t.current_task,motion:r}})}),ta=Se(()=>{const e=ot.value;return q.value.filter(s=>s.status==="active"||s.status==="busy"||s.status==="listening"||s.status==="idle").map(s=>{const t=s.name.trim().toLowerCase(),l=e.get(t),r=(l==null?void 0:l.activeAssignedCount)??0;let n="calm";return r>=3?n="hot":r>=1&&(n="normal"),{name:s.name,emoji:s.emoji??"",koreanName:s.koreanName??null,currentTask:s.current_task,lastActivityAt:(l==null?void 0:l.lastActivityAt)??null,lastActivityText:(l==null?void 0:l.lastActivityText)??null,assignedCount:r,pressure:n}}).sort((s,t)=>{const l={hot:0,normal:1,calm:2};return l[s.pressure]-l[t.pressure]})});function Qe(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function sa(e){const s=e.eventType;return s==="broadcast"?"broadcast":s==="agent_joined"?"joined":s==="agent_left"?"left":s==="task_update"?"task":s==="board_post"?"post":s==="board_comment"?"comment":s==="keeper_heartbeat"?"heartbeat":s==="keeper_handoff"?"handoff":s==="keeper_compaction"?"compact":s==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function aa(e){switch(e){case"working":return"pulse-working";case"stale":return"border-[rgba(239,68,68,0.3)] opacity-60";default:return"border-[var(--white-10)]"}}function na(){const e=ea.value,s=ct.value;return e.length===0?a`
      <div class="pulse-strip rounded-xl">
        <span class="text-[rgba(255,255,255,0.3)] text-[13px]">연결된 에이전트 없음</span>
      </div>
    `:a`
    <div class="pulse-strip rounded-xl">
      ${e.map(t=>a`
        <button
          key=${t.name}
          class="pulse-bubble ${aa(t.state)} ${s===t.name?"pulse-selected":""}"
          onClick=${()=>K(t.name)}
          title="${t.koreanName?`${t.name} (${t.koreanName})`:t.name}${t.currentTask?` — ${t.currentTask}`:""}"
        >
          <span class="text-[1.15rem] leading-none">${t.emoji||t.name.charAt(0).toUpperCase()}</span>
          <span class="text-[0.65rem] text-[var(--white-55)] whitespace-nowrap overflow-hidden text-ellipsis max-w-[64px]">${t.koreanName??t.name}</span>
        </button>
      `)}
    </div>
  `}const la=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function ra(){const e=ue.value;return a`
    <div class="flex gap-1.5">
      ${la.map(s=>a`
        <button
          key=${s.kind}
          class="px-2 py-0.5 text-[11px] rounded-md border cursor-pointer transition-all duration-150 ${e.has(s.kind)?"border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]":"border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)]"}"
          onClick=${()=>Js(s.kind)}
        >
          ${s.label}
        </button>
      `)}
    </div>
  `}function ia(){const e=zs.value;return a`
    <div class="grid gap-3 grid-rows-[auto_auto_1fr] min-h-0">
      <div class="activity-stream-head">
        <h3 class="m-0 text-[0.95rem] font-semibold">Activity Stream</h3>
        <span class="text-xs text-[rgba(255,255,255,0.4)]">${e.length} events</span>
      </div>
      <${ra} />
      <div class="activity-stream-list">
        ${e.length===0?a`<div class="py-6 text-center text-[var(--white-25)] text-[13px]">필터에 맞는 이벤트 없음</div>`:e.map((s,t)=>a`
            <div
              key=${`${s.timestamp}-${t}`}
              class="activity-item rounded-lg ${Qe(s)} ${t===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip rounded ${Qe(s)}">${sa(s)}</span>
                <span class="text-[0.75rem] text-[var(--white-60)] font-medium">${s.agent}</span>
                <span class="text-[0.7rem] text-[var(--white-30)] ml-auto">${Qt(s.timestamp)}</span>
              </div>
              <div class="text-[13px] text-[var(--white-70)] leading-[1.4] break-words">${s.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function oa(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function ca(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function da(){const e=ta.value,s=ct.value;return a`
    <div class="grid gap-3 grid-rows-[auto_1fr] min-h-0">
      <div class="focus-sidebar-head">
        <h3 class="m-0 text-[0.95rem] font-semibold">Agents</h3>
        <span class="text-xs text-[rgba(255,255,255,0.4)]">${e.length} active</span>
      </div>
      <div class="grid gap-1.5 content-start overflow-y-auto max-h-[560px] pr-1">
        ${e.length===0?a`<div class="py-6 text-center text-[var(--white-25)] text-[13px]">No active agents</div>`:e.map(t=>a`
            <div
              key=${t.name}
              class="focus-agent-card transition-colors duration-200 ${s===t.name?"focus-agent-selected":""}"
              onClick=${()=>K(t.name)}
            >
              <div class="focus-agent-header">
                <span class="text-[0.85rem] font-medium flex items-center gap-1">
                  ${t.emoji?a`<span class="text-[0.95rem]">${t.emoji}</span>`:null}
                  ${t.koreanName??t.name}
                </span>
                <span class="focus-pressure-badge rounded-md ${oa(t.pressure)}">
                  ${ca(t.pressure)}
                  ${t.assignedCount>0?a` <span class="bg-[var(--white-10)] px-1 text-[0.6rem] rounded">${t.assignedCount}</span>`:null}
                </span>
              </div>
              ${t.currentTask?a`<div class="text-[0.75rem] text-[var(--white-55)] py-[3px] px-2 bg-[var(--white-3)] border border-[var(--white-5)] whitespace-nowrap overflow-hidden text-ellipsis rounded-md">${t.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${t.lastActivityText?a`<span class="text-[11px] text-[var(--white-40)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0">${t.lastActivityText}</span>`:a`<span class="text-[11px] text-[var(--white-40)] whitespace-nowrap overflow-hidden text-ellipsis flex-1 min-w-0 italic text-[rgba(255,255,255,0.25)]">No recent activity</span>`}
                ${t.lastActivityAt?a`<${I} timestamp=${t.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function ua(){const e=Vt.value;return a`
    <div class="grid gap-4">
      <div class="live-header">
        <h2 class="m-0 text-[1.25rem] font-semibold">라이브 모니터</h2>
        <div class="flex gap-3 items-center text-[13px] text-[var(--white-50)]">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${q.value.length}</span>
          <span class="live-stat">이벤트 ${Xt.value}</span>
        </div>
      </div>

      <${na} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${ia} />
        </div>
        <div class="live-panel-side">
          <${da} />
        </div>
      </div>
    </div>
  `}function pa({title:e,open:s,id:t,class:l,badge:r,children:n}){return a`
    <details open=${s} id=${t} class="rounded-lg border border-[var(--card-border)] overflow-hidden ${l??""}">
      <summary class="flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)] select-none hover:bg-[var(--white-3)] transition-colors list-none">
        ${e}
        ${r??null}
      </summary>
      <div class="p-4 pt-0">
        ${n}
      </div>
    </details>
  `}const va=_(!1);function $a(){return a`
    <div class="flex flex-col gap-4">
      <${ua} />
      <${pa}
        title="활동 그래프"
        open=${va.value}
      >
        <${ns} />
      <//>
    </div>
  `}function xa(){const e=_e.value.params.section;return e==="agents"||e==="activity"?e:"sessions"}function Ca(){const e=xa();return a`
    <div class="flex flex-col gap-6">
      <div class="transition-opacity duration-300">
        ${e==="agents"?a`<${Xs} />`:e==="activity"?a`<${$a} />`:a`<${vs} />`}
      </div>
    </div>
  `}export{Ca as Status};
