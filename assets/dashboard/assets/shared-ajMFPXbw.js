import{m as s,i as f,j as g,k as l,l as $,A as u,n as k,p as h,q as v,w,s as b}from"./index-BB0zaaHQ.js";import{S as d}from"./status-chip-B-Vgmq3f.js";import{t as _}from"./input-DWPrIiMN.js";import{c}from"./vendor-Chwn_OlE.js";function p(e){return(e??"").trim().toLowerCase()}function S(e){switch(p(e)){case"truth":return"ok";case"recorded":return"";case"derived":case"fallback":case"narrative":case"judgment":return"warn";default:return""}}function i(e){const t=(e.label??"").trim();return t||p(e.kind)||"unknown"}function x({item:e}){const t=i(e),n=S(e.kind);return s`<${d} label=${t} tone=${n} />`}function A({items:e,className:t="mission-briefing-meta",testId:n}){const r=e.filter(a=>i(a).trim().length>0);return r.length===0?null:s`
    <div class=${t} data-testid=${n}>
      ${r.map((a,o)=>s`<${x} key=${`${i(a)}-${o}`} item=${a} />`)}
    </div>
  `}function B(){var o;const e=f.value;if(!e)return g.value?s`<section class="room-truth-strip room-truth-strip-loading">불러오는 중...</section>`:l.value?s`<section class="room-truth-strip room-truth-strip-error">${l.value}</section>`:null;const t=e.room.status,n=e.room.counts,r=(o=e.execution)==null?void 0:o.summary,a=(r==null?void 0:r.blocked_sessions)??0;return s`
    <section class="grid grid-cols-[repeat(auto-fit,minmax(220px,1fr))] gap-3 mb-4">
      <article class="room-truth-card rounded-xl">
        <span class="room-truth-label">현황</span>
        <strong>에이전트 ${(n==null?void 0:n.agents)??0} · 태스크 ${(n==null?void 0:n.tasks)??0} · 키퍼 ${(n==null?void 0:n.keepers)??0}</strong>
        <p>${(t==null?void 0:t.project)??"project"} · ${t!=null&&t.paused?"일시정지":"활성"}</p>
      </article>

      <article class="room-truth-card rounded-xl">
        <span class="room-truth-label">세션</span>
        <strong>활성 ${(r==null?void 0:r.active_sessions)??0} · 막힘 ${a}</strong>
        <div class="flex flex-wrap gap-2">
          <${d} label=${`우선 ${(r==null?void 0:r.priority_items)??0}`} tone=${_(a>0?"warn":"ok")} />
        </div>
      </article>
    </section>
  `}const E=c(null),K=c(null),H=c(null),T=new Set(["completed","interrupted","failed","cancelled"]);function L(e){return T.has((e??"").trim().toLowerCase())}function R(e,t){const n=[],r=[];for(const a of e)(L(t(a))?r:n).push(a);return[n,r]}function z(e){return e==="session"?"세션":"작전"}function C(e){return e?$.value.find(t=>t.name===e||t.agent_name===e)??null:null}function y(e){return{name:e.name,agent_name:e.agent_name??e.name,status:e.status??"unknown",emoji:e.emoji??"",koreanName:e.korean_name??null,context_ratio:e.context_ratio??null}}function F(e){return C(e.name)??y(e)}function N(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function O(e){switch(e){case"live":return"최근 신호(≤5m)";case"stale":return"오래된 신호(>5m)";case"absent":return"signal 없음";default:return e??"signal 미상"}}function W(e){switch(e){case"message":return"최근 출력";case"presence":return"presence/하트비트";case"none":return"근거 없음";default:return e??"근거 미상"}}function M(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function m(e){if(!e)return;const t=k({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"실행 진단",summary:e.label});h(t),v(e.surface,e.surface==="intervene"?w(t):b(t))}function Q({intervene:e,command:t}){return s`
    <div class="control-row">
      ${e?s`
            <${u}
              variant="ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),m(e)}}
            >
              ${e.label}
            <//>
          `:null}
      ${t?s`
            <${u}
              variant="ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),m(t)}}
            >
              ${t.label}
            <//>
          `:null}
    </div>
  `}export{Q as H,x as P,B as R,A as a,K as b,H as c,N as d,O as e,C as f,W as g,F as h,L as i,M as j,R as p,z as q,E as s};
