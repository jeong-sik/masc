import{A as J,g as ye,d as l,_ as fe,m as a,q as S,y as ge,T as C}from"./vendor.js";import{I as W}from"./inline-spinner.js";import{M as Y}from"./markdown-renderer.js";import{D as Q}from"./data-table.js";import{R as we}from"./refresh-button.js";import{T as Ae}from"./target-locked-action.js";import{a as E,O as z,s as Se,j as Ce,Y as U,B as X,o as Z}from"./index.js";import{u as j,K as D}from"./keeper-read.js";import{a as ee,b as Me}from"./format-time.js";import{A as xe,B as Re,C as Oe,D as Te,F as Ie}from"./index3.js";import"./markdown.js";import"./table.js";import"./useSelector.js";import"./virtual-list.js";import"./core.js";import"./type-guards.js";import"./format-string.js";import"./lazy-component.js";import"./keeper-state.js";import"./setup-inventory-read.js";import"./quota-window.js";import"./sse-reader.js";import"./wire-decode.js";import"./types.js";import"./attachment-gallery.js";import"./copyable-code.js";import"./toast.js";import"./turn-context.js";import"./now-signal.js";import"./shared-ticker.js";import"./icons.js";const Fe=8;function H(t){return t.memory_id||t.claim}function q(t){return`${t.path}
${t.claim}`}function Ke(t){return t.slice(t.indexOf(":")+1).slice(0,Fe)}function te(t){return t.digest?a`<span class="kp-mem-clip kp-mem-id" title=${t.digest}>${Ke(t.digest)}</span>`:a`<span class="dtable-absent">없음</span>`}function re(t){if(t.seenAt<=0)return a`<span class="dtable-absent">없음</span>`;const i=ee(t.seenAt),c=t.firstSeenAt,u=c!==void 0&&c>0&&c!==t.seenAt?`마지막 ${i} · 처음 ${ee(c)}`:i;return a`<span class="kp-mem-clip" title=${u}>${Me(t.seenAt)}</span>`}function ae(t){const i=J(null),c=ye(),[u,d]=l(!1);return fe(()=>{const r=i.current;if(!r)return;const s=()=>d(r.scrollHeight>r.clientHeight+1);if(s(),typeof ResizeObserver>"u")return;const o=new ResizeObserver(s);return o.observe(r),()=>o.disconnect()},[t.open]),a`
    <div class="kp-mem-claim" data-open=${t.open?"true":void 0}>
      <div ref=${i} id=${c} class="kp-mem-claim-text">${t.children}</div>
      ${(u||t.open)&&a`
        <button
          type="button"
          class="kp-mem-claim-toggle"
          aria-expanded=${t.open}
          aria-controls=${c}
          onClick=${t.onToggle}
        >
          ${t.open?"접기":"더 보기"}
        </button>
      `}
    </div>
  `}function Le(t,i){const c=new Set(t);return c.delete(i)||c.add(i),c}function se(t){if(t==null)return null;if(typeof t=="string")return t.trim()||null;if(typeof t=="number"||typeof t=="boolean")return String(t);if(typeof t=="object"&&!Array.isArray(t)){const i=t,c=[];for(const d of["state","kind","status","stop","reason","error"])typeof i[d]=="string"&&i[d].trim()&&c.push(`${d}=${i[d].trim()}`);if(c.length>0)return c.join(" · ");const u=Object.keys(i);return u.length>0?`{${u.slice(0,3).join(", ")}}`:null}return Array.isArray(t)&&t.length>0?`${t.length}건`:null}function $t(t){const i=E.value;return i.kind!=="single_user_local"?a`
    <section class="kp-scroll-pane" data-keeper-tab="memory" aria-label="Keeper 메모리">
      <div class="kp-card" data-testid="keeper-memory-mode-notice" role="status">
        <h3>Memory OS · ${t.keeperName}</h3>
        <p>Keeper 메모리 조회와 복구는 단일 계정 모드에서 사용할 수 있습니다.</p>
      </div>
    </section>
  `:z("admin",i)?a`
    <section class="kp-scroll-pane" data-keeper-tab="memory" aria-label="Keeper 메모리">
      <div class="kp-card" data-testid="keeper-memory-admin-locked" role="status">
        <h3>Memory OS · ${t.keeperName}</h3>
        <p>Keeper 메모리 Facts·Journal 조회 및 복구/철회는 관리자 전용입니다.</p>
      </div>
    </section>
  `:a`<${Ne} key=${JSON.stringify([Se.value,t.keeperName])} ...${t} />`}function ne({state:t,pending:i}){return t?.kind==="pending"?a`<span class="sr-only" role="status">${i}</span>`:t?.kind==="error"?a`<div class="ap-error" role="alert">${t.text}</div>`:null}function Ne(t){const{keeperName:i}=t,c=j(S(e=>xe(i,e),[i])),u=j(S(e=>Re(i,e),[i])),d=j(S(e=>Oe(i,50,e),[i])),{data:r}=c,{data:s}=u,{data:o}=d,[$,ie]=l(""),[M,oe]=l(!1),[x,ce]=l(!1),[P,V]=l(!1),[b,le]=l(()=>new Set),_=S(e=>le(n=>Le(n,e)),[]),[p,de]=l("resume"),[h,pe]=l(""),[R,ue]=l("0"),[O,T]=l(null),[I,F]=l(""),[y,G]=l(""),[K,v]=l(null),f=J(null),g=J(null),L=()=>Promise.all([c.refresh(),u.refresh(),d.refresh()]);ge(()=>()=>{f.current?.abort(),g.current?.abort()},[]);const me=C(()=>{if(!r||r.ordinary.state!=="present")return[];const e=$.trim().toLowerCase();return e?r.ordinary.facts.filter(n=>n.claim.toLowerCase().includes(e)||n.category.toLowerCase().includes(e)||n.memory_id.toLowerCase().includes(e)):r.ordinary.facts},[r,$]),$e=C(()=>{if(!r||r.source_bound.state!=="present")return[];const e=$.trim().toLowerCase();return e?r.source_bound.facts.filter(n=>n.claim.toLowerCase().includes(e)||n.path.toLowerCase().includes(e)):r.source_bound.facts},[r,$]),ve=C(()=>[{id:"category",header:"Category",width:"10rem",accessor:e=>e.category,cell:e=>a`<span class="kp-mem-clip" title=${e.category}>${e.category}</span>`,sortable:!0},{id:"claim",header:"Claim",cell:e=>a`
        <${ae} open=${b.has(H(e))} onToggle=${()=>_(H(e))}>
          <${Y} text=${e.claim} />
        <//>
      `},{id:"last_seen",header:"Last seen",width:"6.5rem",cell:e=>a`<${re} seenAt=${e.last_seen} firstSeenAt=${e.first_seen} />`,sortable:!0,sortValue:e=>e.last_seen},{id:"memory_id",header:"ID",width:"6rem",cell:e=>a`<${te} digest=${e.memory_id} />`},{id:"act",header:"Cleanup",width:"8rem",cell:e=>a`
        <button
          type="button"
          class="btn-ghost btn-compact"
          onClick=${()=>{F(e.memory_id),y||G("operator_cleanup"),V(!0)}}
        >
          Retract 선택
        </button>
      `}],[y,b,_]),ke=C(()=>[{id:"path",header:"Source Path",width:"18rem",accessor:e=>e.path,sortable:!0},{id:"claim",header:"Claim",cell:e=>a`
        <${ae} open=${b.has(q(e))} onToggle=${()=>_(q(e))}>
          <${Y} text=${e.claim} />
        <//>
      `},{id:"first_seen",header:"First seen",width:"6.5rem",cell:e=>a`<${re} seenAt=${e.first_seen} />`,sortable:!0,sortValue:e=>e.first_seen},{id:"sha",header:"SHA256",width:"6rem",cell:e=>a`<${te} digest=${e.sha256} />`}],[b,_]),be=async()=>{const e=E.peek();if(e.kind!=="single_user_local"||z("admin",e)||f.current)return;let n;p==="resume"?n={action:"resume"}:p==="adopt"?n={action:"adopt",observed:h.trim()}:p==="restart_reading"?n={action:"restart_reading",observed:h.trim()}:p==="skip_line"?n={action:"skip_line",offset:Math.max(0,Number.parseInt(R,10)||0)}:n={action:"skip_item",target:{kind:"unreadable_unit",turn_log:h.trim(),line:Math.max(0,Number.parseInt(R,10)||0)}};const w=U(),k=new AbortController;f.current=k,T({kind:"pending"});const m=await Te(i,n,k.signal);if(!(k.signal.aborted||!X(w))){if(f.current=null,!m.ok){T({kind:"error",text:m.error.message});return}T(null),Z(`${n.action} 적용 완료`,"success"),L()}},_e=async()=>{const e=E.peek();if(e.kind!=="single_user_local"||z("admin",e)||g.current)return;const n=I.trim(),w=y.trim();if(!n||!w){v({kind:"error",text:"memory_id와 사유를 모두 입력하세요."});return}const k=U(),m=new AbortController;g.current=m,v({kind:"pending"});const N=await Ie(i,[{memory_id:n,reason:w}],void 0,m.signal);if(m.signal.aborted||!X(k))return;if(g.current=null,!N.ok){v({kind:"error",text:N.error.message});return}const B=N.value.find(A=>A.memoryId===n);if(!B){v({kind:"error",text:`${n}의 철회 결과를 확인할 수 없습니다.`});return}v(null),Z(B.outcome==="retracted"?`철회 완료 · ${n}`:`현재 메모리에 없는 항목 · ${n}`,B.outcome==="retracted"?"success":"info"),F(A=>A.trim()===n?"":A),L()},he=c.received&&r?.ordinary.state==="present"?r.ordinary.revision:"미관측";return a`
    <div class="kp-scroll-pane" data-keeper-tab="memory">
      <div class="kp-card-head">
        <h3>Memory OS · ${i}</h3>
        <div class="kp-pill-row kp-mem-toolbar">
          <input
            type="search"
            class="kp-input kp-mem-search"
            placeholder="Claim / Category / Path 필터…"
            aria-label="메모리 검색"
            value=${$}
            onInput=${e=>ie(e.currentTarget.value)}
          />
          <${we} onRefresh=${L} />
        </div>
      </div>

      <!-- Memory OS Internals (4 Sections) -->
      <${D} label="Memory OS 내부 상태" read=${u} />
      ${s&&(()=>{const e=se(s.librarian_molt.writer_state),n=se(s.librarian_molt.pending_molt);return a`
          <section class="kp-grid-4" aria-label="Memory OS 내부 상태">
            <div class="kp-kv-box">
              <span class="kp-kv-k">Compaction</span>
              <span class="kp-kv-v">
                ${s.compaction.read_error?"⚠ 읽기 오류":s.compaction.present?`${s.compaction.epoch_count} epochs`:"없음"}
              </span>
              <span
                class=${s.compaction.read_error?"kp-roster-sub kp-wrap-text":"kp-roster-sub"}
                title=${s.compaction.read_error??`archived ${s.compaction.archived_turns_count} · verified ${s.compaction.verified_facts_count}`}
              >
                ${s.compaction.read_error?s.compaction.read_error:`archived ${s.compaction.archived_turns_count} · verified ${s.compaction.verified_facts_count}`}
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Canonical Turns</span>
              <span class="kp-kv-v">
                ${s.canonical_turns.read_error?"⚠ 읽기 오류":s.canonical_turns.present?s.canonical_turns.turn_count:"없음"}
              </span>
              <span
                class=${s.canonical_turns.read_error?"kp-roster-sub kp-wrap-text":"kp-roster-sub"}
                title=${s.canonical_turns.read_error??`watermark ${s.canonical_turns.compaction_watermark_seq??"없음"} · resets ${s.canonical_turns.history_resets_count}`}
              >
                ${s.canonical_turns.read_error?s.canonical_turns.read_error:`watermark ${s.canonical_turns.compaction_watermark_seq??"없음"} · resets ${s.canonical_turns.history_resets_count}`}
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Memory Digest</span>
              <span class="kp-kv-v">${s.memory_digest.present?`${s.memory_digest.fact_count} facts`:"없음"}</span>
              <span class="kp-roster-sub">
                rev ${s.memory_digest.revision??"없음"} · ${s.memory_digest.bytes} B
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Librarian Molt</span>
              <span
                class="kp-kv-v"
                title=${`${s.librarian_molt.writer_kind}${e?` · ${e}`:""}`}
              >
                ${s.librarian_molt.writer_kind}${e?` · ${e}`:""}
              </span>
              <span
                class="kp-roster-sub kp-wrap-text"
                title=${`${n?`대기 molt: ${n} · `:""}acts: ${s.librarian_molt.available_acts.length>0?s.librarian_molt.available_acts.join(", "):"없음"}`}
              >
                ${n?`대기 molt: ${n} · `:""}acts: ${s.librarian_molt.available_acts.length>0?s.librarian_molt.available_acts.join(", "):"없음"}
              </span>
            </div>
          </section>
        `})()}

      <${D} label="메모리 사실" read=${c} />
      ${r&&(r.events_read_error||r.events_unreadable_lines>0)&&a`
        <div class="ap-error sev-warn" role="alert">
          ${r.events_read_error?`메모리 이벤트 로그 읽기 오류 · ${r.events_read_error}`:`메모리 이벤트 로그 해독 불가 줄 ${r.events_unreadable_lines}건 감지`}
          ${r.events_read_error&&r.events_unreadable_lines>0?` (해독 불가 ${r.events_unreadable_lines}줄)`:""}
        </div>
      `}

      <!-- Ordinary Memory Facts (3-way discriminated) -->
      <section class="kp-card" aria-label="Ordinary Memory Facts">
        <div class="kp-card-head">
          <h3>Ordinary Facts</h3>
          ${c.received&&r?.ordinary.state==="present"&&a`
            <span class="kp-pill" data-tone="ok">
              rev ${r.ordinary.revision} · ${r.ordinary.facts.length} facts
            </span>
          `}
        </div>
        ${r&&(r.ordinary.state==="absent"?a`<div class="kp-empty" data-branch="absent">스냅샷 없음 (present: false)</div>`:r.ordinary.state==="read_error"?a`<div class="ap-error" data-branch="read_error" role="alert">Ordinary 읽기 오류: ${r.ordinary.read_error}</div>`:a`
                  <${Q}
                    data=${me}
                    columns=${ve}
                    getRowId=${H}
                    initialSort=${{id:"last_seen",desc:!0}}
                    selectedRowId=${I||null}
                    estimateRowHeight=${96}
                    maxHeight=${360}
                    className="kp-mem-facts"
                    emptyLabel="Ordinary fact 없음"
                    caption="Keeper Ordinary Memory Facts"
                  />
                  ${r.ordinary.support_invalidations.length>0&&a`
                    <div class="ap-error sev-warn">
                      Support Invalidations: ${r.ordinary.support_invalidations.length}건
                    </div>
                  `}
                `)}
      </section>

      <!-- Source-Bound Memory Facts (3-way discriminated) -->
      <section class="kp-card" aria-label="Source-Bound Memory Facts">
        <div class="kp-card-head">
          <h3>Source-Bound Facts</h3>
          ${c.received&&r?.source_bound.state==="present"&&a`
            <span class="kp-pill" data-tone="info">
              rev ${r.source_bound.revision} · ${r.source_bound.facts.length} facts
            </span>
          `}
        </div>
        ${r&&(r.source_bound.state==="absent"?a`<div class="kp-empty" data-branch="absent">Source-bound 스냅샷 없음 (present: false)</div>`:r.source_bound.state==="read_error"?a`<div class="ap-error" data-branch="read_error" role="alert">Source-bound 읽기 오류: ${r.source_bound.read_error}</div>`:a`
                  <${Q}
                    data=${$e}
                    columns=${ke}
                    getRowId=${q}
                    initialSort=${{id:"first_seen",desc:!0}}
                    maxHeight=${220}
                    className="kp-mem-facts"
                    emptyLabel="Source-bound fact 없음"
                    caption="Keeper Source-Bound Memory Facts"
                  />
                  ${r.source_bound.invalidations.length>0&&a`
                    <div class="ap-error sev-warn">
                      Source Invalidations: ${r.source_bound.invalidations.map(e=>`${e.source_path} (${e.reason})`).join(", ")}
                    </div>
                  `}
                `)}
      </section>

      <!-- Memory Recovery (memory/act) & Retraction Cleanup (memory/retractions) -->
      <details
        class="ap-disclosure"
        data-testid="memory-tools-disclosure"
        open=${P}
        onToggle=${e=>V(e.currentTarget.open)}
      >
        <summary class="ap-disclosure-trigger">
          <span>메모리 복구 · 철회 도구</span>
          <span aria-hidden="true">${P?"▾":"▸"}</span>
        </summary>
        <div class="ap-disclosure-body">
          <div class="kp-grid-2">
            <section class="kp-card" aria-label="Librarian memory/act 복구">
              <div class="kp-card-head">
                <h3>Librarian Recovery (POST /memory/act)</h3>
              </div>
              <select
                class="kp-input"
                aria-label="memory/act 선택"
                value=${p}
                onChange=${e=>de(e.currentTarget.value)}
              >
                <option value="resume">resume</option>
                <option value="adopt">adopt</option>
                <option value="restart_reading">restart_reading</option>
                <option value="skip_line">skip_line</option>
                <option value="skip_item">skip_item</option>
              </select>
              ${(p==="adopt"||p==="restart_reading"||p==="skip_item")&&a`
                <input
                  type="text"
                  class="kp-input"
                  placeholder=${p==="adopt"?"observed digest sha256":"turn_log id"}
                  value=${h}
                  onInput=${e=>pe(e.currentTarget.value)}
                />
              `}
              ${(p==="skip_line"||p==="skip_item")&&a`
                <input
                  type="number"
                  class="kp-input"
                  placeholder="offset / line"
                  value=${R}
                  onInput=${e=>ue(e.currentTarget.value)}
                />
              `}
              <button
                type="button"
                class="btn-primary"
                disabled=${O?.kind==="pending"}
                onClick=${()=>{be()}}
              >
                ${O?.kind==="pending"?a`<${W} size="xs" /> 복구 적용 중…`:"memory/act 적용"}
              </button>
              <${ne} state=${O} pending="메모리 복구 적용 중…" />
            </section>

            <section class="kp-card" aria-label="Memory Retraction Cleanup">
              <div class="kp-card-head">
                <h3>Fact Retraction Cleanup</h3>
              </div>
              <${Ae}
                target=${{workspaceId:Ce.value,keeper:i,requestId:`memory-retract:${i}`,revision:he}}
              >
                <input
                  type="text"
                  class="kp-input"
                  placeholder="memory_id"
                  aria-label="철회할 memory_id"
                  value=${I}
                  onInput=${e=>F(e.currentTarget.value)}
                />
                <input
                  type="text"
                  class="kp-input"
                  placeholder="철회 사유 (필수)"
                  aria-label="철회 사유"
                  value=${y}
                  onInput=${e=>G(e.currentTarget.value)}
                />
                <button
                  type="button"
                  class="kp-btn-danger"
                  disabled=${K?.kind==="pending"}
                  onClick=${()=>{_e()}}
                >
                  ${K?.kind==="pending"?a`<${W} size="xs" /> 철회 요청 중…`:"Fact 철회 (POST /memory/retractions)"}
                </button>
              <//>
              <${ne} state=${K} pending="메모리 철회 요청 중…" />
            </section>
          </div>
        </div>
      </details>

      <!-- Memory Journal & Activity -->
      <section class="kp-card" aria-label="Memory Journal 및 활동 로그">
        <div class="kp-card-head">
          <h3>Memory Journal (${d.received?o?.returned??"—":"—"})</h3>
          ${o&&o.undecodable_lines>0&&a`
            <span class="kp-pill" data-tone="warn">
              ⚠ undecodable ${o.undecodable_lines}
            </span>
          `}
        </div>
        <${D} label="메모리 저널" read=${d} />
        ${d.received&&o?.entries.length===0&&a`<div class="kp-empty">메모리 저널 기록 없음</div>`}
        ${o&&o.entries.length>0&&a`
              ${o.entries.length>12&&a`
                <div class="kp-card-head">
                  <span class="kp-roster-sub">
                    ${M?`전체 ${o.entries.length}건 표시`:`상위 12건 표시 (전체 ${o.entries.length}건)`}
                  </span>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>oe(e=>!e)}
                  >
                    ${M?"12건만 보기":`전체 ${o.entries.length}건 보기`}
                  </button>
                </div>
              `}
              <div class="kp-grid-2">
                ${(M?o.entries:o.entries.slice(0,12)).map((e,n)=>a`
                  <div key=${e.structural_id||n} class="kp-kv-box">
                    <div class="kp-card-head">
                      <span class="kp-roster-name">
                        ${e.ok?`rev ${e.revision??"?"} · ${e.source_kind??"commit"}`:"저널 오류"}
                      </span>
                      <span class="kp-pill" data-tone=${e.ok?"ok":"bad"}>
                        ${e.ok?`+${e.added??0} / -${e.removed??0}`:"error"}
                      </span>
                    </div>
                    <span
                      class=${e.ok?"kp-roster-sub":"kp-roster-sub kp-wrap-text"}
                      title=${e.ok?`retained ${e.retained??0} · invalidated ${e.invalidated??0}`:e.error??void 0}
                    >
                      ${e.ok?`retained ${e.retained??0} · invalidated ${e.invalidated??0}`:e.error}
                    </span>
                  </div>
                `)}
              </div>
            `}
        ${o?.activity&&o.activity.events.length>0&&a`
          <div>
            <div class="kp-card-head">
              <span class="kp-kv-k">
                Recent Activity Events (${x?o.activity.events.length:Math.min(10,o.activity.events.length)} / ${o.activity.events.length})
              </span>
              ${o.activity.events.length>10&&a`
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>ce(e=>!e)}
                >
                  ${x?"접기":"전체 보기"}
                </button>
              `}
            </div>
            <div class="kp-pill-row">
              ${(x?o.activity.events:o.activity.events.slice(0,10)).map((e,n)=>a`
                <span key=${n} class="kp-pill" data-tone="info">
                  ${e.kind} · r${e.revision}
                </span>
              `)}
            </div>
          </div>
        `}
      </section>
    </div>
  `}export{$t as KeeperMemoryTab};
