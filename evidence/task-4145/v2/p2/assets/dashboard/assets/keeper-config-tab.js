import{d as c,A as R,y as Z,q as he,T as ee,m as n}from"./vendor.js";import{c as Oe}from"./copyable-code.js";import{M as Ie}from"./markdown-renderer.js";import{U as Ee}from"./unified-diff.js";import{R as Le}from"./refresh-button.js";import{O as $,a as v,Y as y,B as m,J as $e,o as O}from"./index.js";import{s as Te,d as Re,a as xe,b as De}from"./keeper-oauth-flow.js";import{f as Ue,p as Fe,a as Me}from"./config-schema.js";import{w as Pe,x as qe,y as Be,z as me}from"./index3.js";import"./toast.js";import"./markdown.js";import"./sse-reader.js";import"./type-guards.js";import"./lazy-component.js";import"./keeper-state.js";import"./format-string.js";import"./core.js";import"./setup-inventory-read.js";import"./quota-window.js";import"./wire-decode.js";import"./types.js";import"./attachment-gallery.js";import"./turn-context.js";import"./now-signal.js";import"./shared-ticker.js";import"./virtual-list.js";import"./table.js";import"./useSelector.js";import"./target-locked-action.js";import"./icons.js";import"./inline-spinner.js";function ge(u,l){const a=l?.trim().toLowerCase();if(!a)return null;const i=u.find(f=>f.id.toLowerCase()===a);if(i)return i.id;if(a==="sandbox"||a==="ssh"||a==="docker"){const f=u.find(S=>{const h=`${S.id} ${S.title}`.toLowerCase();return h.includes("sandbox")||h.includes("ssh")||h.includes("docker")});if(f)return f.id}return u.find(f=>f.id.toLowerCase().includes(a)||f.title.toLowerCase().includes(a))?.id??null}function Ve(u,l){if(l!==!0)return null;const a=u.trim().toLowerCase();return a.endsWith("supports_image_input")||a.endsWith("vision_input")?{label:"Vision"}:a.endsWith("supports_image_output")||a.endsWith("image_output")?{label:"Image Gen",gen:!0}:null}function te(u){return u==null?"":Array.isArray(u)?u.join(", "):String(u)}function gt(u){const{keeperName:l}=u,a=$("admin",v.value),[i,N]=c(null),[f,S]=c(""),[h,x]=c({}),[g,j]=c(null),[re,I]=c(null),[se,q]=c(!1),[ne,ae]=c(!1),[D,ye]=c("keeper"),[G,oe]=c(""),[J,Y]=c(""),[le,A]=c(null),[ie,ce]=c([]),[H,ue]=c(null),[pe,p]=c(null),[_,B]=c(null),[k,K]=c(null),[de,ve]=c(!1),E=R(null),d=R(!0),b=R(l),U=R(null),F=R(null),M=R(void 0);b.current=l,Z(()=>(d.current=!0,()=>{d.current=!1,E.current?.cancel(),U.current?.abort(),F.current?.abort()}),[]);const V=he(async(e=!1)=>{if(a)return;U.current?.abort();const r=new AbortController;U.current=r;const t=l,s=y();I(null),q(!1);const o=await Ue(`keeper:${t}`,r.signal);if(!d.current||b.current!==t||!m(s)||r.signal.aborted)return;if(!o.ok){o.error.kind!=="aborted"&&o.error.kind!=="epoch_stale"&&I(o.error.message);return}N(o.value),x({}),e||j(null);const w=$e.peek().query.section,fe=ge(o.value.categories,w),Ae=o.value.categories[0]?.id??"";S(X=>X&&o.value.categories.some(Ke=>Ke.id===X)?X:fe?(M.current=w,fe):Ae)},[l,a]),P=$e.value.query.section;Z(()=>{if(!P){M.current=void 0;return}if(!i||P===M.current)return;const e=ge(i.categories,P);M.current=P,e&&S(e)},[i,P]);const C=he(async()=>{if(v.peek().kind!=="single_user_local")return;F.current?.abort();const e=new AbortController;F.current=e;const r=l,t=y(),s=await Pe(r,e.signal);!d.current||b.current!==r||!m(t)||e.signal.aborted||(s.ok?(ce(s.value.providers),ue(s.value.callbackUrl),p(null)):s.error.kind!=="aborted"&&s.error.kind!=="epoch_stale"&&p(`OAuth 연결 조회 실패: ${s.error.message}`))},[l]),L=v.value.kind==="single_user_local",_e=L&&!a,z=L&&!a;Z(()=>{E.current?.cancel(),U.current?.abort(),F.current?.abort(),N(null),S(""),x({}),j(null),I(null),q(!1),oe(""),Y(""),A(null),ce([]),ue(null),p(null),B(null),K(null),M.current=void 0;const e=[];return a||e.push(V()),L&&e.push(C()),e.length>0&&Promise.all(e),()=>{U.current?.abort(),F.current?.abort()}},[V,C,a,L]);const ke=ee(()=>i?i.categories.flatMap(e=>e.fields):[],[i]),Q=ee(()=>i?.categories.find(e=>e.id===f)??i?.categories[0]??null,[i,f]),{pendingChanges:T,invalidFieldKeys:W}=ee(()=>{const e=[],r=[];for(const t of ke){if(!t.writable)continue;const s=h[t.full_key];if(s===void 0||s===te(t.current_value))continue;const o=Fe(t,s,!1,",");o?e.push(o):r.push(t.full_key)}return{pendingChanges:e,invalidFieldKeys:r}},[ke,h]),be=async e=>{if(a||!i)return;if(W.length>0){I(`유효하지 않은 숫자/형식 입력이 있습니다: ${W.join(", ")}`);return}if(T.length===0)return;const r=l,t=y();ae(!0),I(null),q(!1);const s=await Me({target:`keeper:${r}`,expectedSha256:i.file_sha256,dryRun:e,changes:T});if(!(!d.current||b.current!==r||!m(t))){if(ae(!1),!s.ok){(s.error.kind==="conflict_cas"||s.error.status===409)&&q(!0),I(s.error.message);return}j(s.value),!e&&s.value.applied&&(await V(!0),d.current&&b.current===r&&m(t)&&u.onMutated())}},Ce=async()=>{const e=v.peek();if(e.kind!=="single_user_local"||$("admin",e))return;const r=G.trim();if(!r||!J){A("환경변수 이름과 값을 입력하세요.");return}const t=l,s=y();A(null);const o=await me(t,{action:"set_env",scope:D,name:r,value:J});if(!(!d.current||b.current!==t||!m(s)||$("admin",v.peek()))){if(!o.ok){A(`저장 실패: ${o.error.message}`);return}Y(""),A(null),O(`${D}:${r} 시크릿 저장 완료 (값은 재표시되지 않습니다).`,"success")}},we=async()=>{const e=v.peek();if(e.kind!=="single_user_local"||$("admin",e))return;const r=G.trim();if(!r)return;const t=l,s=y(),o=await me(t,{action:"delete_env",scope:D,name:r});if(!(!d.current||b.current!==t||!m(s)||$("admin",v.peek()))){if(!o.ok){A(`삭제 실패: ${o.error.message}`);return}A(null),O(`${D}:${r} 삭제 완료`,"success")}},Se=e=>n`<${Ee} diffText=${e} inline=${!0} />`;return n`
    <div class="kp-scroll-pane" data-keeper-tab="config">
      <section class="kp-card" aria-label="Schema-Driven Keeper TOML 설정 편집기">
        <div class="kp-card-head">
          <h3>Keeper Config Schema (CAS)</h3>
          ${!a&&n`
            <div class="kp-pill-row">
              <span class="kp-pill">sha256: ${i?.file_sha256.slice(0,12)||"없음"}</span>
              <span class="kp-pill" data-tone=${T.length>0?"brass":"default"}>
                변경 ${T.length}건
              </span>
              <${Le} label="스키마 새로고침" onRefresh=${()=>V()} />
            </div>
          `}
        </div>

        ${a&&n`
          <div class="kp-empty" data-testid="keeper-config-admin-locked" role="status">
            Keeper TOML 설정 스키마 조회 및 변경은 관리자 전용입니다.
          </div>
        `}

        ${!a&&se&&n`
          <div class="ap-error" role="alert" data-cas-conflict="true">
            CAS 충돌 (409 conflict_cas): 다른 변경이 먼저 적용되었습니다. 스키마를 다시 불러온 뒤 적용하세요.
          </div>
        `}
        ${!a&&W.length>0&&n`
          <div class="ap-error" role="alert">
            유효하지 않은 입력 값: ${W.join(", ")}
          </div>
        `}
        ${!a&&re&&!se&&n`<div class="ap-error" role="alert">${re}</div>`}

        ${!a&&i&&n`
          <div class="kp-tabs" role="tablist" aria-label="설정 카테고리">
            ${i.categories.map(e=>n`
              <button
                key=${e.id}
                type="button"
                role="tab"
                class="kp-tab"
                aria-selected=${Q?.id===e.id?"true":"false"}
                onClick=${()=>S(e.id)}
              >
                ${e.title} (${e.field_count})
              </button>
            `)}
          </div>

          ${Q&&n`
            <div>
              ${Q.fields.map(e=>{const r=h[e.full_key]??te(e.current_value),t=e.writable?null:Ve(e.full_key,e.current_value);return n`
                  <div key=${e.full_key} class="kp-field-row">
                    <div>
                      <div class="kp-roster-name">
                        ${e.label??e.full_key}
                        <span class="kp-pill" data-tone=${e.reload_scope==="restart_required"?"warn":"info"}>
                          ${e.reload_scope}
                        </span>
                      </div>
                      ${e.description&&n`<${Ie} class="kp-roster-sub" text=${e.description} />`}
                      <div class="kp-roster-sub">${e.description?e.provenance:`${e.type} · ${e.provenance}`}</div>
                    </div>
                    ${e.writable?e.type==="bool"||e.type==="boolean"?n`
                            <select
                              class="kp-input"
                              aria-label=${e.full_key}
                              value=${r||"false"}
                              onChange=${s=>x({...h,[e.full_key]:s.currentTarget.value})}
                            >
                              <option value="true">true</option>
                              <option value="false">false</option>
                            </select>
                          `:e.enum_values&&e.enum_values.length>0?n`
                              <select
                                class="kp-input"
                                aria-label=${e.full_key}
                                value=${r}
                                onChange=${s=>x({...h,[e.full_key]:s.currentTarget.value})}
                              >
                                ${e.enum_values.map(s=>n`<option key=${s} value=${s}>${s}</option>`)}
                              </select>
                            `:n`
                              <input
                                type=${e.secret?"password":"text"}
                                class="kp-input"
                                aria-label=${e.full_key}
                                value=${r}
                                onInput=${s=>x({...h,[e.full_key]:s.currentTarget.value})}
                              />
                            `:t?n`<span class=${`mono rt-cap-chip${t.gen?" rt-cap-chip--gen":""}`}>${t.label}</span>`:n`<span class="kp-pill">읽기 전용 (${te(e.current_value)||"없음"})</span>`}
                  </div>
                `})}
            </div>
          `}
        `}

        ${!a&&n`
          <div class="kp-lifecycle-bar">
            <button
              type="button"
              class="btn-ghost"
              disabled=${ne||T.length===0}
              onClick=${()=>{be(!0)}}
            >
              Dry-Run Unified Diff 미리보기
            </button>
            <button
              type="button"
              class="btn-primary"
              disabled=${ne||T.length===0}
              onClick=${()=>{be(!1)}}
            >
              CAS 설정 적용 (expected_sha256)
            </button>
          </div>
        `}

        ${!a&&g&&n`
          <div>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone=${g.applied?"ok":"info"}>
                ${g.applied?"적용 완료":"Dry-Run 미리보기"}
              </span>
              <span class="kp-pill" data-tone=${g.reload_scope==="restart_required"?"warn":"brass"}>
                reload_scope: ${g.reload_scope}
              </span>
              ${g.snapshot_id&&n`
                <span class="kp-pill">snapshot: ${g.snapshot_id}</span>
              `}
            </div>
            ${g.validation_warnings.map((e,r)=>n`
              <div key=${r} class="ap-error sev-warn">⚠ ${e}</div>
            `)}
            <pre class="kp-diff">${Se(g.unified_diff)}</pre>
          </div>
        `}
      </section>

      <!-- Secrets & OAuth Identity Section -->
      <div class="kp-grid-2">
        <section class="kp-card" aria-label="Keeper 시크릿 환경변수">
          <div class="kp-card-head">
            <h3>Secrets (Write-Only Env)</h3>
          </div>
          ${_e?n`
                <select
                  class="kp-input"
                  aria-label="시크릿 범위"
                  value=${D}
                  onChange=${e=>ye(e.currentTarget.value)}
                >
                  <option value="keeper">keeper (${l})</option>
                  <option value="shared">shared (workspace)</option>
                </select>
                <input
                  type="text"
                  class="kp-input"
                  placeholder="ENV_VAR_NAME"
                  aria-label="시크릿 이름"
                  value=${G}
                  onInput=${e=>oe(e.currentTarget.value)}
                />
                <input
                  type="password"
                  class="kp-input"
                  placeholder="시크릿 값 (저장 후 재표시되지 않음)"
                  aria-label="시크릿 값"
                  value=${J}
                  onInput=${e=>Y(e.currentTarget.value)}
                />
                <div class="kp-lifecycle-bar">
                  <button type="button" class="btn-primary" onClick=${()=>{Ce()}}>
                    시크릿 저장
                  </button>
                  <button type="button" class="kp-btn-danger" onClick=${()=>{we()}}>
                    시크릿 삭제
                  </button>
                </div>
                ${le&&n`<div class="ap-error" role="alert">${le}</div>`}
              `:n`
                <div class="kp-empty" data-testid="keeper-secrets-admin-locked" role="status">
                  ${L?"Keeper 시크릿 환경변수 관리는 관리자 전용입니다.":"Keeper 시크릿 환경변수 관리는 싱글유저 로컬 관리자 세션 전용입니다."}
                </div>
              `}
        </section>

        <section class="kp-card" aria-label="OAuth 연결 계정 및 도구">
          <div class="kp-card-head">
            <h3>OAuth Identity & Attached Tools</h3>
          </div>
          ${L?n`
          ${!z&&n`
            <div class="kp-roster-sub" data-testid="keeper-oauth-admin-locked" role="status">
              OAuth 연결·해제·앱 등록 변경은 관리자 전용입니다 (읽기 전용 보기).
            </div>
          `}
          ${pe&&n`<div class="ap-error" role="alert">${pe}</div>`}
          ${z&&_&&n`
            <div class="kp-block-card kp-block-card--tool" data-testid="keeper-config-oauth-flow" role="status">
              <div class="kp-card-head">
                <strong>${_.providerLabel} · ${_.phase}</strong>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{E.current?.cancel(),B(null)}}
                >
                  닫기
                </button>
              </div>
              <div class="kp-roster-sub">${_.message}</div>
              <div class="kp-pill-row">
                ${_.authorizeUrl&&n`
                  <a
                    class="btn-primary"
                    href=${_.authorizeUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    OAuth 인증 페이지 열기 ↗
                  </a>
                `}
                ${_.deviceCode&&n`
                  <span class="kp-pill" data-tone="brass">${_.deviceCode}</span>
                `}
              </div>
            </div>
          `}
          ${z&&k&&n`
            <form
              class="kp-block-card kp-block-card--memory"
              data-testid="keeper-config-oauth-client-form"
              onSubmit=${async e=>{e.preventDefault();const r=v.peek();if(r.kind!=="single_user_local"||$("admin",r)||!k.clientId.trim())return;const t=l,s=y(),o=k.providerLabel;ve(!0);const w=await Te({provider:k.provider,clientId:k.clientId,clientSecret:k.clientSecret,scopes:k.scopes});if(!(!d.current||b.current!==t||!m(s))){if(ve(!1),!w.ok){p(`앱 등록 실패: ${w.error.message}`);return}p(null),O(`${o} OAuth 앱 등록 완료`,"success"),K(null),C()}}}
            >
              <div class="kp-card-head">
                <strong>내 OAuth 앱 등록 · ${k.providerLabel}</strong>
                <button type="button" class="btn-ghost" onClick=${()=>K(null)}>닫기</button>
              </div>
              ${H&&n`
                <div class="kp-pill-row" data-testid="keeper-oauth-callback-url" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>
                  <span>Callback URL:</span>
                  <code class="mono" style=${{overflowWrap:"anywhere"}}>${H}</code>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>{Oe(H).then(e=>{d.current&&(e?(p(null),O("Callback URL 복사 완료","success")):p("Callback URL 복사에 실패했습니다."))})}}
                  >
                    복사
                  </button>
                </div>
              `}
              <input
                type="text"
                class="kp-input"
                aria-label="Keeper OAuth Client ID"
                placeholder="Client ID (필수)"
                required
                value=${k.clientId}
                onInput=${e=>{const r=e.currentTarget.value;K(t=>t?{...t,clientId:r}:null)}}
              />
              <input
                type="password"
                class="kp-input"
                aria-label="Keeper OAuth Client Secret"
                placeholder="Client Secret (공개 PKCE 앱은 비워두세요)"
                value=${k.clientSecret}
                onInput=${e=>{const r=e.currentTarget.value;K(t=>t?{...t,clientSecret:r}:null)}}
              />
              <input
                type="text"
                class="kp-input"
                aria-label="Keeper OAuth Scopes"
                placeholder="Scopes (선택)"
                value=${k.scopes}
                onInput=${e=>{const r=e.currentTarget.value;K(t=>t?{...t,scopes:r}:null)}}
              />
              <button type="submit" class="btn-primary" disabled=${de}>
                ${de?"저장 중…":"앱 저장"}
              </button>
            </form>
          `}
          ${ie.length===0?n`<div class="kp-empty">연결 가능한 OAuth 공급자 없음</div>`:ie.map(e=>n`
                <div key=${e.provider} class="kp-field-row">
                  <div>
                    <div class="kp-roster-name">${e.provider_label}</div>
                    <div class="kp-roster-sub">
                      ${e.problem?`⚠ ${e.problem}`:e.attached?`연결됨 · 도구 ${e.tools?.length??0}개`:"미연결"}
                    </div>
                  </div>
                  ${z&&n`
                    <div class="kp-pill-row">
                      ${e.provider!=="github"&&n`
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${()=>K({provider:e.provider,providerLabel:e.provider_label,clientId:"",clientSecret:"",scopes:""})}
                        >
                          앱 설정
                        </button>
                      `}
                      ${e.attached?n`
                            <button
                              type="button"
                              class="btn-ghost"
                              disabled=${e.switch_problem!=null}
                              onClick=${async()=>{const r=v.peek();if(r.kind!=="single_user_local"||$("admin",r))return;const t=l,s=y(),o=!(e.enabled??!0),w=await qe(t,e.provider,o);!d.current||b.current!==t||!m(s)||(w.ok?(p(null),O(`${e.provider_label} ${o?"활성화":"비활성화"}`,"success")):p(w.error.message),C())}}
                            >
                              ${e.enabled===!1?"켜기":"끄기"}
                            </button>
                            <button
                              type="button"
                              class="btn-ghost"
                              onClick=${async()=>{const r=v.peek();if(r.kind!=="single_user_local"||$("admin",r))return;const t=l,s=y(),o=await Be(t,e.provider);!d.current||b.current!==t||!m(s)||(o.ok?(p(null),O(`${e.provider_label} 도구 목록 갱신`,"success")):p(o.error.message),C())}}
                            >
                              갱신
                            </button>
                            <button
                              type="button"
                              class="kp-btn-danger"
                              onClick=${async()=>{const r=v.peek();if(r.kind!=="single_user_local"||$("admin",r))return;const t=l,s=y(),o=await Re(t,e.provider);!d.current||b.current!==t||!m(s)||(o.ok?(p(null),O(`${e.provider_label} 연결 해제됨`,"success")):p(o.error.message),C())}}
                            >
                              해제
                            </button>
                          `:n`
                            <button
                              type="button"
                              class="btn-primary"
                              onClick=${()=>{const r=v.peek();if(!(r.kind!=="single_user_local"||$("admin",r))){if(E.current?.cancel(),p(null),e.provider==="github"){E.current=xe({keeper:l,providerLabel:e.provider_label,onUpdate:t=>{B(t)},onSettled:t=>{t&&C()}});return}E.current=De({keeper:l,provider:e.provider,providerLabel:e.provider_label,onUpdate:t=>{B(t)},onSettled:t=>{t&&C()}})}}}
                            >
                              연결
                            </button>
                          `}
                    </div>
                  `}
                </div>
              `)}
              `:n`
                <div class="kp-empty" data-testid="keeper-oauth-admin-locked" role="status">
                  OAuth 연결 계정 및 도구 관리는 싱글유저 로컬 세션 전용입니다.
                </div>
              `}
        </section>
      </div>
    </div>
  `}export{gt as KeeperConfigTab};
