import{d as i,A as M,y as Y,q as de,T as me,m as s}from"./vendor.js";import{a as d,R as Fe,O as k,$ as J,Y as S,B as P,j as ot}from"./index.js";import{U as lt}from"./unified-diff.js";import{U as ct}from"./uplot-chart.js";import{R as ze}from"./refresh-button.js";import{T as it}from"./target-locked-action.js";import{K as ut}from"./keeper-tool-call-inspector.js";import{f as pt,p as dt,a as mt}from"./config-schema.js";import{G as Qe,i as kt,H as vt,I as ft,J as ht,B as $t,K as gt,A as bt,C as yt,r as _t,L as Ct,M as wt,N as xt,D as Rt}from"./index3.js";import"./markdown-renderer.js";import"./markdown.js";import"./type-guards.js";import"./lazy-component.js";import"./keeper-state.js";import"./format-string.js";import"./core.js";import"./setup-inventory-read.js";import"./quota-window.js";import"./sse-reader.js";import"./wire-decode.js";import"./types.js";import"./attachment-gallery.js";import"./copyable-code.js";import"./toast.js";import"./turn-context.js";import"./now-signal.js";import"./shared-ticker.js";import"./virtual-list.js";import"./table.js";import"./useSelector.js";import"./icons.js";import"./inline-spinner.js";const Pt={per_request:"요청별",turn_total:"클라이언트 턴 합계",conversation_cumulative:"대화 누적",unavailable:"범위 미상"};function Tt(c){switch(c){case"measured_request":case"agent_held_context":return"counted";case"context_estimate":return"estimated";case void 0:return"unknown";default:return c}}function St(c){const t=c.context_window??null,o=c.provider_context_window??null,u=o??t,f=o!==null?"실측 컨텍스트":"설정 기준 컨텍스트",m=c.input_tokens,p=c.usage_scope==="per_request"&&m!=null&&u!==null&&u>0&&m<=u?m/u*100:null,h=Tt(c.input_provenance);return{configured:t,reported:o,window:u,label:f,percent:h==="counted"?p:null,estimatedPercent:h==="estimated"?p:null}}function Mt(c){if(!c)return{cacheRead:null,cacheCreate:null,uncachedInput:null,output:null,total:null,cacheHitPct:null};const t=c.cache_read_input_tokens??null,o=c.cache_creation_input_tokens??null,u=c.input_tokens??null,f=c.output_tokens??null,m=c.usage_scope==="per_request"&&u!==null&&t!==null&&o!==null&&u>=t+o?u-t-o:null,p=c.usage_scope==="per_request"&&u!==null&&u>0&&t!==null&&o!==null&&u>=t+o?Math.round(t/u*100):null,h=t!==null&&o!==null&&m!==null&&f!==null?t+o+m+f:null;return{cacheRead:t,cacheCreate:o,uncachedInput:m,output:f,total:h,cacheHitPct:p}}function At(c){const t=[...c].sort((p,h)=>p.absolute_turn-h.absolute_turn).slice(-60),o=[],u=[],f=[];let m=null;for(const p of t){if(!Number.isFinite(p.ts)||p.ts<=0)continue;const h=p.ts,A=St(p).percent,C=A===null?null:Math.round(A);m!==null&&C!==null&&m-C>=25&&f.push(p.absolute_turn),C!==null&&(m=C),o.push(h),u.push(C)}return u.every(p=>p===null)?{data:[[],[]],compactionTurns:f}:{data:[o,u],compactionTurns:f}}const Kt=[{label:"Context %",colorToken:"--brass-1",width:2,fillAlpha:.16,unit:"%"}];function ps(c){const{keeperName:t}=c,[o,u]=i("trace"),[f,m]=i(null),[p,h]=i(null),[A,C]=i([]),[qe,ke]=i(null),[Le,N]=i(null),[U,ve]=i(null),[G,V]=i(null),[K,fe]=i(null),[De,he]=i(null),[Ue,E]=i(null),[Oe,$e]=i(null),[Z,O]=i(null),[I,ge]=i(null),[Be,be]=i(null),[ye,ee]=i(null),[$,Xe]=i("resume"),[te,Ye]=i(""),[_e,Ze]=i("0"),[He,z]=i(null),[F,Ce]=i(null),[Q,we]=i(""),[We,se]=i(""),[xe,ne]=i(null),[je,q]=i(null),Re=M(null);Y(()=>{Re.current&&(Re.current.scrollTop=0)},[o,t]);const X=M(0),B=M(0),ae=M(0),re=M(0),g=M(!0),_=M(t),oe=M(Q);_.current=t,oe.current=Q,Y(()=>(g.current=!0,()=>{g.current=!1}),[]),Y(()=>{X.current+=1,B.current+=1,ae.current+=1,re.current+=1,oe.current="",m(null),h(null),C([]),ke(null),N(null),ve(null),V(null),fe(null),he(null),E(null),$e(null),O(null),ge(null),be(null),ee(null),z(null),Ce(null),we(""),se(""),ne(null),q(null)},[t]);const Pe=d.value,Te=Fe(Pe),H=k("admin",Pe),b=Te&&!H,L=J(Pe),Se=de(async()=>{const e=d.peek();if(!Fe(e))return;const n=J(e),a=!k("admin",e);if(!n&&!a)return;const r=++X.current,l=S();N(null);const y=n?Qe(t,60):Promise.resolve(null),Ke=a?kt(t,50):Promise.resolve(null),Ee=a?vt(t,12):Promise.resolve(null),[j,x,T]=await Promise.all([y,Ke,Ee]);if(!g.current||r!==X.current||_.current!==t||!P(l))return;const R=[];n&&j&&J(d.peek())&&(j.ok?m(j.value):R.push(`턴 기록: ${j.error.message}`)),a&&!k("admin",d.peek())&&(x&&(x.ok?h(x.value):R.push(`도구 호출: ${x.error.message}`)),T&&(T.ok?C(T.value):R.push(`원시 추적: ${T.error.message}`))),R.length>0&&N(R.join(" · "))},[t]),le=de(async()=>{const e=d.peek();if(!Fe(e))return;const n=J(e),a=!k("admin",e);if(!n&&!a)return;const r=++B.current,l=S();$e(null);const y=n?Qe(t,60):Promise.resolve(null),Ke=a?ft(t):Promise.resolve(null),Ee=a?ht(t):Promise.resolve(null),j=n?$t(t):Promise.resolve(null),[x,T,R,pe]=await Promise.all([y,Ke,Ee,j]);if(!g.current||r!==B.current||_.current!==t||!P(l))return;const D=[];if(n&&x&&J(d.peek()))if(x.ok){m(x.value);const Ve=x.value.entries[0]?.record.turn_ref;if(a&&Ve&&!k("admin",d.peek())){const Ie=await gt(t,Ve);if(!g.current||r!==B.current||_.current!==t||!P(l)||k("admin",d.peek()))return;Ie.ok?V(Ie.value):D.push(`Provider 입력: ${Ie.error.message}`)}else V(null)}else D.push(`턴 기록: ${x.error.message}`);else V(null);a&&T&&!k("admin",d.peek())&&(T.ok?ve(T.value):D.push(`최근 프롬프트: ${T.error.message}`)),a&&R&&!k("admin",d.peek())&&(R.ok?fe(R.value):D.push(`체크포인트: ${R.error.message}`)),n&&pe&&J(d.peek())&&(pe.ok?he(pe.value.compaction.epoch_count):D.push(`Memory OS: ${pe.error.message}`)),D.length>0&&$e(D.join(" · "))},[t]),ce=de(async()=>{const e=d.peek();if(e.kind!=="single_user_local"||k("admin",e))return;const n=++ae.current,a=S();ee(null);const[r,l]=await Promise.all([bt(t),yt(t,20)]);if(!g.current||n!==ae.current||_.current!==t||!P(a)||k("admin",d.peek()))return;const y=[];r.ok?ge(r.value):y.push(`Memory Facts: ${r.error.message}`),l.ok?be(l.value):y.push(`Memory Journal: ${l.error.message}`),y.length>0&&ee(y.join(" · "))},[t]),Je=de(async()=>{if(k("admin",d.peek()))return;const e=++re.current,n=S();q(null);const a=await pt(`keeper:${t}`);if(!g.current||e!==re.current||_.current!==t||!P(n)||k("admin",d.peek()))return;if(!a.ok){q(a.error.message);return}Ce(a.value);const r=a.value.categories.flatMap(l=>l.fields).find(l=>l.writable&&!l.secret);r&&!oe.current&&(oe.current=r.full_key,we(r.full_key),se(Array.isArray(r.current_value)?r.current_value.join(", "):String(r.current_value??"")))},[t]);Y(()=>{L||(X.current+=1,B.current+=1,m(null),he(null)),b||(X.current+=1,B.current+=1,ae.current+=1,h(null),C([]),ke(null),ve(null),V(null),fe(null),O(null),ge(null),be(null),ee(null),z(null)),Te&&(o==="trace"&&(L||b)?Se():o==="context"&&(L||b)?le():o==="memory"&&b&&ce())},[o,Te,L,b,Se,le,ce]),Y(()=>{if(H){re.current+=1,Ce(null),ne(null),q(null);return}o==="config-diff"&&Je()},[o,H,Je]);const w=me(()=>f?f.entries.map(e=>e.record):[],[f]),Ne=me(()=>Math.max(100,...w.map(e=>e.request_latency_ms??0)),[w]),Me=me(()=>At(w),[w]),v=me(()=>Mt(w[0]??null),[w]),et=async e=>{const n=d.peek();if(n.kind!=="single_user_local"||k("admin",n))return;const a=t,r=S();N(null);const l=await Ct(a,e,30);if(!(!g.current||_.current!==a||!P(r))){if(!l.ok){l.error.kind!=="aborted"&&l.error.kind!=="epoch_stale"&&N(`Raw Trace 읽기 실패 (${e}): ${l.error.message}`);return}ke(l.value),c.onInspect({title:`Raw Trace · ${e}`,subtitle:a,kind:"raw_trace",data:l.value})}},tt=async()=>{const e=d.peek();if(e.kind!=="single_user_local"||k("admin",e))return;const n=t,a=S();E("대화 컨텍스트 초기화 중…");const r=await wt(n,"operator_debug_companion_clear",!0);if(!(!g.current||_.current!==n||!P(a))){if(!r.ok){E(`Clear 실패: ${r.error.message}`);return}E("컨텍스트가 초기화되었습니다."),le(),c.onMutated?.()}},st=async()=>{const e=d.peek();if(e.kind!=="single_user_local"||k("admin",e))return;const n=t,a=S();E("Keeper 리셋 중…");const r=await xt(n);if(!(!g.current||_.current!==n||!P(a))){if(!r.ok){E(`Reset 실패: ${r.error.message}`);return}E("Keeper 리셋이 완료되었습니다."),le(),c.onMutated?.()}},nt=async()=>{const e=d.peek();if(e.kind!=="single_user_local"||k("admin",e))return;const n=t,a=S();z(null);let r;$==="resume"?r={action:"resume"}:$==="adopt"?r={action:"adopt",observed:te.trim()}:$==="restart_reading"?r={action:"restart_reading",observed:te.trim()}:$==="skip_line"?r={action:"skip_line",offset:Math.max(0,Number.parseInt(_e,10)||0)}:r={action:"skip_item",target:{kind:"unreadable_unit",turn_log:te.trim(),line:Math.max(0,Number.parseInt(_e,10)||0)}};const l=await Rt(n,r);if(!(!g.current||_.current!==n||!P(a))){if(!l.ok){z(`오류: ${l.error.message}`);return}z(`memory/act (${$}) 적용 완료`),ce()}},at=async()=>{if(H||!F||!Q)return;const e=F.categories.flatMap(y=>y.fields).find(y=>y.full_key===Q);if(!e)return;const n=dt(e,We,!1,",");if(!n){q(`${e.full_key} (${e.type})에 유효한 값을 입력하세요.`);return}const a=t,r=S();q(null);const l=await mt({target:`keeper:${a}`,expectedSha256:F.file_sha256,dryRun:!0,changes:[n]});if(!(!g.current||_.current!==a||!P(r))){if(!l.ok){q(l.error.message);return}ne(l.value)}},W=v.total!==null,ie=W&&v.total>0?v.total:1,ue=W?v.cacheRead/ie*100:0,Ae=W?v.cacheCreate/ie*100:0,Ge=W?v.uncachedInput/ie*100:0,rt=W?v.output/ie*100:0;return s`
    <aside class="kp-companion" aria-label="Debug Companion (⌘.)" data-companion-tab=${o}>
      <div class="kp-companion-head">
        <span class="kp-roster-name">Debug Companion (⌘.)</span>
        <button type="button" class="btn-ghost" onClick=${c.onClose}>닫기</button>
      </div>

      <div class="kp-companion-tabs" role="tablist" aria-label="디버그 탭">
        ${[["trace","Trace"],["context","Context"],["memory","Memory"],["config-diff","Config Diff"]].map(([e,n])=>s`
          <button
            key=${e}
            type="button"
            role="tab"
            class="kp-companion-tab"
            aria-selected=${o===e?"true":"false"}
            onClick=${()=>u(e)}
          >
            ${n}
          </button>
        `)}
      </div>

      <div ref=${Re} class="kp-companion-body">
        ${o==="trace"&&s`
          ${Le&&s`<div class="ap-error" role="alert">${Le}</div>`}

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Turn Gantt Waterfall (${w.length})</h3>
              ${L||b?s`<${ze} onRefresh=${Se} />`:s`<button type="button" class="btn-ghost" disabled>새로고침</button>`}
            </div>
            ${L?w.length===0?s`<div class="kp-empty">턴 기록 없음</div>`:w.slice(0,14).map(e=>{const n=Math.max(2,Math.min(100,Math.round((e.request_latency_ms??0)/Ne*100))),a=Math.max(1,Math.min(n,Math.round((e.ttfrc_ms??0)/Ne*100)));return s`
                    <div key=${e.turn_ref||e.absolute_turn} class="kp-kv-box">
                      <div class="kp-card-head">
                        <span class="kp-roster-name">#${e.absolute_turn} · ${e.turn_kind}</span>
                        <span class="kp-roster-sub tnum">
                          ${e.request_latency_ms!=null?`${Math.round(e.request_latency_ms)}ms`:"없음"}
                        </span>
                      </div>
                      <svg class="kp-svg-bar" viewBox="0 0 100 10" preserveAspectRatio="none" aria-label="턴 지연 바">
                        <rect x="0" y="0" width="100" height="10" class="kp-seg-bg" />
                        <rect x="0" y="1" width=${n} height="8" class="kp-gantt-total" />
                        <rect x="0" y="1" width=${a} height="8" class="kp-gantt-ttfrc" />
                      </svg>
                    </div>
                  `}):s`<div class="kp-empty" data-testid="companion-turn-records-token-locked" role="status">턴 기록 조회는 토큰 인증 싱글유저 세션 전용입니다.</div>`}
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Recent Tool Calls (${p?.count??0})</h3>
            </div>
            ${b?!p||p.entries.length===0?s`<div class="kp-empty">도구 호출 없음</div>`:p.entries.slice(0,15).map((e,n)=>s`
                    <button
                      key=${e.execution_id??n}
                      type="button"
                      class="kp-kv-box"
                      onClick=${()=>c.onInspect({title:`Tool Call · ${e.tool}`,subtitle:`${t} · ${Math.round(e.duration_ms)}ms`,kind:"tool_call",data:e,render:()=>s`
                          <${ut}
                            key=${`${t}:${e.execution_id??`${e.ts}-${e.tool}`}`}
                            keeperName=${t}
                            entry=${e}
                          />
                        `})}
                    >
                      <div class="kp-card-head">
                        <span class="kp-roster-name">${e.tool}</span>
                        <span class="kp-pill" data-tone=${_t(e)}>
                          ${Math.round(e.duration_ms)}ms
                        </span>
                      </div>
                      <span class="kp-roster-sub">${e.disposition??e.wire_outcome}</span>
                    </button>
                  `):s`<div class="kp-empty" data-testid="companion-tool-calls-admin-locked" role="status">도구 호출 상세 내역은 관리자 전용입니다.</div>`}
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Raw Traces (${A.length})</h3>
            </div>
            ${b?A.length===0?s`<div class="kp-empty">Raw trace 파일 없음</div>`:A.slice(0,8).map(e=>s`
                    <button
                      key=${e.file}
                      type="button"
                      class="btn-ghost"
                      onClick=${()=>{et(e.file)}}
                    >
                      ${e.file} (${e.records??"?"} rec · ${Math.round(e.bytes/1024)}KB)
                    </button>
                  `):s`<div class="kp-empty" data-testid="companion-raw-traces-admin-locked" role="status">Raw Trace 조회는 관리자 전용입니다.</div>`}
            ${b&&qe&&s`
              <div class="kp-roster-sub">최근 로드: ${String(qe.file??"")}</div>
            `}
          </div>
        `}

        ${o==="context"&&s`
          ${Oe&&s`<div class="ap-error" role="alert">${Oe}</div>`}
          ${L?s`
                <${ct}
                  id=${`kp-ctx-${t}`}
                  title="60-Turn Context Fill %"
                  subtitle=${s`
                    <span class="kp-pill" data-tone="brass">
                      Compaction epochs: ${De!==null?De:"없음"}
                    </span>
                  `}
                  data=${Me.data}
                  series=${Kt}
                  height=${140}
                  syncCrosshair=${!1}
                  emptyLabel="턴 컨텍스트 데이터 없음"
                />

                ${Me.compactionTurns.length>0&&s`
                  <div class="kp-pill-row">
                    <span class="kp-pill" data-tone="info">
                      Compaction 감지 턴: ${Me.compactionTurns.map(e=>`#${e}`).join(", ")}
                    </span>
                  </div>
                `}

                <!-- 4-segment Prompt Cache SVG stacked bar (zero inline style) -->
                <div class="kp-card">
                  <div class="kp-card-head">
                    <h3>Prompt Cache (4-Segment)</h3>
                    <span class="kp-pill" data-tone=${v.cacheHitPct!==null?"ok":"muted"}>
                      Hit ${v.cacheHitPct!==null?`${v.cacheHitPct}%`:"미상"}
                    </span>
                  </div>
                  <div class="kp-roster-sub">사용량 범위: ${Pt[w[0]?.usage_scope??"unavailable"]}</div>
                  ${W?s`<svg class="kp-svg-bar" viewBox="0 0 100 12" preserveAspectRatio="none" aria-label="프롬프트 캐시 4구간 막대">
                    <rect x="0" y="0" width="100" height="12" class="kp-seg-bg" />
                    <rect x="0" y="0" width=${ue} height="12" class="kp-seg-cache-read" />
                    <rect x=${ue} y="0" width=${Ae} height="12" class="kp-seg-cache-create" />
                    <rect x=${ue+Ae} y="0" width=${Ge} height="12" class="kp-seg-uncached" />
                    <rect x=${ue+Ae+Ge} y="0" width=${rt} height="12" class="kp-seg-output" />
                  </svg>`:s`<div class="kp-empty" role="status">4구간 막대에 필요한 요청별 사용량을 모두 보고하지 않았습니다.</div>`}
                  <div class="kp-grid-2">
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Cache Read</span>
                      <span class="kp-kv-v">${v.cacheRead?.toLocaleString("en-US")??"미상"}</span>
                    </div>
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Cache Write</span>
                      <span class="kp-kv-v">${v.cacheCreate?.toLocaleString("en-US")??"미상"}</span>
                    </div>
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Uncached In</span>
                      <span class="kp-kv-v">${v.uncachedInput?.toLocaleString("en-US")??"미상"}</span>
                    </div>
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Output</span>
                      <span class="kp-kv-v">${v.output?.toLocaleString("en-US")??"미상"}</span>
                    </div>
                  </div>
                </div>
              `:s`
                <div class="kp-card">
                  <div class="kp-card-head">
                    <h3>60-Turn Context Fill & Prompt Cache</h3>
                  </div>
                  <div class="kp-empty" data-testid="companion-context-token-locked" role="status">
                    컨텍스트 채움 추이와 프롬프트 캐시 조회는 토큰 인증 싱글유저 세션 전용입니다.
                  </div>
                </div>
              `}

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Last Prompt & Provider Input</h3>
            </div>
            ${b?s`
                  ${U?s`
                        <div class="kp-roster-sub">
                          Turn #${U.absolute_turn} · ${U.assembled_bytes.toLocaleString("en-US")} bytes · ${U.blocks.length} blocks
                        </div>
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${()=>c.onInspect({title:`Last Prompt #${U.absolute_turn}`,subtitle:t,kind:"last_prompt",data:U})}
                        >
                          Last Prompt 전체 검사
                        </button>
                      `:s`<div class="kp-empty">캡처된 프롬프트 없음</div>`}
                  ${G&&s`
                    <div class="kp-roster-sub">
                      Provider Input: ${G.wire.provider}/${G.wire.model} (${G.parts.length} parts · ${G.wire.body_bytes.toLocaleString("en-US")} B)
                    </div>
                  `}
                `:s`<div class="kp-empty" data-testid="companion-last-prompt-admin-locked" role="status">최근 프롬프트 및 Provider 입력 조회는 관리자 전용입니다.</div>`}
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Checkpoints / Clear / Reset</h3>
            </div>
            ${b?s`
                  <div class="kp-roster-sub">
                    Current: ${K?.current?`${K.current.message_count} msgs (${K.current.snapshot_id.slice(0,12)})`:K?.current_status??"없음"}
                    · History: ${K?.history.length??0}
                  </div>
                  ${Ue&&s`<div class="kp-pill" data-tone="info">${Ue}</div>`}
                  <div class="kp-lifecycle-bar">
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${()=>O(e=>e==="clear"?null:"clear")}
                    >
                      Clear Context…
                    </button>
                    <button
                      type="button"
                      class="kp-btn-danger"
                      onClick=${()=>O(e=>e==="reset"?null:"reset")}
                    >
                      Reset Keeper…
                    </button>
                  </div>
                  ${Z!==null&&s`
                    <${it}
                      target=${{workspaceId:ot.value,keeper:t,requestId:`${Z}:${t}`,revision:K?.current?.snapshot_id??K?.trace_id??"none"}}
                    >
                      <button
                        type="button"
                        class="kp-btn-danger"
                        onClick=${async()=>{const e=Z;O(null),e==="clear"?await tt():await st()}}
                      >
                        ${Z==="clear"?"Clear Context 실행 확인":"Reset Keeper 실행 확인"}
                      </button>
                      <button type="button" class="btn-ghost" onClick=${()=>O(null)}>
                        취소
                      </button>
                    <//>
                  `}
                `:s`<div class="kp-empty" data-testid="companion-checkpoints-admin-locked" role="status">체크포인트 조회 및 Clear/Reset은 관리자 전용입니다.</div>`}
          </div>
        `}

        ${o==="memory"&&(b?s`
          ${ye&&s`<div class="ap-error" role="alert">${ye}</div>`}
          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Memory Facts Summary</h3>
              <${ze} onRefresh=${ce} />
            </div>
            ${I?s`
                  <div class="kp-grid-2">
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Ordinary Facts</span>
                      <span class="kp-kv-v">
                        ${I.ordinary.state==="present"?I.ordinary.facts.length:I.ordinary.state==="absent"?"없음":"오류"}
                      </span>
                    </div>
                    <div class="kp-kv-box">
                      <span class="kp-kv-k">Source-Bound</span>
                      <span class="kp-kv-v">
                        ${I.source_bound.state==="present"?I.source_bound.facts.length:I.source_bound.state==="absent"?"없음":"오류"}
                      </span>
                    </div>
                  </div>
                `:ye?s`<div class="kp-empty">Memory Facts 조회 실패</div>`:s`<div class="kp-empty">불러오는 중…</div>`}
            <div class="kp-roster-sub">
              Journal entries: ${Be?.returned??0} · undecodable: ${Be?.undecodable_lines??0}
            </div>
          </div>

          <div class="kp-card">
            <div class="kp-card-head">
              <h3>memory/act Recovery</h3>
            </div>
            <select
              class="kp-input"
              aria-label="memory/act 액션"
              value=${$}
              onChange=${e=>Xe(e.currentTarget.value)}
            >
              <option value="resume">resume</option>
              <option value="adopt">adopt (sha256)</option>
              <option value="restart_reading">restart_reading (turn_log id)</option>
              <option value="skip_line">skip_line (offset)</option>
              <option value="skip_item">skip_item (unreadable_unit)</option>
            </select>
            ${($==="adopt"||$==="restart_reading"||$==="skip_item")&&s`
              <input
                type="text"
                class="kp-input"
                placeholder=${$==="adopt"?"observed sha256 hex":"turn_log id"}
                value=${te}
                onInput=${e=>Ye(e.currentTarget.value)}
              />
            `}
            ${($==="skip_line"||$==="skip_item")&&s`
              <input
                type="number"
                class="kp-input"
                placeholder="line offset"
                value=${_e}
                onInput=${e=>Ze(e.currentTarget.value)}
              />
            `}
            <button type="button" class="btn-primary" onClick=${()=>{nt()}}>
              memory/act 실행
            </button>
            ${He&&s`<div class="kp-pill" data-tone="info">${He}</div>`}
          </div>
        `:s`
              <div class="kp-card">
                <div class="kp-card-head">
                  <h3>Memory Facts & Recovery</h3>
                </div>
                <div class="kp-empty" data-testid="companion-memory-admin-locked" role="status">
                  메모리 Facts·Journal 조회 및 memory/act 복구는 관리자 전용입니다.
                </div>
              </div>
            `)}

        ${o==="config-diff"&&s`
          <div class="kp-card">
            <div class="kp-card-head">
              <h3>Quick CAS Config Diff</h3>
              ${!H&&s`<span class="kp-pill">sha: ${F?.file_sha256.slice(0,8)||"없음"}</span>`}
            </div>
            ${H?s`<div class="kp-empty" data-testid="companion-config-diff-admin-locked" role="status">Config Diff 조회 및 시뮬레이션은 관리자 전용입니다.</div>`:s`
                  ${je&&s`<div class="ap-error" role="alert">${je}</div>`}
                  ${F&&s`
                    <select
                      class="kp-input"
                      aria-label="설정 필드 선택"
                      value=${Q}
                      onChange=${e=>{const n=e.currentTarget.value;we(n),ne(null);const a=F.categories.flatMap(r=>r.fields).find(r=>r.full_key===n);se(a?Array.isArray(a.current_value)?a.current_value.join(", "):String(a.current_value??""):"")}}
                    >
                      ${F.categories.flatMap(e=>e.fields).filter(e=>e.writable&&!e.secret).map(e=>s`
                        <option key=${e.full_key} value=${e.full_key}>${e.full_key}</option>
                      `)}
                    </select>
                    <input
                      type="text"
                      class="kp-input"
                      aria-label="새 값"
                      value=${We}
                      onInput=${e=>se(e.currentTarget.value)}
                    />
                    <button type="button" class="btn-primary" onClick=${()=>{at()}}>
                      Dry-Run Diff 계산
                    </button>
                  `}
                  ${xe&&s`
                    <div>
                      <span class="kp-pill" data-tone="info">reload: ${xe.reload_scope}</span>
                      <${lt} diffText=${xe.unified_diff||"(변경 없음)"} inline=${!0} />
                    </div>
                  `}
                `}
          </div>
        `}
      </div>
    </aside>
  `}export{ps as KeeperDebugCompanion,At as buildContextFillSeries,Mt as computePromptCacheSegments};
