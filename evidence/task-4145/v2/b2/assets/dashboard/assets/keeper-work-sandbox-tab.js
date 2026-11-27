import{m as t,q as k,d as b,A as B,y as D,T as L,S as E}from"./vendor.js";import{I as W}from"./inline-spinner.js";import{D as M}from"./data-table.js";import{s as j,O as C,a as h,Y as z,B as F,o as V}from"./index.js";import{u as $,K as m}from"./keeper-read.js";import{K as P}from"./keeper-tool-call-inspector.js";import{d as q,e as H,g as J,h as U,s as Y,i as G,r as Q}from"./index3.js";import"./table.js";import"./useSelector.js";import"./virtual-list.js";import"./core.js";import"./type-guards.js";import"./markdown-renderer.js";import"./markdown.js";import"./lazy-component.js";import"./keeper-state.js";import"./format-string.js";import"./setup-inventory-read.js";import"./quota-window.js";import"./sse-reader.js";import"./wire-decode.js";import"./types.js";import"./attachment-gallery.js";import"./copyable-code.js";import"./toast.js";import"./turn-context.js";import"./now-signal.js";import"./shared-ticker.js";import"./target-locked-action.js";import"./icons.js";function Le(a){return t`<${X} key=${JSON.stringify([j.value,a.keeperName])} ...${a} />`}function S(a,s,r){return!a||s===void 0?"—":r?s>0?`관측 ${s}`:"—":s}function T({observation:a}){return a?t`<p class="kp-roster-sub" role="status">
    ${["마지막 성공 조회 표시 중",a.lastSuccessAt,a.reason].filter(Boolean).join(" · ")}
  </p>`:null}function A(a){return a?a.health==="coverage_gap"?["도구 기록 수집에 공백이 있습니다.",a.stale_reason??a.coverage_gaps?.at(-1)?.stale_reason].filter(Boolean).join(" · "):a.health==="stale"?["마지막 도구 기록이 오래되었습니다.",a.stale_reason].filter(Boolean).join(" · "):null:null}function X(a){const{keeperName:s}=a,r=$(k(l=>q(s,l),[s])),d=$(k(l=>H(s,l),[s])),{data:i}=r,{data:n}=d,c=i?.workspaceScope,p=c!=null&&c.shown<c.total,u=p||i?.retained!=null,e=C("admin",h.value);return t`
    <div class="kp-scroll-pane" data-keeper-tab="work-sandbox">
      <div class="kp-grid-2">
        <!-- Linked Tasks -->
        <section class="kp-card" aria-label="연결된 작업">
          <div class="kp-card-head">
            <h3>Linked Tasks (${S(r.received,i?.tasks.length,u)})</h3>
            <button type="button" class="btn-ghost" onClick=${()=>a.onNavigate("/work/tasks")}>
              Tasks →
            </button>
          </div>
          <${m} label="연결 작업" read=${r} />
          <${T} observation=${i?.retained} />
          ${p&&t`<p class="kp-roster-sub">작업공간 전체 ${c.total}건 중 ${c.shown}건 조회</p>`}
          ${r.received&&i?.tasks.length===0&&t`<div class="kp-empty">
            ${u?"이 조회 결과에서 담당 작업을 찾지 못했습니다.":"조회된 담당 작업 없음"}
          </div>`}
          ${i?.tasks.map(l=>t`
                <div key=${l.id} class="kp-kv-box">
                  <div class="kp-card-head">
                    <span class="kp-roster-name">${l.title}</span>
                    <span class="kp-pill" data-tone=${l.status==="Done"?"ok":l.status==="AwaitingVerification"?"warn":"info"}>
                      ${l.status}
                    </span>
                  </div>
                  <span class="kp-roster-sub">${l.id}${l.goal_id?` · goal ${l.goal_id}`:""}</span>
                </div>
              `)}
        </section>

        <!-- Keeper Sandbox Status -->
        <section class="kp-card" aria-label="Keeper 샌드박스 상태">
          <div class="kp-card-head">
            <h3>Sandbox Status</h3>
            ${!e&&t`
              <div class="kp-pill-row">
                <button
                  type="button"
                  class="btn-ghost"
                  data-testid="keeper-sandbox-config-btn"
                  onClick=${()=>a.onNavigate(`/keepers/${encodeURIComponent(s)}/config?section=sandbox`)}
                >
                  샌드박스 설정 →
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  data-testid="keeper-sandbox-infra-btn"
                  onClick=${()=>a.onNavigate("/infra/sandboxes")}
                >
                  Infra →
                </button>
              </div>
            `}
          </div>
          <${m} label="샌드박스" read=${d} />
          ${n?t`
                <div class="kp-grid-2">
                  <div class="kp-kv-box">
                    <span class="kp-kv-k">Backend</span>
                    <span class="kp-kv-v">${n.backend}</span>
                  </div>
                  <div class="kp-kv-box">
                    <span class="kp-kv-k">Probe State</span>
                    <span class="kp-kv-v">${n.probe_kind}</span>
                  </div>
                </div>
                <div class="kp-pill-row">
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>a.onInspect({title:`Sandbox · ${s}`,subtitle:n.backend,kind:"sandbox",data:n.summary})}
                  >
                    샌드박스 원시 상태 보기
                  </button>
                  ${d.received&&t`<button
                    type="button" class="btn-ghost"
                    onClick=${()=>{d.refresh()}}
                  >샌드박스 다시 읽기</button>`}
                </div>
              `:d.received&&t`<div class="kp-lifecycle-bar">
                <span>현재 조회에서 샌드박스 텔레메트리 행을 찾지 못했습니다.</span>
                <button type="button" class="btn-ghost" onClick=${()=>{d.refresh()}}>샌드박스 다시 읽기</button>
              </div>`}
        </section>
      </div>

      ${h.value.kind==="single_user_local"?t`<${Z} keeperName=${s} onInspect=${a.onInspect} />`:t`<p class="kp-card">운영자 노트와 도구 호출 통계·내역은 단일 계정 모드에서 사용할 수 있습니다.</p>`}
    </div>
  `}function Z(a){const{keeperName:s}=a,r=C("admin",h.value),d=$(k(o=>J(s,o),[s]),!0),i=$(k(o=>U(s,24,o),[s])),{data:n}=d,{data:c}=i,[p,u]=b(null),e=p??n?.text??"",[l,_]=b(!1),[K,f]=b(null),v=B(null);D(()=>()=>v.current?.abort(),[]);const N=async()=>{const o=h.peek();if(o.kind!=="single_user_local"||C("admin",o)||v.current||e.trim()==="")return;const O=z(),y=new AbortController;v.current=y,_(!0),f(null);const x=await Y(s,e,y.signal);if(!(y.signal.aborted||!F(O))){if(v.current=null,_(!1),!x.ok){f({kind:"failed",text:x.error.message});return}d.accept(x.value),u(I=>I===e?null:I),f(null),V("운영자 노트 저장 완료","success")}},R=L(()=>new TextEncoder().encode(e).length,[e]),g=A(c),w=g!==null||c?.retained!=null;return t`
    <${E}>
      <!-- Operator-Note Editor -->
      <section class="kp-card" aria-label="운영자 노트 편집기">
        <div class="kp-card-head">
          <h3>Operator Note</h3>
          <div class="kp-pill-row">
            ${d.received&&t`
              <span class="kp-pill" data-tone=${n?.pending?"brass":"default"} role="status">
                ${n?.pending?"다음 턴 주입 대기":n?.consumed_turn!=null?`Consumed @ turn #${n.consumed_turn}`:n?"저장된 노트":"저장된 노트 없음"}
              </span>
            `}
            ${p!==null&&t`<span class="kp-pill" data-tone="warn">저장되지 않은 초안</span>`}
            <span class="kp-pill">${R} B</span>
          </div>
        </div>
        <${m} label="저장된 운영자 노트" read=${d} />
        <textarea
          class="kp-textarea"
          rows=${3}
          aria-label="운영자 노트 입력"
          placeholder="다음 턴 시작 시 Keeper에게 전달할 운영자 지시를 작성하세요… (⌘↵ 저장)"
          readOnly=${r}
          value=${e}
          onInput=${o=>{r||u(o.currentTarget.value)}}
          onKeyDown=${o=>{r||o.isComposing||o.keyCode===229||(o.metaKey||o.ctrlKey)&&o.key==="Enter"&&!l&&(o.preventDefault(),N())}}
        />
        <div class="kp-lifecycle-bar">
          ${r?t`<span class="kp-roster-sub" data-testid="keeper-note-admin-locked">운영자 노트 저장은 관리자 전용입니다.</span>`:t`
                <button type="button" class="btn-primary" disabled=${l||e.trim()===""} onClick=${()=>{N()}}>
                  ${l?t`<${W} size="xs" /> 저장 중…`:"운영자 노트 저장"}
                </button>
              `}
          ${l&&t`<span class="sr-only" role="status">운영자 노트 저장 중…</span>`}
          ${K?.kind==="failed"&&t`<span class="ap-error" role="alert">저장 실패 · ${K.text}</span>`}
        </div>
      </section>

      <!-- Tool Stats 24h Summary -->
      <section class="kp-card" aria-label="도구 호출 통계">
        <div class="kp-card-head">
          <h3>Tool Stats (24h · ${S(i.received,c?.total_entries,w)} calls)</h3>
        </div>
        <${m} label="도구 호출 통계" read=${i} />
        <${T} observation=${c?.retained} />
        ${g&&t`<p class="kp-roster-sub" role="status">${g}</p>`}
        ${i.received&&!w&&c?.tools.length===0&&t`<div class="kp-empty">24h 도구 통계 없음</div>`}
        ${c&&c.tools.length>0&&t`
              <div class="kp-grid-4">
                ${c.tools.slice(0,8).map(o=>t`
                  <div key=${o.name} class="kp-kv-box">
                    <span class="kp-kv-k">${o.name}</span>
                    <span class="kp-kv-v">${o.call_count} calls</span>
                    <span class="kp-roster-sub">
                      ok ${o.success_count} · fail ${o.failure_count} · p95 ${Math.round(o.p95_duration_ms)}ms
                    </span>
                  </div>
                `)}
              </div>
            `}
      </section>

      ${r?t`
            <section class="kp-card" aria-label="도구 호출 내역">
              <div class="kp-card-head">
                <h3>Tool Calls</h3>
              </div>
              <div class="kp-empty" data-testid="keeper-tool-calls-admin-locked" role="status">
                도구 호출 상세 내역 조회는 관리자 전용입니다.
              </div>
            </section>
          `:t`<${ee} keeperName=${s} onInspect=${a.onInspect} />`}
    <//>
  `}function ee(a){const{keeperName:s}=a,[r,d]=b(50),i=$(k(e=>G(s,r,e),[s,r])),{data:n}=i,c=L(()=>[{id:"tool",header:"Tool",width:"16rem",accessor:e=>e.tool,sortable:!0},{id:"kind",header:"Kind",width:"5.5rem",accessor:e=>e.record_kind},{id:"outcome",header:"Outcome",width:"7rem",cell:e=>t`
        <span class="kp-pill" data-tone=${Q(e)}>
          ${e.disposition??e.wire_outcome}
        </span>
      `},{id:"duration",header:"Duration (ms)",width:"8rem",accessor:e=>Math.round(e.duration_ms),numeric:!0,sortable:!0},{id:"turn",header:"Turn",width:"4.5rem",accessor:e=>e.turn??null,numeric:!0}],[]),p=A(n),u=p!==null||n?.retained!=null;return t`
    <!-- Paginated Virtualized Tool Calls -->
    <section class="kp-card" aria-label="도구 호출 내역">
      <div class="kp-card-head">
        <h3>Tool Calls (${S(i.received,n?.count,u)})</h3>
        <div class="kp-pill-row">
          <button
            type="button"
            class="btn-ghost"
            disabled=${!i.received||r>=200}
            onClick=${()=>d(e=>Math.min(200,e+50))}
          >
            더 불러오기 (+50)
          </button>
        </div>
      </div>
      <${m} label="도구 호출 내역" read=${i} />
      <${T} observation=${n?.retained} />
      ${p&&t`<p class="kp-roster-sub" role="status">${p}</p>`}
      ${n&&(n.entries.length>0||i.received&&!u)&&t`
      <${M}
        data=${n.entries}
        columns=${c}
        getRowId=${(e,l)=>e.execution_id??`${e.ts}-${l}`}
        onRowClick=${e=>a.onInspect({title:`Tool Call · ${e.tool}`,subtitle:`${s} · ${Math.round(e.duration_ms)}ms`,kind:"tool_call",data:e,render:()=>t`
            <${P}
              key=${`${s}:${e.execution_id??`${e.ts}-${e.tool}`}`}
              keeperName=${s}
              entry=${e}
            />
          `})}
        maxHeight=${320}
        virtualizeThreshold=${30}
        emptyLabel="도구 호출 기록 없음"
        caption="Keeper Tool Calls"
      />`}
    </section>
  `}export{Le as KeeperWorkSandboxTab};
