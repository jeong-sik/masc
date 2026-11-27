import{d as n,A as u,y as m,T as D,m as a}from"./vendor.js";import{v as E}from"./index.js";import{M as F}from"./markdown-renderer.js";import{f as P,a as T,p as N}from"./config-schema.js";import"./markdown.js";import"./type-guards.js";function j(o){const[d,K]=n(null),[M,S]=n(!0),[$,s]=n(null),[y,R]=n(""),[l,g]=n({}),[c,x]=n(null),[b,h]=n(!1),f=u(!1),i=u(!0),v=u(null),k=u(null),C=u(o.onClose);C.current=o.onClose,m(()=>(i.current=!0,()=>{i.current=!1}),[]),E({containerRef:v,active:!0,initialFocus:()=>k.current}),m(()=>{queueMicrotask(()=>k.current?.focus());const e=t=>{if(!(t.defaultPrevented||t.isComposing||t.keyCode===229)&&t.key==="Escape"){if(typeof document<"u"&&Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).some(p=>p!==v.current))return;t.preventDefault(),t.stopPropagation(),C.current()}};return window.addEventListener("keydown",e),()=>window.removeEventListener("keydown",e)},[]),m(()=>{let e=!0;return P("keeper_create").then(t=>{if(e){if(S(!1),!t.ok){s(t.error.message);return}K(t.value)}}),()=>{e=!1}},[]);const _=D(()=>d?d.categories.flatMap(e=>e.fields).filter(e=>e.writable&&!e.secret).slice(0,12):[],[d]),A=()=>{const e=[];for(const t of _){const r=l[t.full_key];if(r===void 0||r.trim()==="")continue;const p=N(t,r.trim(),!1,",");p&&e.push(p)}return e},w=async e=>{if(f.current)return;const t=y.trim();if(!t){s("Keeper 이름(소문자/숫자/하이픈)을 입력하세요.");return}f.current=!0,h(!0),s(null);try{const r=await T({target:"keeper_create",keeperName:t,dryRun:e,changes:A()});if(!i.current)return;if(!r.ok){s(r.error.message);return}x(r.value),!e&&r.value.applied&&o.onCreated(t)}catch(r){i.current&&s(r instanceof Error?r.message:String(r))}finally{f.current=!1,i.current&&h(!1)}};return a`
    <div
      ref=${v}
      class="kp-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="새 Keeper 생성"
      onClick=${e=>{e.target===e.currentTarget&&o.onClose()}}
    >
      <div class="kp-modal">
        <div class="kp-card-head">
          <h3>+ Create Keeper (target=keeper_create)</h3>
          <button type="button" class="btn-ghost" onClick=${o.onClose}>닫기</button>
        </div>

        ${$&&a`<div class="ap-error" role="alert">${$}</div>`}

        <label class="kp-kv-box">
          <span class="kp-kv-k">Keeper Name (필수)</span>
          <input
            ref=${k}
            type="text"
            class="kp-input"
            placeholder="e.g. code-reviewer-alpha"
            value=${y}
            onInput=${e=>R(e.currentTarget.value)}
          />
        </label>

        ${M?a`<div class="kp-empty">keeper_create 스키마 불러오는 중…</div>`:a`
              <div>
                ${_.map(e=>a`
                  <div key=${e.full_key} class="kp-field-row">
                    <div>
                      <div class="kp-roster-name">${e.label??e.full_key}</div>
                      ${e.description?a`<${F} class="kp-roster-sub" text=${e.description} />`:a`<div class="kp-roster-sub">${e.type}</div>`}
                    </div>
                    ${e.enum_values&&e.enum_values.length>0?a`
                          <select
                            class="kp-input"
                            value=${l[e.full_key]??""}
                            onChange=${t=>g({...l,[e.full_key]:t.currentTarget.value})}
                          >
                            <option value="">(기본값: ${String(e.default_value??"없음")})</option>
                            ${e.enum_values.map(t=>a`<option key=${t} value=${t}>${t}</option>`)}
                          </select>
                        `:a`
                          <input
                            type="text"
                            class="kp-input"
                            placeholder=${String(e.default_value??"")}
                            value=${l[e.full_key]??""}
                            onInput=${t=>g({...l,[e.full_key]:t.currentTarget.value})}
                          />
                        `}
                  </div>
                `)}
              </div>
            `}

        ${c&&a`
          <div>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone="info">reload: ${c.reload_scope}</span>
              ${c.validation_warnings.map((e,t)=>a`
                <span key=${t} class="kp-pill" data-tone="warn">⚠ ${e}</span>
              `)}
            </div>
            <pre class="kp-diff">${c.unified_diff||"(변경 diff 없음)"}</pre>
          </div>
        `}

        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-ghost" disabled=${b} onClick=${()=>{w(!0)}}>
            Dry-Run Diff 미리보기
          </button>
          <button type="button" class="btn-primary" disabled=${b} onClick=${()=>{w(!1)}}>
            Keeper 생성 적용
          </button>
        </div>
      </div>
    </div>
  `}export{j as CreateKeeperModal};
