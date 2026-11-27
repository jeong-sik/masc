import{d as p,A as D,q as H,y as W,m as o}from"./vendor.js";import{A as N,Q as M,s as U,Y as O,B as P,o as I,aF as K,j as Y,aG as te,aH as Q,a7 as G,aI as F,aJ as se,a6 as q,a as ne,f as ae}from"./index.js";import{c as J}from"./copyable-code.js";import"./toast.js";function R(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function _(e){return typeof e=="string"&&e.length>0?e:null}const oe=864e13;function B(e){return typeof e=="number"&&Number.isSafeInteger(e)&&e>=0&&e<=oe?e:null}function re(e){if(!R(e)||!R(e.principal))throw new Error("Invalid whoami payload: missing principal");const t=_(e.principal.id),s=_(e.role);if(!t||!s||e.principal.kind!=="human")throw new Error("Invalid whoami payload: expected human principal");return{id:t,role:s==="admin"?"admin":s==="worker"||s==="member"?"member":"unrecognised"}}function ie(e,t){return N("/api/v1/auth/whoami",{fetchImpl:e,signal:t,decode:re})}function le(e){return M("POST","/auth/logout",void 0,{fetchImpl:e})}const ce=new Set(["open","expired","revoked","unknown"]);function de(e){return e==="read_only"?{runtimes:"all",channels:["direct"],effects:["read_state"]}:{runtimes:"all",channels:["direct"],effects:["invoke_model","manage_own_keeper","manage_own_provider","read_state","use_tool"]}}function j(e){if(e==="all")return"all";if(!Array.isArray(e))throw new Error("Invalid scope reach");const t=[];for(const s of e){const l=_(s);if(!l)throw new Error("Invalid scope label");t.push(l)}return t}function ue(e){if(!R(e)||!Array.isArray(e.pats))throw new Error("Invalid PAT list payload");const t=new Set,s=[];for(const l of e.pats){if(!R(l)||!R(l.scope))throw new Error("Invalid PAT row");const d=_(l.pat_id),b=B(l.issued_at_ms),c=l.expires_at_ms===null?null:B(l.expires_at_ms);if(!d||b===null||l.expires_at_ms!==null&&c===null)throw new Error("Invalid PAT metadata");if(t.has(d))throw new Error(`Duplicate PAT id: ${d}`);t.add(d);const f=typeof l.status=="string"?l.status:"",$=ce.has(f)?f:"unrecognised";s.push({id:d,scope:{runtimes:j(l.scope.runtimes),channels:j(l.scope.channels),effects:j(l.scope.allowed_effects)},issuedAtMs:b,expiresAtMs:c,status:$})}return s}function pe(e){if(!R(e))throw new Error("Invalid issued PAT payload");const t=_(e.pat_id),s=_(e.token);if(!t||!s)throw new Error("Issued PAT missing pat_id or token");return{id:t,token:s}}function ve(e,t){return N("/api/v1/auth/pats",{fetchImpl:e,signal:t,decode:ue})}function be(e,t,s){const l=de(e);return M("POST","/api/v1/auth/pats",{scope:{runtimes:l.runtimes,channels:l.channels,allowed_effects:l.effects},expires_at_ms:t},{fetchImpl:s,decode:pe})}function fe(e,t){return M("DELETE",`/api/v1/auth/pats/${encodeURIComponent(e)}`,void 0,{fetchImpl:t})}const X=/^[!-~]{1,255}$/;function Z(e){if(!R(e))throw new Error("Invalid identity object");const t=_(e.provider);if(!t)throw new Error("Identity missing provider");if(t==="github"){if(typeof e.user_id!="number"||!Number.isSafeInteger(e.user_id)||e.user_id<=0)throw new Error("Invalid GitHub user_id");return{provider:"github",userId:e.user_id}}if(t==="google"){const s=_(e.sub);if(!s||!X.test(s))throw new Error("Invalid Google sub");return{provider:"google",sub:s}}return{provider:"unrecognised"}}function ee(e){switch(e.provider){case"github":return`GitHub #${e.userId}`;case"google":return`Google (${e.sub})`;case"unrecognised":return"Unknown provider"}}const me=["security_incident","operational"],ge=new Set(["revoke","disable","delete"]);function he(e){if(!R(e)||!Array.isArray(e.members))throw new Error("Invalid members payload");const t=new Set,s=[];for(const l of e.members){if(!R(l)||!Array.isArray(l.held))throw new Error("Invalid member row");const d=_(l.user_id);if(!d)throw new Error("Member missing user_id");if(t.has(d))throw new Error(`Duplicate member user_id: ${d}`);t.add(d);const b=l.role==="admin"?"admin":l.role==="member"?"member":"unrecognised",c=l.status==="active"?"active":l.status==="disabled"?"disabled":"unrecognised",f=l.held.map($=>typeof $=="string"&&ge.has($)?$:"unrecognised");s.push({userId:d,identity:Z(l.identity),role:b,status:c,held:f})}return s}function $e(e,t){return N("/api/v1/auth/members",{fetchImpl:e,signal:t,decode:he})}function ke(e,t){return M("POST",`/api/v1/auth/members/${encodeURIComponent(e)}/disable`,void 0,{fetchImpl:t})}function we(e,t){return M("POST",`/api/v1/auth/members/${encodeURIComponent(e)}/enable`,void 0,{fetchImpl:t})}function ye(e,t,s){if(t!=="security_incident"&&t!=="operational")throw new Error(`Invalid revoke-admin cause: ${String(t)}`);return M("POST",`/api/v1/auth/members/${encodeURIComponent(e)}/revoke-admin`,{cause:t},{fetchImpl:s})}function Ie(e,t){return M("DELETE",`/api/v1/auth/members/${encodeURIComponent(e)}`,void 0,{fetchImpl:t})}function Ae(e){if(!R(e)||!Array.isArray(e.invites))throw new Error("Invalid invites payload");const t=[];for(const s of e.invites){if(!R(s)||!R(s.issuer))throw new Error("Invalid invite row");const l=_(s.invite_id),d=s.role==="member"||s.role==="admin"?s.role:null,b=B(s.expires_at_ms);if(!l||!d||b===null)throw new Error("Invalid invite metadata");let c;if(s.issuer.kind==="local_operator")c={kind:"local_operator"};else if(s.issuer.kind==="admin"&&_(s.issuer.user_id))c={kind:"admin",userId:String(s.issuer.user_id)};else throw new Error("Invalid invite issuer");let f;switch(s.status){case"consumed":{const $=_(s.user_id);if(!$)throw new Error("Consumed invite missing user_id");f={kind:"consumed",joined:$};break}case"open":case"expired":case"revocation_pending":case"revoked":f={kind:s.status};break;default:f={kind:"unrecognised"}}t.push({id:l,role:d,issuer:c,expiresAtMs:b,status:f})}return t}function _e(e){if(!R(e))throw new Error("Invalid issued invite");const t=_(e.invite_id),s=e.role==="member"||e.role==="admin"?e.role:null,l=B(e.expires_at_ms),d=_(e.link);if(!t||!s||l===null||!d)throw new Error("Issued invite incomplete");return{id:t,role:s,expiresAtMs:l,link:d}}function Se(e,t){return N("/api/v1/auth/invites",{fetchImpl:e,signal:t,decode:Ae})}function Ee(e,t){return M("POST","/api/v1/auth/invites",{role:e},{fetchImpl:t,decode:_e})}function Ce(e,t){return M("DELETE",`/api/v1/auth/invites/${encodeURIComponent(e)}`,void 0,{fetchImpl:t})}function Re(e){if(!R(e)||!Array.isArray(e.registrations))throw new Error("Invalid allowlist payload");const t=[];for(const s of e.registrations){if(!R(s))throw new Error("Invalid allowlist row");const l=_(s.registration_id),d=_(s.registrar);if(!l||!d)throw new Error("Allowlist row missing fields");let b;switch(s.status){case"consumed":{const c=_(s.user_id);if(!c)throw new Error("Consumed allowlist entry missing user_id");b={kind:"consumed",joined:c};break}case"open":case"removal_pending":case"removed":b={kind:s.status};break;default:b={kind:"unrecognised"}}t.push({id:l,identity:Z(s.identity),registrar:d,status:b})}return t}function Te(e){if(!R(e))throw new Error("Invalid allowlist registration response");const t=_(e.registration_id);if(!t||typeof e.previously_deleted!="boolean")throw new Error("Allowlist registration missing fields");return{id:t,previouslyDeleted:e.previously_deleted}}function Oe(e,t){return N("/api/v1/auth/allowlist",{fetchImpl:e,signal:t,decode:Re})}function Pe(e,t){const s=e.provider==="github"?{provider:"github",user_id:e.userId}:{provider:"google",sub:e.sub};return M("POST","/api/v1/auth/allowlist",s,{fetchImpl:t,decode:Te})}function Me(e,t){return M("DELETE",`/api/v1/auth/allowlist/${encodeURIComponent(e)}`,void 0,{fetchImpl:t})}function Le(e){return e.kind==="consumed"?`consumed (${e.joined})`:e.kind}function De(){const e=U.value,[t,s]=p([]),[l,d]=p(!0),[b,c]=p(null),[f,$]=p("google"),[S,A]=p(""),[v,m]=p(!1),[k,y]=p(null),[L,E]=p(!1),h=D(!0),C=D(null),w=H(async()=>{C.current?.abort();const i=new AbortController;C.current=i;const r=O();d(!0),c(null);const a=await Oe(void 0,i.signal);!h.current||i.signal.aborted||!P(r)||(a.ok?(s(a.value),E(!0)):a.error.kind!=="epoch_stale"&&a.error.kind!=="aborted"&&c(a.error.message),d(!1))},[]);W(()=>(h.current=!0,s([]),E(!1),c(null),y(null),w(),()=>{h.current=!1,C.current?.abort()}),[w,e]);const T=async i=>{if(i.preventDefault(),v)return;const r=S.trim();let a;if(f==="github"){const g=Number(r);if(!Number.isSafeInteger(g)||g<=0||String(g)!==r){c("GitHub user_id는 양의 정수여야 합니다.");return}a={provider:"github",userId:g}}else{if(!X.test(r)){c("Google sub는 공백 없는 1~255자 ASCII 문자열이어야 합니다.");return}a={provider:"google",sub:r}}const u=O();m(!0),c(null);try{const g=await Pe(a);if(!h.current||!P(u))return;if(!g.ok){c(g.error.message);return}A(""),I(g.value.previouslyDeleted?"허용 목록 등록 완료 (이전 삭제 계정은 새 사용자로 재가입합니다).":"허용 목록에 등록되었습니다.","success"),await w()}finally{h.current&&m(!1)}},n=async i=>{const r=O();y(i);try{const a=await Me(i);if(!h.current||!P(r))return;if(!a.ok){c(a.error.message);return}I(`허용 목록 항목 제거 (${i})`,"info"),await w()}finally{h.current&&y(null)}};return o`
    <div class="ap-acct-stack" data-testid="account-allowlist-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Register Sign-In Allowlist Entry</h2>
            <p class="ap-card-sub">
              Pre-authorize a Google subject or GitHub numeric user ID to sign in directly as a Member.
            </p>
          </div>
        </header>

        <form class="ap-form-row" onSubmit=${i=>{T(i)}}>
          <label class="ap-field">
            <span>Identity Provider</span>
            <select
              class="ap-input"
              value=${f}
              onChange=${i=>{$(i.currentTarget.value),A(""),c(null)}}
            >
              <option value="google">Google OIDC (sub)</option>
              <option value="github">GitHub OAuth (user_id)</option>
            </select>
          </label>

          <label class="ap-field ap-field--grow">
            <span>${f==="google"?"Google sub":"GitHub numeric user_id"}</span>
            <input
              type="text"
              class="ap-input mono"
              required
              placeholder=${f==="google"?"109876543210987654321":"1234567"}
              value=${S}
              onInput=${i=>A(i.currentTarget.value)}
            />
          </label>

          <button type="submit" class="btn-primary" disabled=${v}>
            ${v?"Registering…":"Register"}
          </button>
        </form>
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <h2 class="ap-card-title">Allowlist Registrations (${t.length})</h2>
          <button type="button" class="btn-ghost" onClick=${()=>{w()}}>Refresh</button>
        </header>

        ${b&&o`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${b}</div>`}
        ${l?o`<p class="ap-muted">허용 목록을 불러오는 중…</p>`:t.length===0?b||!L?null:o`<p class="ap-muted">등록된 허용 목록 항목이 없습니다.</p>`:o`
                <ul class="ap-acct-list">
                  ${t.map(i=>{const r=i.status.kind==="open"||i.status.kind==="removal_pending";return o`
                      <li key=${i.id} class="ap-acct-row" data-allowlist-id=${i.id}>
                        <div>
                          <div class="ap-acct-row-top">
                            <strong>${ee(i.identity)}</strong>
                            <span class=${`ap-badge ap-badge--${i.status.kind==="open"?"ok":i.status.kind==="removal_pending"?"warn":"muted"}`}>
                              ${Le(i.status)}
                            </span>
                          </div>
                          <div class="ap-muted mono">
                            id=${i.id} · registrar=${i.registrar}
                          </div>
                        </div>
                        ${r&&o`
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${k===i.id}
                            onClick=${()=>{n(i.id)}}
                          >
                            ${k===i.id?"Removing…":"Remove"}
                          </button>
                        `}
                      </li>
                    `})}
                </ul>
              `}
      </section>
    </div>
  `}function xe(e){return e.kind==="consumed"?`consumed (${e.joined})`:e.kind}function Ue(){const e=U.value,[t,s]=p([]),[l,d]=p(!0),[b,c]=p(null),[f,$]=p("member"),[S,A]=p(!1),[v,m]=p(null),[k,y]=p(null),[L,E]=p(!1),h=D(!0),C=D(null),w=H(async()=>{C.current?.abort();const r=new AbortController;C.current=r;const a=O();d(!0),c(null);const u=await Se(void 0,r.signal);!h.current||r.signal.aborted||!P(a)||(u.ok?(s(u.value),E(!0)):u.error.kind!=="epoch_stale"&&u.error.kind!=="aborted"&&c(u.error.message),d(!1))},[]);W(()=>{h.current=!0,s([]),E(!1),c(null),m(null),y(null),w();const r=()=>m(null);return window.addEventListener("pagehide",r),()=>{h.current=!1,C.current?.abort(),window.removeEventListener("pagehide",r),m(null)}},[w,e]);const T=async r=>{if(r.preventDefault(),S)return;const a=O();A(!0),c(null);try{const u=await Ee(f);if(!h.current||!P(a))return;if(!u.ok){c(u.error.message);return}m(u.value),I(`초대 링크가 생성되었습니다 (${f}).`,"success"),await w()}finally{h.current&&A(!1)}},n=async r=>{const a=O();y(r);try{const u=await Ce(r);if(!h.current||!P(a))return;if(!u.ok){c(u.error.message);return}I(`초대 취소 완료 (${r})`,"info"),await w()}finally{h.current&&y(null)}},i=v&&typeof window<"u"?new URL(v.link,window.location.origin).href:v?.link??"";return o`
    <div class="ap-acct-stack" data-testid="account-invites-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Create Invitation</h2>
            <p class="ap-card-sub">
              One-time onboarding links for new Members or Admins. Token fragment is shown only once.
            </p>
          </div>
        </header>

        <form class="ap-form-row" onSubmit=${r=>{T(r)}}>
          <label class="ap-field">
            <span>Role</span>
            <select
              class="ap-input"
              value=${f}
              onChange=${r=>$(r.currentTarget.value)}
            >
              <option value="member">Member (Worker)</option>
              <option value="admin">Admin</option>
            </select>
          </label>
          <button type="submit" class="btn-primary" disabled=${S}>
            ${S?"Creating…":"Create Invite Link"}
          </button>
        </form>

        ${v&&o`
          <div class="ap-secret-box" role="status" data-testid="issued-invite-link">
            <div class="ap-secret-head">
              <strong>One-time invite link (${v.role})</strong>
              <button type="button" class="btn-ghost" onClick=${()=>m(null)}>Dismiss</button>
            </div>
            <div class="ap-secret-value">
              <code class="mono">${i}</code>
              <button
                type="button"
                class="btn-primary"
                onClick=${()=>{J(i).then(r=>{r?I("초대 링크를 복사했습니다.","success"):I("클립보드 복사에 실패했습니다. 링크를 직접 선택해 복사하세요.","error")})}}
              >
                Copy
              </button>
            </div>
          </div>
        `}
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <h2 class="ap-card-title">Invitations (${t.length})</h2>
          <button type="button" class="btn-ghost" onClick=${()=>{w()}}>Refresh</button>
        </header>

        ${b&&o`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${b}</div>`}
        ${l?o`<p class="ap-muted">초대 목록을 불러오는 중…</p>`:t.length===0?b||!L?null:o`<p class="ap-muted">발급된 초대가 없습니다.</p>`:o`
                <ul class="ap-acct-list">
                  ${t.map(r=>{const a=r.status.kind==="open"||r.status.kind==="expired"||r.status.kind==="revocation_pending";return o`
                      <li key=${r.id} class="ap-acct-row" data-invite-id=${r.id}>
                        <div>
                          <div class="ap-acct-row-top">
                            <code class="mono">${r.id}</code>
                            <span class=${`ap-badge ap-badge--${r.role==="admin"?"brass":"muted"}`}>
                              ${r.role}
                            </span>
                            <span class=${`ap-badge ap-badge--${r.status.kind==="open"?"ok":r.status.kind==="revocation_pending"?"warn":"muted"}`}>
                              ${xe(r.status)}
                            </span>
                          </div>
                          <div class="ap-muted mono">
                            issuer: ${r.issuer.kind==="local_operator"?"local_operator":r.issuer.userId} ·
                            expires ${new Date(r.expiresAtMs).toISOString().slice(0,16).replace("T"," ")}
                          </div>
                        </div>
                        ${a&&o`
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${k===r.id}
                            onClick=${()=>{n(r.id)}}
                          >
                            ${k===r.id?"Revoking…":"Revoke"}
                          </button>
                        `}
                      </li>
                    `})}
                </ul>
              `}
      </section>
    </div>
  `}function We({session:e}){const[t,s]=p(""),[l,d]=p(null),[b,c]=p(!1),[f,$]=p(""),[S,A]=p(""),[v,m]=p(null),k=K.value,y=Y.value,L=U.value,E=D(!1),h=D(!0);W(()=>(h.current=!0,()=>{h.current=!1}),[]);const C=async n=>{if(n.preventDefault(),!E.current){E.current=!0,d(null),c(!0);try{const i=await se(t);if(!h.current)return;i.ok?(s(""),I("Local Operator 인증이 확인되었습니다.","success"),G()):(d(i.error),I(`인증 실패: ${i.error}`,"error"))}finally{E.current=!1,h.current&&c(!1)}}},w=n=>{n.preventDefault(),m(null);const i=f.trim(),r=S.trim();if(!i){m("워크스페이스 이름을 입력하세요.");return}let a;if(r)if(/^\/(?!\/)/.test(r))a=r.replace(/\/+$/,"")||"/";else try{const x=new URL(r);if(x.protocol!=="http:"&&x.protocol!=="https:"){m("동일 Origin의 http(s) URL 또는 상대 경로 접두사(예: /workspace-b)만 등록할 수 있습니다.");return}if(typeof window<"u"&&window.location?.origin&&x.origin!==window.location.origin){m("교차 출처(Cross-Origin) URL은 보안 정책상 차단됩니다. 동일 Origin URL 또는 상대 경로 접두사(/prefix)를 사용하세요.");return}a=`${x.origin}${x.pathname.replace(/\/+$/,"")}`}catch{m("올바른 경로 접두사(/workspace-b) 또는 동일 Origin URL을 입력하세요.");return}const u=i.toLowerCase().replace(/[^a-z0-9-]+/g,"-").replace(/^-|-$/g,"")||`ws-${Date.now()}`;let g=u,z=k.length+1;for(;k.some(x=>x.id===g);)g=`${u}-${z}`,z+=1;F([...k,{id:g,label:i,...a?{baseUrl:a}:{}}]),$(""),A(""),I(`워크스페이스 추가됨: ${i}`,"success")},T=n=>{k.length<=1||(F(k.filter(i=>i.id!==n)),I(`워크스페이스 제거됨 (${n})`,"info"))};return o`
    <div class="ap-acct-stack" data-testid="account-local-operator">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Local Operator & Bearer Access</h2>
            <p class="ap-card-sub">
              Single-user server mode. Accepts <code>?token=</code> from <code>masc login</code> (stripped from URL history) and keeps the bearer in tab-scoped sessionStorage (never localStorage).
            </p>
          </div>
          <span class=${`ap-badge ap-badge--${e.kind==="single_user_local"?"ok":"warn"}`}>
            ${e.kind==="single_user_local"?e.tokenPresent?"Bearer Active":"Local Trusted":"Auth Required"}
          </span>
        </header>

        ${e.kind==="single_user_auth_required"&&o`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            <div>${e.reason} — Paste an operator Bearer token below, or run in terminal:</div>
            <code class="mono">eval "$(masc login --agent local-dashboard-admin --role admin --client-env MASC_ADMIN_TOKEN --no-expiry --shell)" && open "$MASC_DASHBOARD_URL"</code>
          </div>
        `}

        <dl class="ap-kv-grid mono">
          <div><dt>Account Mode</dt><dd>single_user</dd></div>
          <div><dt>Dev-Token Advertised</dt><dd>${e.authMethods.dev_token?"true":"false (no probe)"}</dd></div>
          <div><dt>Active Workspace</dt><dd>${y}</dd></div>
          <div><dt>Session Epoch</dt><dd class="tnum">${String(L)}</dd></div>
        </dl>

        <form class="ap-form-row" onSubmit=${n=>{C(n)}}>
          <label class="ap-field ap-field--grow">
            <span>Operator Bearer Token</span>
            <input
              type="password"
              class="ap-input mono"
              placeholder="Paste MASC operator bearer token…"
              value=${t}
              onInput=${n=>s(n.currentTarget.value)}
            />
          </label>
          <button type="submit" class="btn-primary" disabled=${b}>
            ${b?"Verifying…":"Apply & Verify"}
          </button>
          ${e.kind==="single_user_local"&&e.tokenPresent&&o`
            <button
              type="button"
              class="btn-ghost"
              onClick=${()=>{te(null),I("Bearer 토큰이 제거되었습니다.","info")}}
            >
              Clear Token
            </button>
          `}
        </form>
        ${l&&o`<div class="ap-inline-alert ap-inline-alert--err" role="alert" data-testid="local-token-error">${l}</div>`}
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Multi-Workspace Targets (${k.length})</h2>
            <p class="ap-card-sub">
              Register MASC server targets. Switching targets increments sessionEpoch and drops stale in-flight responses.
            </p>
          </div>
        </header>

        <ul class="ap-acct-list">
          ${k.map(n=>{const i=n.id===y;return o`
              <li key=${n.id} class="ap-acct-row" data-ws-row=${n.id}>
                <div>
                  <strong>${n.label}</strong>
                  <div class="mono ap-muted">${n.baseUrl??"same-origin"} · id=${n.id}</div>
                </div>
                <div class="ap-acct-actions">
                  <button
                    type="button"
                    class=${i?"btn-primary":"btn-ghost"}
                    disabled=${i}
                    onClick=${()=>{Q(n.id)&&(I(`워크스페이스 전환: ${n.label}`,"info"),G())}}
                  >
                    ${i?"Active":"Switch"}
                  </button>
                  ${k.length>1&&n.id!=="default"&&o`
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${()=>T(n.id)}
                    >
                      Remove
                    </button>
                  `}
                </div>
              </li>
            `})}
        </ul>

        <form class="ap-form-row" onSubmit=${w}>
          <label class="ap-field">
            <span>Workspace Label</span>
            <input
              type="text"
              class="ap-input"
              placeholder="e.g. Staging MASC"
              value=${f}
              onInput=${n=>$(n.currentTarget.value)}
            />
          </label>
          <label class="ap-field ap-field--grow">
            <span>Same-Origin Path Prefix or URL (optional)</span>
            <input
              type="text"
              class="ap-input mono"
              placeholder="/workspace-b"
              value=${S}
              onInput=${n=>A(n.currentTarget.value)}
            />
          </label>
          <button type="submit" class="btn-primary">Add Target</button>
        </form>
        ${v&&o`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${v}</div>`}
      </section>
    </div>
  `}const Ge=Object.freeze({security_incident:"security_incident — 보안 사고 대응",operational:"operational — 운영 권한 조정"});function Ne(){const e=U.value,[t,s]=p([]),[l,d]=p(!0),[b,c]=p(null),[f,$]=p(()=>new Set),[S,A]=p(null),[v,m]=p(""),[k,y]=p(null),[L,E]=p(!1),h=D(!0),C=D(null),w=H(async()=>{C.current?.abort();const n=new AbortController;C.current=n;const i=O();d(!0),c(null);const r=await $e(void 0,n.signal);!h.current||n.signal.aborted||!P(i)||(r.ok?(s(r.value),E(!0)):r.error.kind!=="epoch_stale"&&r.error.kind!=="aborted"&&c(r.error.message),d(!1))},[]);W(()=>(h.current=!0,s([]),E(!1),c(null),$(new Set),A(null),m(""),y(null),w(),()=>{h.current=!1,C.current?.abort()}),[w,e]);const T=async(n,i,r)=>{const a=O();$(u=>{const g=new Set(u);return g.add(n),g}),c(null);try{const u=await r();if(!h.current||!P(a))return;if(!u.ok){c(u.error?.message??`${i} failed`);return}I(`${i}: ${n}`,"success"),A(null),m(""),y(null),await w()}finally{h.current&&$(u=>{if(!u.has(n))return u;const g=new Set(u);return g.delete(n),g})}};return o`
    <section class="ap-card" data-testid="account-members-tab">
      <header class="ap-card-head">
        <div>
          <h2 class="ap-card-title">Members & Admin Lifecycle (${t.length})</h2>
          <p class="ap-card-sub">
            Admin-only principal management. Server enforces the last-active-Admin invariant (HTTP 409) and requires an explicit closed-sum cause to revoke Admin privileges.
          </p>
        </div>
        <button type="button" class="btn-ghost" onClick=${()=>{w()}}>Refresh</button>
      </header>

      ${b&&o`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${b}</div>`}

      ${l?o`<p class="ap-muted">구성원 목록을 불러오는 중…</p>`:t.length===0?b||!L?null:o`<p class="ap-muted">등록된 구성원이 없습니다.</p>`:o`
              <ul class="ap-acct-list">
                ${t.map(n=>{const i=f.has(n.userId),r=S===n.userId,a=k===n.userId;return o`
                    <li key=${n.userId} class="ap-acct-row ap-acct-row--col" data-member-id=${n.userId}>
                      <div class="ap-acct-row-split">
                        <div>
                          <div class="ap-acct-row-top">
                            <code class="mono">${n.userId}</code>
                            <span class=${`ap-badge ap-badge--${n.role==="admin"?"brass":"muted"}`}>
                              ${n.role}
                            </span>
                            <span class=${`ap-badge ap-badge--${n.status==="active"?"ok":"warn"}`}>
                              ${n.status}
                            </span>
                            ${n.held.map(u=>o`
                              <span key=${u} class="ap-badge ap-badge--err">held:${u}</span>
                            `)}
                          </div>
                          <div class="ap-muted mono">${ee(n.identity)}</div>
                        </div>

                        <div class="ap-acct-actions">
                          ${n.status==="active"?o`
                                <button
                                  type="button"
                                  class="btn-ghost"
                                  disabled=${i}
                                  data-action="disable"
                                  onClick=${()=>{T(n.userId,"Disable member",()=>ke(n.userId))}}
                                >
                                  Disable
                                </button>
                              `:n.status==="disabled"?o`
                                  <button
                                    type="button"
                                    class="btn-ghost"
                                    disabled=${i}
                                    data-action="enable"
                                    onClick=${()=>{T(n.userId,"Enable member",()=>we(n.userId))}}
                                  >
                                    Enable
                                  </button>
                                `:null}

                          ${n.role==="admin"&&o`
                            <button
                              type="button"
                              class="btn-ghost"
                              disabled=${i}
                              data-action="open-revoke-admin"
                              onClick=${()=>{y(null),A(r?null:n.userId),m("")}}
                            >
                              Revoke Admin
                            </button>
                          `}

                          <button
                            type="button"
                            class="btn-ghost ap-danger-btn"
                            disabled=${i}
                            data-action="open-delete"
                            onClick=${()=>{A(null),y(a?null:n.userId)}}
                          >
                            Delete
                          </button>
                        </div>
                      </div>

                      ${r&&o`
                        <form
                          class="ap-inline-panel"
                          data-testid="revoke-admin-form"
                          onSubmit=${u=>{u.preventDefault(),!(v!=="security_incident"&&v!=="operational")&&T(n.userId,`Revoke Admin (${v})`,()=>ye(n.userId,v))}}
                        >
                          <label class="ap-field">
                            <span>Revocation Cause (required closed-sum)</span>
                            <select
                              class="ap-input"
                              required
                              aria-label="Admin 권한 회수 사유"
                              value=${v}
                              onChange=${u=>m(u.currentTarget.value)}
                            >
                              <option value="">사유를 선택하세요…</option>
                              ${me.map(u=>o`
                                <option key=${u} value=${u}>${Ge[u]}</option>
                              `)}
                            </select>
                          </label>
                          <div class="ap-acct-actions">
                            <button
                              type="submit"
                              class="btn-primary"
                              disabled=${i||v!=="security_incident"&&v!=="operational"}
                            >
                              Confirm Revoke Admin
                            </button>
                            <button type="button" class="btn-ghost" onClick=${()=>{A(null),m("")}}>
                              Cancel
                            </button>
                          </div>
                        </form>
                      `}

                      ${a&&o`
                        <div class="ap-inline-panel ap-inline-panel--err" data-testid="delete-member-confirm">
                          <span>
                            계정 <code class="mono">${n.userId}</code> 을(를) 영구 삭제합니다. 마지막 활성 Admin은 삭제할 수 없습니다.
                          </span>
                          <div class="ap-acct-actions">
                            <button
                              type="button"
                              class="btn-primary ap-danger-solid"
                              disabled=${i}
                              onClick=${()=>{T(n.userId,"Delete member",()=>Ie(n.userId))}}
                            >
                              Confirm Delete
                            </button>
                            <button type="button" class="btn-ghost" onClick=${()=>y(null)}>
                              Cancel
                            </button>
                          </div>
                        </div>
                      `}
                    </li>
                  `})}
              </ul>
            `}
    </section>
  `}function Be(e){switch(e){case"never":return null;case"7d":return Date.now()+7*864e5;case"30d":return Date.now()+30*864e5;case"90d":return Date.now()+90*864e5}}function V(e){return e===null?"만료 없음":new Date(e).toISOString().slice(0,16).replace("T"," ")}function He(){const e=U.value,[t,s]=p([]),[l,d]=p(!0),[b,c]=p(null),[f,$]=p("read_only"),[S,A]=p("30d"),[v,m]=p(!1),[k,y]=p(null),[L,E]=p(null),[h,C]=p(!1),w=D(!0),T=D(null),n=H(async()=>{T.current?.abort();const a=new AbortController;T.current=a;const u=O();d(!0),c(null);const g=await ve(void 0,a.signal);!w.current||a.signal.aborted||!P(u)||(g.ok?(s(g.value),C(!0)):g.error.kind!=="epoch_stale"&&g.error.kind!=="aborted"&&c(g.error.message),d(!1))},[]);W(()=>{w.current=!0,s([]),C(!1),c(null),y(null),E(null),n();const a=()=>y(null);return window.addEventListener("pagehide",a),()=>{w.current=!1,T.current?.abort(),window.removeEventListener("pagehide",a),y(null)}},[n,e]);const i=async a=>{if(a.preventDefault(),v)return;const u=O();m(!0),c(null);try{const g=await be(f,Be(S));if(!w.current||!P(u))return;if(!g.ok){c(g.error.message);return}y(g.value),I("새 Personal Access Token이 발급되었습니다.","success"),await n()}finally{w.current&&m(!1)}},r=async a=>{const u=O();E(a);try{const g=await fe(a);if(!w.current||!P(u))return;if(!g.ok){c(g.error.message);return}I(`토큰 폐기 완료 (${a})`,"info"),await n()}finally{w.current&&E(null)}};return o`
    <div class="ap-acct-stack" data-testid="account-pats-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Issue Personal Access Token</h2>
            <p class="ap-card-sub">
              Scoped bearer credentials for CLI / MCP clients. Raw secrets are shown once and never stored in browser storage.
            </p>
          </div>
        </header>

        <form class="ap-form-row" onSubmit=${a=>{i(a)}}>
          <label class="ap-field">
            <span>Scope Preset</span>
            <select
              class="ap-input"
              value=${f}
              onChange=${a=>$(a.currentTarget.value)}
            >
              <option value="read_only">Read-Only (whoami & state)</option>
              <option value="mcp">MCP Full (Keeper turns, tools & own providers)</option>
            </select>
          </label>

          <label class="ap-field">
            <span>Expiration</span>
            <select
              class="ap-input"
              value=${S}
              onChange=${a=>A(a.currentTarget.value)}
            >
              <option value="7d">7 days</option>
              <option value="30d">30 days</option>
              <option value="90d">90 days</option>
              <option value="never">No expiration</option>
            </select>
          </label>

          <button type="submit" class="btn-primary" disabled=${v}>
            ${v?"Issuing…":"Issue Token"}
          </button>
        </form>

        ${k&&o`
          <div class="ap-secret-box" role="status" data-testid="issued-pat-secret">
            <div class="ap-secret-head">
              <strong>One-time token issued (${k.id}) — copy now; it cannot be shown again.</strong>
              <button type="button" class="btn-ghost" onClick=${()=>y(null)}>Dismiss</button>
            </div>
            <div class="ap-secret-value">
              <code class="mono">${k.token}</code>
              <button
                type="button"
                class="btn-primary"
                onClick=${()=>{J(k.token).then(a=>{a?I("토큰을 클립보드에 복사했습니다.","success"):I("클립보드 복사에 실패했습니다. 토큰을 직접 선택해 복사하세요.","error")})}}
              >
                Copy
              </button>
            </div>
          </div>
        `}
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <h2 class="ap-card-title">Issued Tokens (${t.length})</h2>
          <button type="button" class="btn-ghost" onClick=${()=>{n()}}>Refresh</button>
        </header>

        ${b&&o`<div class="ap-inline-alert ap-inline-alert--err" role="alert">${b}</div>`}
        ${l?o`<p class="ap-muted">토큰 목록을 불러오는 중…</p>`:t.length===0?b||!h?null:o`<p class="ap-muted">발급된 Personal Access Token이 없습니다.</p>`:o`
                <ul class="ap-acct-list">
                  ${t.map(a=>o`
                    <li key=${a.id} class="ap-acct-row" data-pat-id=${a.id}>
                      <div>
                        <div class="ap-acct-row-top">
                          <code class="mono">${a.id}</code>
                          <span class=${`ap-badge ap-badge--${a.status==="open"?"ok":a.status==="revoked"?"err":"muted"}`}>
                            ${a.status}
                          </span>
                        </div>
                        <div class="ap-muted mono">
                          issued ${V(a.issuedAtMs)} · expires ${V(a.expiresAtMs)}
                        </div>
                        <div class="ap-muted mono">
                          effects: ${a.scope.effects==="all"?"all":a.scope.effects.join(", ")}
                        </div>
                      </div>
                      ${a.status==="open"&&o`
                        <button
                          type="button"
                          class="btn-ghost"
                          disabled=${L===a.id}
                          onClick=${()=>{r(a.id)}}
                        >
                          ${L===a.id?"Revoking…":"Revoke"}
                        </button>
                      `}
                    </li>
                  `)}
                </ul>
              `}
      </section>
    </div>
  `}function je({session:e}){const[t,s]=p(null),[l,d]=p(null),[b,c]=p(!1),f=K.value,$=Y.value,S=U.value;W(()=>{let v=!1;const m=new AbortController;return s(null),d(null),ie(void 0,m.signal).then(k=>{v||m.signal.aborted||(k.ok?s(k.value):k.error.kind!=="epoch_stale"&&k.error.kind!=="aborted"&&d(k.error.message))}),()=>{v=!0,m.abort()}},[e.accountId,S]);const A=async()=>{if(!b){c(!0);try{const v=await le();if(!v.ok&&v.error.kind!=="unauthorized"){I(`로그아웃 실패: ${v.error.message}`,"error");return}I("로그아웃되었습니다.","info"),await q()}finally{c(!1)}}};return o`
    <div class="ap-acct-stack" data-testid="account-profile-tab">
      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Profile & Active Browser Session</h2>
            <p class="ap-card-sub">
              Cookie-authenticated same-origin session with CSRF header protection (zero tokens stored in Web Storage).
            </p>
          </div>
          <button
            type="button"
            class="btn-ghost"
            disabled=${b}
            onClick=${()=>{A()}}
          >
            ${b?"Signing out…":"Sign out"}
          </button>
        </header>

        <dl class="ap-kv-grid mono">
          <div><dt>Principal</dt><dd>${e.displayName}</dd></div>
          <div><dt>Account ID</dt><dd>${t?.id??e.accountId}</dd></div>
          <div><dt>Role</dt><dd>${e.role==="admin"?"Admin":e.role==="worker"?"Worker (Member)":"Viewer"}</dd></div>
          <div><dt>Email</dt><dd>${e.email??"없음"}</dd></div>
          <div><dt>Session Epoch</dt><dd class="tnum">${String(S)}</dd></div>
          <div><dt>CSRF Guard</dt><dd>${e.csrfToken?"Active":"Missing"}</dd></div>
        </dl>

        ${l&&o`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            whoami 조회 실패: ${l}
          </div>
        `}
      </section>

      <section class="ap-card">
        <header class="ap-card-head">
          <div>
            <h2 class="ap-card-title">Connected Workspace Targets</h2>
            <p class="ap-card-sub">
              Switching workspace increments the monotonic session epoch and drops stale in-flight fetches.
            </p>
          </div>
        </header>

        <ul class="ap-acct-list">
          ${f.map(v=>{const m=v.id===$;return o`
              <li key=${v.id} class="ap-acct-row">
                <div>
                  <strong>${v.label}</strong>
                  <div class="mono ap-muted">${v.baseUrl??v.id}</div>
                </div>
                <button
                  type="button"
                  class=${m?"btn-primary":"btn-ghost"}
                  disabled=${m}
                  onClick=${()=>{Q(v.id)&&(I(`워크스페이스 전환: ${v.label}`,"info"),G())}}
                >
                  ${m?"Active":"Switch"}
                </button>
              </li>
            `})}
        </ul>
      </section>
    </div>
  `}const qe=new Set(["members","invites","allowlist"]);function ze({onNavigate:e}){return o`
    <p
      class="ap-muted"
      role="note"
      data-testid="account-provider-callout"
      style=${{margin:0,display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",fontSize:"var(--fs-12)"}}
    >
      <span>Operator identity & workspace access — manage LLM Provider keys in</span>
      <button
        type="button"
        onClick=${()=>e("/runtime/quotas")}
        style=${{padding:0,border:"none",background:"transparent",color:"var(--info-fg)",fontSize:"var(--fs-12)",fontWeight:500,textDecoration:"underline",textUnderlineOffset:"2px",cursor:"pointer"}}
      >
        Runtime → Quotas
      </button>
    </p>
  `}function Fe({session:e}){const{google:t,github:s}=e.authMethods,l=!t&&!s;return o`
    <section class="ap-card ap-signin-gate" data-testid="multi-account-signin-gate">
      <header class="ap-card-head">
        <div>
          <span class="ap-eyebrow">MULTI-ACCOUNT SIGN IN</span>
          <h2 class="ap-card-title">Sign in to MASC</h2>
          <p class="ap-card-sub">
            Authenticate with your organization identity provider. Browser sessions use HttpOnly same-origin cookies + CSRF headers.
          </p>
        </div>
      </header>

      <div class="ap-signin-actions">
        ${(t||s)&&o`
          <a
            href="/?return_to=%2Fdashboard%23account"
            class="btn-primary ap-signin-btn"
            data-testid="multi-account-signin-link"
            data-oauth-providers=${[t?"google":"",s?"github":""].filter(Boolean).join(",")}
          >
            ${t&&s?"Continue to Sign-In (Google / GitHub)":t?"Continue to Google OIDC Sign-In":"Continue to GitHub OAuth Sign-In"}
          </a>
          <p class="ap-muted">
            Redirects to the server sign-in page (<code>/</code>) where OAuth form submission is permitted by strict CSP, then returns to <code>/dashboard#account</code>.
          </p>
        `}
        ${l&&o`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            No OAuth provider (Google OIDC / GitHub) is enabled on this server&apos;s <code>/health</code> capabilities.
          </div>
        `}
      </div>
    </section>
  `}function Je(e){const t=ne.value,s=U.value,l=ae.value,d=e.subroute||"profile";return o`
    <div class="ap-workspace ap-account-workspace" data-testid="account-workspace">
      <header class="ap-workspace-head">
        <span class="ap-eyebrow">SYSTEM · OPERATOR IDENTITY</span>
        <h1 class="ap-workspace-title">Account & Workspace Access</h1>
        <${ze} onNavigate=${e.onNavigate} />
      </header>

      ${t.kind==="probing"&&o`
        <section class="ap-card" role="status">
          <p class="ap-muted">인증 및 서버 모드를 확인하는 중…</p>
        </section>
      `}

      ${t.kind==="unavailable"&&o`
        <section class="ap-card" role="alert" data-testid="account-unavailable">
          <h2 class="ap-card-title">Server Unavailable</h2>
          <p class="ap-muted">${t.reason}</p>
          <button
            type="button"
            class="btn-primary"
            onClick=${()=>{q().then(()=>G())}}
          >
            Retry Connection
          </button>
        </section>
      `}

      ${t.kind==="account_changed"&&o`
        <section class="ap-card ap-inline-panel--err" role="alert" data-testid="account-changed-banner">
          <h2 class="ap-card-title">다른 탭에서 계정이 변경되었습니다</h2>
          <p class="ap-card-sub">
            이전 계정(<code class="mono">${t.previousAccountId??"없음"}</code>)에서
            새 계정(<code class="mono">${t.nextAccountId??"로그아웃"}</code>)(으)로 세션이 바뀌었습니다.
            오동작 방지를 위해 이 탭의 모든 변경 요청이 중단되었습니다.
          </p>
          <button
            type="button"
            class="btn-primary"
            onClick=${()=>{q().then(()=>G())}}
          >
            현재 세션 다시 불러오기
          </button>
        </section>
      `}

      ${t.kind==="multi_account_signed_out"&&o`
        <${Fe} session=${t} />
      `}

      ${(t.kind==="single_user_local"||t.kind==="single_user_auth_required")&&o`
        <${We} session=${t} />
      `}

      ${t.kind==="multi_account_signed_in"&&(()=>{const b=t.role==="admin",c=qe.has(d);return o`
          ${l&&o`
            <div class="ap-acct-tabs" role="tablist" aria-label="Account sections">
              ${[{id:"profile",label:"Profile & Sessions",adminOnly:!1},{id:"pats",label:"Personal Access Tokens",adminOnly:!1},{id:"members",label:"Members",adminOnly:!0},{id:"invites",label:"Invites",adminOnly:!0},{id:"allowlist",label:"Allowlist",adminOnly:!0}].map(f=>{const $=f.adminOnly&&!b;return o`
                  <button
                    key=${f.id}
                    type="button"
                    role="tab"
                    aria-selected=${d===f.id?"true":"false"}
                    class=${`ap-acct-tab${d===f.id?" is-active":""}${$?" is-locked":""}`}
                    data-rbac-locked=${$?"true":void 0}
                    onClick=${()=>e.onNavigate(`/account/${f.id}`)}
                  >
                    <span>${f.label}</span>
                    ${$&&o`<span class="ap-acct-lock" aria-label="관리자 전용">🔒</span>`}
                  </button>
                `})}
            </div>
          `}

          ${c&&!b?o`
                <section class="ap-card" role="status" data-testid="account-admin-locked">
                  <h2 class="ap-card-title">관리자 전용 영역</h2>
                  <p class="ap-muted">
                    현재 역할(<code class="mono">${t.role}</code>)은 <strong>${d}</strong> 관리 권한이 없습니다.
                    권한 없는 API 요청은 전송하지 않습니다.
                  </p>
                  <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/account/profile")}>
                    Profile로 돌아가기
                  </button>
                </section>
              `:d==="pats"?o`<${He} key=${s} />`:d==="members"?o`<${Ne} key=${s} />`:d==="invites"?o`<${Ue} key=${s} />`:d==="allowlist"?o`<${De} key=${s} />`:o`<${je} key=${s} session=${t} />`}
        `})()}
    </div>
  `}export{Je as AccountWorkspace,Je as default};
