import{m as o,d as $,y as V,A as oe,T as H}from"./vendor.js";import{U as ye}from"./unified-diff.js";import{a1 as $e,a2 as he,ak as _e,al as ke,a as P,s as we,O as B,z as se,J as Z,Y as J,A as Ce,B as Y}from"./index.js";import{M as xe}from"./markdown-renderer.js";import{R as Se}from"./refresh-button.js";import{f as Re,a as ie,p as Ae}from"./config-schema.js";import"./markdown.js";import"./type-guards.js";function Ie(){const t=$e.value,r=he.value,i=b=>{_e(b)},s=b=>{ke(b)};return o`
    <section
      class="wka-card"
      data-testid="settings-appearance-panel"
      aria-label="화면 테마 및 대비 설정"
      style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)"}}
    >
      <div class="wka-h" style=${{marginBottom:0}}>
        <h3>화면 테마 & 고대비 (OKLCH SSOT)</h3>
        <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
          theme=${t} · contrast=${r??"auto"}
        </span>
      </div>

      <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(240px, 1fr))",gap:"var(--sp-3)"}}>
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
          <div style=${{fontSize:"var(--fs-12)",fontWeight:600,color:"var(--fg-2)"}}>색상 테마</div>
          <div class="ap-viewseg" role="group" aria-label="색상 테마 선택">
            <button
              type="button"
              class=${`ap-viewbtn ${t==="dark"?"on":""}`}
              aria-pressed=${t==="dark"}
              onClick=${()=>i("dark")}
            >
              Dark · Tempered Slate
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${t==="light"?"on":""}`}
              aria-pressed=${t==="light"}
              onClick=${()=>i("light")}
            >
              Light · Warm Paper
            </button>
          </div>
          <span style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            Tempered Slate + Surgical Hearth (Dark) / Warm Archival Paper (Light)
          </span>
        </div>

        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
          <div style=${{fontSize:"var(--fs-12)",fontWeight:600,color:"var(--fg-2)"}}>고대비 모드 (APCA Lc ≥ 90)</div>
          <div class="ap-viewseg" role="group" aria-label="대비 모드 선택">
            <button
              type="button"
              class=${`ap-viewbtn ${r===null?"on":""}`}
              aria-pressed=${r===null}
              onClick=${()=>s(null)}
            >
              시스템 자동
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${r==="normal"?"on":""}`}
              aria-pressed=${r==="normal"}
              onClick=${()=>s("normal")}
            >
              기본
            </button>
            <button
              type="button"
              class=${`ap-viewbtn ${r==="high"?"on":""}`}
              aria-pressed=${r==="high"}
              onClick=${()=>s("high")}
            >
              High Contrast
            </button>
          </div>
          <span style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            정적 OKLCH 프리셋 (<span class="mono">data-contrast="high"</span>) — 런타임 연산 없음
          </span>
        </div>
      </div>
    </section>
  `}const le=[{id:"general",title:"General & UI"},{id:"providers",title:"Providers & Models"},{id:"routing",title:"Routing & Failover"},{id:"keepers",title:"Keepers & Companies"},{id:"sandbox",title:"Sandbox & SSH"},{id:"voice",title:"Voice & Integrations"},{id:"board_memory_candle",title:"Board, Memory & Candle"}],De=new Set(le.map(t=>t.id)),Le={general_ui:"general",general_server:"general",observability_ops:"general",providers_models:"providers",providers_accounts:"providers",runtime_providers:"providers",routing_failover:"routing",runtime_cascades:"routing",runtime_media:"routing",media:"routing",keepers_companies:"keepers",keepers_fleet:"keepers",keepers_autonomy:"keepers",sandbox_ssh:"sandbox",sandbox_ssh_microvm:"sandbox",sandbox_infra:"sandbox",voice_integrations:"voice",voice_audio:"voice",connectors:"voice",economy_connectors:"voice",board_memory_candle:"board_memory_candle",memory_librarian:"board_memory_candle",board_candle:"board_memory_candle",memory_knowledge:"board_memory_candle"};function We(t){const r=t.id.trim().toLowerCase();if(De.has(r))return r;const i=Le[r];if(i)return i;const s=t.title.toLowerCase();return r.includes("general")||s.includes("general")||/\bui\b/.test(s)?"general":r.includes("provider")||s.includes("provider")||s.includes("model")?"providers":r.includes("rout")||r.includes("lane")||r.includes("failover")||s.includes("routing")?"routing":r.includes("keeper")||r.includes("compan")||s.includes("keeper")?"keepers":r.includes("sandbox")||r.includes("ssh")||r.includes("docker")||s.includes("sandbox")?"sandbox":r.includes("voice")||r.includes("integrat")||r.includes("gate")||s.includes("voice")?"voice":r.includes("board")||r.includes("memory")||r.includes("candle")||s.includes("candle")?"board_memory_candle":t.id}function ze(t){const r=new Map;for(const i of le)r.set(i.id,{title:i.title,fields:[]});for(const i of t){const s=We(i),b=r.get(s);b?b.fields.push(...i.fields):r.set(s,{title:i.title,fields:[...i.fields]})}return[...r.entries()].map(([i,s])=>({id:i,title:s.title,field_count:s.fields.length,fields:s.fields}))}function Q(t){switch(t){case"hot_reload":return{label:"hot_reload (즉시 반영)",detail:"적용 즉시 실행 중인 서버에 반영됩니다. 재시작이 필요하지 않습니다.",tone:"ok"};case"next_turn":return{label:"next_turn (다음 턴 반영)",detail:"이미 진행 중인 턴은 유지되며 다음 턴부터 새 설정이 적용됩니다.",tone:"info"};case"restart_required":return{label:"restart_required (서버 재시작 필요)",detail:"이 변경은 TOML에 저장되지만 MASC 서버를 재시작해야 완전히 반영됩니다.",tone:"warn"}}}function Te(t){const r=t.toLowerCase();return r==="env_override"||r==="env"?{background:"var(--warn-soft)",border:"1px solid var(--warn-border)",color:"var(--warn-fg)"}:r==="keeper"?{background:"var(--brass-soft)",border:"1px solid var(--brass-border)",color:"var(--brass-1)"}:r==="project"||r==="global"?{background:"var(--info-soft)",border:"1px solid var(--info-border)",color:"var(--info-fg)"}:{background:"var(--idle-soft)",border:"1px solid var(--idle-border)",color:"var(--fg-3)"}}function Ee(t){return t.secret?t.current_value?"••••••••":"없음":t.current_value===null||t.current_value===void 0?"":Array.isArray(t.current_value)?t.current_value.join(`
`):typeof t.current_value=="object"?JSON.stringify(t.current_value):String(t.current_value)}function Oe(t){return o`<${ye} diffText=${t} testId="settings-unified-diff" />`}function X(t){const r=(t??"").trim().toLowerCase();return r?r==="general"||r==="ui"?"general":r==="provider"||r==="providers"||r==="model"||r==="models"?"providers":r==="routing"||r==="route"||r==="lane"||r==="lanes"||r==="failover"?"routing":r==="keeper"||r==="keepers"||r==="company"||r==="companies"?"keepers":r==="sandbox"||r==="ssh"||r==="docker"?"sandbox":r==="voice"||r==="integrations"||r==="gate"?"voice":r==="board"||r==="memory"||r==="candle"||r==="board_memory_candle"?"board_memory_candle":r:null}function Pe(){const t=Z.peek().query.key;return t||(typeof window>"u"?"":new URLSearchParams(window.location.search).get("key")??"")}function Be(){const t=X(Z.peek().query.section);if(t)return t;if(typeof window<"u"){const r=X(new URLSearchParams(window.location.search).get("section")??void 0);if(r)return r}return"general"}function Ke(t){const r=P.value,i=we.value,s=B("admin",r),b=r.kind==="single_user_local"&&!s,C=t.entityId?`keeper:${t.entityId}`:"runtime",ee=`settings:schema:${C}`,h=se.observe(ee).value,x=Z.value.query,[ce,re]=$(()=>Be()),[_,M]=$(()=>Pe());V(()=>{if(x.key)M(x.key);else if(x.section){const e=X(x.section);e&&(M(""),re(e))}},[x.key,x.section]);const[N,R]=$({}),[v,f]=$(null),[A,U]=$(null),[te,k]=$(null),[ae,g]=$(null),[c,w]=$(null),I=oe(!0),q=oe(C);q.current=C,V(()=>(I.current=!0,()=>{I.current=!1}),[]);const j=(e="mount")=>B("admin",P.peek())?Promise.resolve():se.fetch(ee,a=>Re(C,a),{ttlMs:15e3,topics:["config"],reason:e});V(()=>{R({}),f(null),U(null),k(null),g(null),w(null),s||j("mount")},[C,i,s]);const d=h.kind==="value"?h.data:null,D=H(()=>ze(d?.categories??[]),[d]),F=H(()=>Object.values(N),[N]),G=F.some(e=>e.op==="invalid_number"),L=H(()=>F.filter(e=>e.op!=="invalid_number"),[F]),W=L.length,m=v&&!G&&v.changes===L&&v.target===d?.target&&v.sha256===d.file_sha256?v.result:null,z=D.find(e=>e.id===ce)??D[0]??null,T=H(()=>{const e=_.trim().toLowerCase();if(e){const a=[];for(const n of D)for(const l of n.fields)`${l.full_key} ${l.label??""} ${l.description}`.toLowerCase().includes(e)&&a.push(l);return a}return z?.fields??[]},[D,z,_]),E=(e,a,n=!1)=>{const l=Ae(e,a,n)??{op:"invalid_number",value:String(a??"")};R(y=>({...y,[e.full_key]:l})),f(null),k(null),g(null)},de=e=>{R(a=>{const n={...a};return delete n[e],n}),f(null)},ue=async()=>{if(B("admin",P.peek())||!d||G||L.length===0||c)return;const e=J(),a=d.target;w("preview"),f(null),g(null),k(null),U(null);const n=await ie({target:a,expectedSha256:d.file_sha256,dryRun:!0,changes:L});if(!(!I.current||q.current!==a||!Y(e))){if(w(null),!n.ok){n.error.kind==="conflict_cas"?k(n.error.message||"설정 파일이 외부에서 변경되었습니다 (409 conflict_cas)."):g(`Dry-Run 미리보기 실패: ${n.error.message}`);return}f({target:a,sha256:d.file_sha256,changes:L,result:n.value})}},pe=async()=>{if(B("admin",P.peek())||!v||!m?.changed||c)return;const e=J(),a=v.target;w("apply"),g(null),k(null);const n=await ie({target:a,expectedSha256:v.sha256,dryRun:!1,changes:v.changes});if(!(!I.current||q.current!==a||!Y(e))){if(w(null),!n.ok){n.error.kind==="conflict_cas"?k(n.error.message||"CAS 충돌 (409): 설정 파일 SHA-256이 변경되었습니다."):g(`패치 적용 실패: ${n.error.message}`);return}U(n.value),f(null),R({}),j("manual")}},ve=()=>{k(null),f(null),g(null),j("manual")},fe=async()=>{const e=P.peek();if(e.kind!=="single_user_local"||B("admin",e))return;const a=J();w("export"),g(null);const n=await Ce("/api/v1/world/configuration/export");if(!I.current||!Y(a))return;if(w(null),!n.ok){g(`월드 설정 내보내기 실패: ${n.error.message}`);return}const l=n.value,y=JSON.stringify(l,null,2);t.onInspect({title:"World Configuration Export",subtitle:`${l.scope??"authored_configuration_documents"} · 경고 ${l.lock_warnings?.length??0}건`,kind:"world_config_export",data:l,render:()=>o`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
          <div style=${{display:"flex",gap:"var(--sp-2)"}}>
            <button
              type="button"
              class="btn-primary"
              onClick=${()=>{try{const O=new Blob([y],{type:"application/json"}),u=URL.createObjectURL(O),S=document.createElement("a");S.href=u,S.download=`masc-world-config-${new Date().toISOString().slice(0,10)}.json`,S.click(),URL.revokeObjectURL(u)}catch{}}}
            >
              JSON 다운로드
            </button>
          </div>
          <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap",background:"var(--bg-0)",padding:"var(--sp-3)",borderRadius:"var(--radius-sm)"}}>
            ${y}
          </pre>
        </div>
      `})},ge=e=>{const a=N[e.full_key],n=a!==void 0,l=a?.op==="remove",y=a?.op==="invalid_number",O=n?l?"(키 제거 예정)":Array.isArray(a.value)?a.value.join(`
`):String(a.value??""):Ee(e),u=e.type.toLowerCase(),S=u==="bool"||u==="boolean",K=u==="int"||u==="integer",ne=K||u==="float"||u==="number",be=u==="string_array"||u==="string_list",me=Array.isArray(e.enum_values)&&e.enum_values.length>0;return o`
      <article
        key=${e.full_key}
        data-field-key=${e.full_key}
        style=${{padding:"var(--sp-3)",borderRadius:"var(--radius-sm)",border:`1px solid ${n?"var(--brass-border)":"var(--line-1)"}`,background:n?"var(--brass-soft)":"var(--bg-2)",display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}
      >
        <div style=${{display:"flex",justifyContent:"space-between",alignItems:"flex-start",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          <div style=${{minWidth:0}}>
            <div style=${{fontWeight:600,fontSize:"var(--fs-13)",color:"var(--fg-1)"}}>
              ${e.label||e.key}
            </div>
            <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${e.full_key}</div>
          </div>

          <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-1)",flexWrap:"wrap"}}>
            <span
              class="mono"
              style=${{...Te(e.provenance),padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-10)"}}
            >
              ${e.provenance}
            </span>
            <span
              class="mono"
              style=${{padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-10)",background:"var(--bg-3)",color:e.reload_scope==="restart_required"?"var(--warn-fg)":"var(--fg-2)"}}
            >
              ${e.reload_scope}
            </span>
            ${e.secret&&o`
              <span class="mono" style=${{padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-10)",background:"var(--err-soft)",color:"var(--err-fg)"}}>
                secret
              </span>
            `}
            ${!e.writable&&o`
              <span class="mono" style=${{padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-10)",background:"var(--idle-soft)",color:"var(--fg-3)"}}>
                read-only
              </span>
            `}
          </div>
        </div>

        ${e.description&&o`
          <div style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
            <${xe} text=${e.description} />
          </div>
        `}

        <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          ${a?.op==="remove"?o`
                <span class="mono" style=${{fontSize:"var(--fs-12)",color:"var(--warn-fg)"}}>
                  기본값 복원 예정 (remove)
                </span>
              `:!e.writable&&S&&e.current_value===!0&&(e.full_key.toLowerCase().endsWith("supports_image_input")||e.full_key.toLowerCase().endsWith("vision_input")||e.full_key.toLowerCase().endsWith("supports_image_output")||e.full_key.toLowerCase().endsWith("image_output"))?o`
                  <span
                    class=${`mono rt-cap-chip${e.full_key.toLowerCase().endsWith("supports_image_output")||e.full_key.toLowerCase().endsWith("image_output")?" rt-cap-chip--gen":""}`}
                    data-testid=${`settings-cap-${e.full_key}`}
                  >
                    ${e.full_key.toLowerCase().endsWith("supports_image_output")||e.full_key.toLowerCase().endsWith("image_output")?"Image Gen":"Vision"}
                  </span>
                `:S?o`
                <label style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                  <input
                    type="checkbox"
                    aria-label=${e.full_key}
                    disabled=${!e.writable||c==="apply"}
                    checked=${n?!!a.value:!!e.current_value}
                    onChange=${p=>E(e,p.target.checked)}
                  />
                  <span class="mono">${(n?a.value:e.current_value)?"true":"false"}</span>
                </label>
              `:me?o`
                  <select
                    aria-label=${e.full_key}
                    disabled=${!e.writable||c==="apply"}
                    value=${O}
                    onChange=${p=>E(e,p.target.value)}
                    style=${{minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",fontSize:"var(--fs-12)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                  >
                    ${e.enum_values.map(p=>o`<option key=${p} value=${p}>${p}</option>`)}
                  </select>
                `:be?o`
                    <textarea
                      rows=${3}
                      aria-label=${e.full_key}
                      disabled=${!e.writable||c==="apply"}
                      value=${O}
                      onInput=${p=>E(e,p.target.value)}
                      class="mono"
                      style=${{flex:1,minWidth:"220px",padding:"var(--sp-1) var(--sp-2)",fontSize:"var(--fs-12)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                    />
                  `:o`
                    <input
                      type=${e.secret?"password":ne?"number":"text"}
                      aria-label=${e.full_key}
                      disabled=${!e.writable||c==="apply"}
                      aria-invalid=${y}
                      step=${ne?K?1:"any":void 0}
                      placeholder=${e.secret?"•••••••• (새 시크릿 입력 시 덮어씀)":String(e.default_value??"없음")}
                      value=${e.secret&&!n?"":O}
                      onInput=${p=>E(e,p.target.value)}
                      class="mono tnum"
                      style=${{flex:1,minWidth:"200px",minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",fontSize:"var(--fs-12)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                    />
                  `}

          ${y&&o`<span class="ap-error" role="alert">${K?"정수를 입력하세요.":"숫자를 입력하세요."}</span>`}
          ${e.writable&&e.table&&o`
            <button
              type="button"
              class="btn-ghost"
              style=${{padding:"var(--sp-1) var(--sp-2)",fontSize:"var(--fs-11)"}}
              disabled=${c==="apply"}
              onClick=${()=>E(e,null,!0)}
            >
              기본값 복원
            </button>
          `}
          ${n&&o`
            <button
              type="button"
              class="btn-ghost"
              style=${{padding:"var(--sp-1) var(--sp-2)",fontSize:"var(--fs-11)",color:"var(--err-fg)"}}
              disabled=${c==="apply"}
              onClick=${()=>de(e.full_key)}
            >
              변경 취소
            </button>
          `}
        </div>
      </article>
    `};return o`
    <div class="set-shell" data-testid="settings-workspace">
      <header class="ov-head" style=${{gridColumn:"1 / -1"}}>
        <div>
          <span class="ov-eyebrow">SYSTEM · SCHEMA-DRIVEN SETTINGS</span>
          <h1>설정 트리 & CAS Dry-Run Diff 인스펙터</h1>
          <p class="ov-sub">
            대상: <span class="mono">${C}</span> · SHA-256: <span class="mono">${d?.file_sha256?d.file_sha256.slice(0,12):"없음"}</span>
          </p>
        </div>
        <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          <input
            type="search"
            aria-label="설정 키 검색"
            placeholder="설정 키 / 설명 검색…"
            value=${_}
            onInput=${e=>M(e.target.value)}
            style=${{minHeight:"var(--btn-h, 32px)",fontSize:"var(--fs-12)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)",minWidth:"200px"}}
          />
          ${b&&o`
            <button
              type="button"
              class="btn-ghost"
              disabled=${c==="export"}
              onClick=${()=>{fe()}}
            >
              ${c==="export"?"내보내는 중…":"Export World Config"}
            </button>
          `}
          <button
            type="button"
            class="btn-primary"
            disabled=${W===0||G||c!==null||!d}
            onClick=${()=>{ue()}}
          >
            ${c==="preview"?"Diff 생성 중…":`Preview Diff (${W})`}
          </button>
        </div>
      </header>

      ${ae&&o`<div class="ap-error" role="alert" style=${{gridColumn:"1 / -1"}}>${ae}</div>`}

      <!-- 409 CAS Conflict Alert -->
      ${te&&o`
        <section class="ap-error" data-testid="settings-cas-conflict" role="alert" style=${{gridColumn:"1 / -1",display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-3)",flexWrap:"wrap"}}>
          <div>
            <strong>⚠ 409 CAS 충돌 (conflict_cas):</strong> ${te}
          </div>
          <button type="button" class="btn-primary" onClick=${ve}>
            최신 스키마 다시 불러오기
          </button>
        </section>
      `}

      <!-- Applied Patch Receipt -->
      ${A&&o`
        <section
          class="wka-card"
          data-testid="settings-apply-receipt"
          role="status"
          style=${{gridColumn:"1 / -1",borderColor:"var(--ok-border)",background:"var(--ok-soft)",display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}
        >
          <div style=${{fontWeight:600,color:"var(--ok-fg)"}}>
            ✓ 설정 패치 적용 완료 (${Q(A.reload_scope).label})
          </div>
          <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-1)"}}>
            snapshot_id: ${A.snapshot_id??"없음"} · new_sha256: ${A.new_sha256.slice(0,16)}
          </div>
          <div style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
            ${Q(A.reload_scope).detail}
          </div>
        </section>
      `}

      <!-- Dry-Run Diff Preview & Explicit Apply Gate -->
      ${m&&o`
        <section
          class="wka-card"
          data-testid="settings-dry-run-panel"
          style=${{gridColumn:"1 / -1",borderColor:"var(--brass-border)",display:"flex",flexDirection:"column",gap:"var(--sp-3)"}}
        >
          <div class="wka-h" style=${{marginBottom:0}}>
            <h3>Dry-Run Unified Diff 미리보기 (${W}건 변경)</h3>
            <div style=${{display:"flex",gap:"var(--sp-2)"}}>
              <button type="button" class="btn-ghost" onClick=${()=>f(null)}>닫기</button>
              <button
                type="button"
                class="btn-primary"
                disabled=${c!==null||!m.changed}
                onClick=${()=>{pe()}}
              >
                ${c==="apply"?"적용 중…":"Apply Patch"}
              </button>
            </div>
          </div>

          ${(()=>{const e=Q(m.reload_scope),a=e.tone==="warn"?{borderColor:"var(--warn-border)",background:"var(--warn-soft)",color:"var(--warn-fg)"}:e.tone==="info"?{borderColor:"var(--info-border)",background:"var(--info-soft)",color:"var(--info-fg)"}:{borderColor:"var(--ok-border)",background:"var(--ok-soft)",color:"var(--ok-fg)"};return o`
              <div data-testid="settings-reload-scope-notice" style=${{padding:"var(--sp-2) var(--sp-3)",borderRadius:"var(--radius-sm)",border:"1px solid",...a,fontSize:"var(--fs-12)"}}>
                <strong>${e.label}:</strong> ${e.detail}
              </div>
            `})()}

          ${m.validation_warnings.length>0&&o`
            <div class="ap-error sev-warn">
              ${m.validation_warnings.map((e,a)=>o`<div key=${a}>⚠ ${e}</div>`)}
            </div>
          `}

          ${m.unified_diff?Oe(m.unified_diff):o`<div class="dtable-absent">변경된 Diff 라인이 없습니다.</div>`}
        </section>
      `}

      <!-- 2-Pane Category Tree + Property Inspector -->
      <nav class="set-card-b" aria-label="설정 카테고리 (7개)" style=${{padding:"var(--sp-2)",display:"flex",flexDirection:"column",gap:"var(--sp-1)",alignSelf:"start"}}>
        ${D.map(e=>{const a=!_.trim()&&z?.id===e.id,n=e.fields.filter(l=>l.full_key in N).length;return o`
            <button
              key=${e.id}
              type="button"
              aria-current=${a?"page":void 0}
              onClick=${()=>{M(""),re(e.id)}}
              style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)",minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-3)",borderRadius:"var(--radius-sm)",border:"none",background:a?"var(--bg-4)":"transparent",color:a?"var(--fg-1)":"var(--fg-2)",fontWeight:a?600:400,textAlign:"left",cursor:"pointer",fontSize:"var(--fs-12)"}}
            >
              <span>${e.title}</span>
              <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:n>0?"var(--brass-1)":"var(--fg-3)"}}>
                ${n>0?`*${n} / `:""}${e.field_count}
              </span>
            </button>
          `})}

        ${W>0&&o`
          <button
            type="button"
            class="btn-ghost"
            style=${{marginTop:"var(--sp-1)",color:"var(--err-fg)"}}
            onClick=${()=>{R({}),f(null)}}
          >
            스테이징 모두 취소 (${W})
          </button>
        `}
      </nav>

      <section class="set-card-b" aria-label="속성 인스펙터" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
        ${z?.id==="general"&&!_.trim()&&o`<${Ie} />`}

        <div class="wka-h" style=${{marginBottom:0}}>
          <h3>
            ${_.trim()?`검색 결과: "${_.trim()}" (${T.length})`:`${z?.title??"Settings"} (${T.length})`}
          </h3>
          <${Se} label="스키마 새로고침" onRefresh=${()=>j("manual")} />
        </div>

        ${h.kind==="loading"&&o`<div class="dtable-absent">설정 스키마 불러오는 중…</div>`}
        ${h.kind==="failed"&&o`
          <div class="ap-error" role="alert">
            ${h.error.kind==="forbidden"?"관리자(Admin) 권한이 필요한 설정 스키마입니다 (HTTP 403).":`설정 스키마 조회 실패: ${h.error.message}`}
          </div>
        `}

        ${h.kind==="value"&&T.length===0&&o`
          <div class="dtable-absent">이 카테고리에 표시할 설정 필드가 없습니다.</div>
        `}

        ${T.length>0&&o`
          <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
            ${T.map(ge)}
          </div>
        `}
      </section>
    </div>
  `}export{le as CANONICAL_SETTINGS_CATEGORIES,Ke as SettingsWorkspace,Ke as default,ze as organizeCategoriesIntoSeven,Ae as patchOpForField,Q as reloadScopeNotice};
