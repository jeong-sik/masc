import{d as D,A as _,T as x,y as R,m as f}from"./vendor.js";import{g as K,a as v,v as z,a1 as F,a2 as H,a3 as $,a4 as O,a5 as N,O as w,n as c,a6 as L,a7 as M,o as n,Q as U,a8 as j,a9 as B,l as y,t as V,aa as J,ab as X,R as I,r as Y,A as q,ac as Z}from"./index.js";import{p as ee,o as S,a as u,b as te,c as h,S as oe,n as Q,s as m,d as b}from"./drift-error.js";import{c as ae}from"./command-search.js";const re=S({supports_image_input:u(b()),supports_image_output:u(b()),vision_input:u(b()),image_output:u(b())}),ne=S({id:m(),provider:m(),model:m(),max_context:Q(),is_default:b(),capabilities:u(h(re)),supports_image_input:u(b()),supports_image_output:u(b())}),W=S({vision_reader:u(h(m())),image_generator:u(h(m()))}),ie=S({media:u(h(W))}),se=S({generated_at_iso:u(m()),dashboard_surface:u(m()),source:u(m()),config_path:h(m()),default_runtime_id:h(m()),default_model:h(m()),default_max_context:h(Q()),runtimes:te(ne),model_routing:ie,media:u(h(W))});class ce extends oe{constructor(r){super("runtime_defaults",r)}}function ue(t){return ee(ce,se,t)}function le(t){const r=[];for(const e of N){if(e.workspace==="account")continue;const s=w(e.access,t);r.push({id:`route:${e.id}`,label:e.label,category:e.workspace,keywords:[...e.keywords,e.path],group:"Route",subtitle:s?`${e.path} · Admin only`:e.path,locked:s,run:()=>c(e.path)})}const a=w("admin",t),i=w("member",t),l=w("su_read_ma_admin",t);r.push({id:"account:profile",label:"Account: Profile, Sessions & Workspaces",category:"Account",keywords:["account","whoami","login","workspace","bearer","계정","프로필"],group:"Account",subtitle:"/account/profile",run:()=>c("/account/profile")},{id:"account:pats",label:"Account: Personal Access Tokens (PATs)",category:"Account",keywords:["account","pat","token","mcp","토큰"],group:"Account",subtitle:"/account/pats",run:()=>c("/account/pats")},{id:"account:members",label:"Account: Members & Admin Lifecycle",category:"Account",keywords:["account","member","admin","disable","revoke","구성원"],group:"Account",subtitle:a?"/account/members · Admin only":"/account/members",locked:a,run:()=>c("/account/members")},{id:"account:invites",label:"Account: Invitations",category:"Account",keywords:["account","invite","초대"],group:"Account",subtitle:a?"/account/invites · Admin only":"/account/invites",locked:a,run:()=>c("/account/invites")},{id:"account:allowlist",label:"Account: Sign-In Allowlist",category:"Account",keywords:["account","allowlist","google","github","허용"],group:"Account",subtitle:a?"/account/allowlist · Admin only":"/account/allowlist",locked:a,run:()=>c("/account/allowlist")},{id:"account:reload-session",label:"Account: Refresh Auth Session",category:"Account",keywords:["account","session","refresh","csrf","재조회"],group:"Account",subtitle:"Re-read /health & session state",run:async()=>{await L(),M(),n("세션 상태를 다시 확인했습니다.","info")}}),t.kind==="multi_account_signed_in"&&r.push({id:"account:sign-out",label:"Account: Sign Out",category:"Account",keywords:["account","logout","signout","로그아웃"],group:"Account",subtitle:"POST /auth/logout",run:async()=>{const e=await U("POST","/auth/logout");if(!e.ok&&e.error.kind!=="unauthorized"){n(`로그아웃 실패: ${e.error.message}`,"error");return}await L(),c("/account"),n("로그아웃되었습니다.","info")}}),r.push({id:"provider:quotas",label:"Provider: Quotas & Rate Limits",category:"Provider",keywords:["provider","quota","codex","claude","antigravity","glm","kimi","429","할당량"],group:"Provider",subtitle:i?"/runtime/quotas · Restricted":"/runtime/quotas — Manage LLM Provider keys & subscriptions",locked:i,run:()=>c("/runtime/quotas")},{id:"provider:efficiency",label:"Provider: Prompt Cache & Spend Efficiency",category:"Provider",keywords:["provider","cache","spend","cost","token","캐시"],group:"Provider",subtitle:i?"/runtime/efficiency · Restricted":"/runtime/efficiency",locked:i,run:()=>c("/runtime/efficiency")},{id:"provider:lanes",label:"Provider: Failover Lanes & Exact Output",category:"Provider",keywords:["provider","lane","failover","exact","fusion","model","레인"],group:"Provider",subtitle:i?"/runtime/lanes · Restricted":"/runtime/lanes",locked:i,run:()=>c("/runtime/lanes")}),r.push({id:"setting:runtime",label:"Setting: runtime.toml Schema & Diff",category:"Setting",keywords:["setting","config","runtime","toml","설정"],group:"Setting",subtitle:a?"/settings · Admin only":"/settings",locked:a,run:()=>c("/settings")},{id:"setting:candle-halflife",label:"Setting: candle.half_life_hours & Pricing Mode",category:"Setting",keywords:["setting","candle","half_life","pricing","캔들"],group:"Setting",subtitle:a?"/settings?section=candle · Admin only":"/settings?section=candle",locked:a,run:()=>c("/settings?section=candle")},{id:"setting:sandbox-policy",label:"Setting: sandbox.microvm & Execution Policy",category:"Setting",keywords:["setting","sandbox","microvm","docker","ssh","보안"],group:"Setting",subtitle:a?"/settings?section=sandbox · Admin only":"/settings?section=sandbox",locked:a,run:()=>c("/settings?section=sandbox")},{id:"setting:keeper-defaults",label:"Setting: keeper.default_lane & Compaction",category:"Setting",keywords:["setting","keeper","lane","compaction","키퍼"],group:"Setting",subtitle:a?"/settings?section=keeper · Admin only":"/settings?section=keeper",locked:a,run:()=>c("/settings?section=keeper")});const p=F.peek(),A=H.peek();return r.push({id:"theme:toggle",label:p==="dark"?"Theme: Switch to Warm Archival Paper (Light)":"Theme: Switch to Tempered Slate (Dark)",category:"Theme",keywords:["theme","dark","light","paper","slate","테마","라이트","다크"],group:"Theme",subtitle:`Current: ${p}`,run:()=>{const e=j();n(`테마 변경: ${e==="light"?"Warm Archival Paper (Light)":"Tempered Slate (Dark)"}`,"info")}},{id:"theme:high-contrast",label:A==="high"?"Theme: Disable High-Contrast Mode":"Theme: Enable High-Contrast Mode (APCA Lc ≥ 90)",category:"Theme",keywords:["contrast","hc","high contrast","accessibility","a11y","고대비"],group:"Theme",subtitle:`data-contrast="${A==="high"?"high":"normal"}"`,run:()=>{const e=B();n(`고대비 모드: ${e==="high"?"켜짐 (Lc ≥ 90)":"기본"}`,"info")}}),r.push(...y(t)?[{id:"action:queue-context",label:"Action: Toggle Queue & Context Quick-Peek",category:"Action",keywords:["queue","context","ctx","peek","큐","컨텍스트"],group:"Action",subtitle:"Read-only live queue & context overview",shortcut:"⌘T",run:()=>{y(v.peek())&&V()}}]:[],{id:"action:incidents",label:"Action: Toggle Historical Incidents (Ch3)",category:"Action",keywords:["incident","error","alert","ch3","장애","이력"],group:"Action",subtitle:"Read-only Channel 3 historical incidents",shortcut:"I",run:()=>J()},{id:"action:toggle-rail",label:"Action: Toggle Navigation Rail",category:"Action",keywords:["sidebar","rail","collapse","expand","사이드바"],group:"Action",subtitle:"208px expanded ↔ 56px collapsed",shortcut:"B",run:()=>X()},...I(t)?[{id:"action:refresh-hitl",label:"Action: Refresh Pending Approvals & Asks",category:"Action",keywords:["refresh","approval","ask","inbox","승인","새로고침"],group:"Action",subtitle:"Fetch /api/v1/keepers/tool-approvals & /asks",run:async()=>{if(!I(v.peek())){n("승인 대기열 새로고침은 싱글유저 세션 전용입니다.","info");return}await Y(),n("승인 및 질문 대기열을 새로고침했습니다.","info")}}]:[],...y(t)?[{id:"action:reconnect-observer",label:"Action: Reconnect Observer SSE Stream",category:"Action",keywords:["sse","observer","reconnect","live","재연결"],group:"Action",subtitle:"Restart shared observer stream",run:()=>{if(!y(v.peek())){n("로그인된 세션에서만 Observer SSE를 재연결할 수 있습니다.","info");return}M(),n("Observer SSE 재연결을 시작했습니다.","info")}}]:[],{id:"action:operator-snapshot-check",label:"Action: Read Operator Digest Snapshot",category:"Action",keywords:["operator","digest","probe","health","운영자"],group:"Action",subtitle:l?"GET /api/v1/operator/digest · Admin only":"GET /api/v1/operator/digest (read-only)",locked:l,run:async()=>{if(w("su_read_ma_admin",v.peek())){n("운영자 다이제스트 조회는 관리자 전용입니다.","info");return}const e=await q("/api/v1/operator/digest");if(!e.ok){Z({severity:"warn",source:"command-palette",summary:`Operator digest returned ${e.error.status??e.error.kind}`,detail:e.error.message}),n(`운영자 다이제스트 조회 실패: ${e.error.message}`,"warning");return}const s=typeof e.value?.health=="string"?e.value.health:typeof e.value?.status=="string"?e.value.status:"ok";n(`Operator digest: ${s}`,"success")}},...y(t)?[{id:"action:runtime-defaults-check",label:"Action: Inspect Resolved Runtime Defaults",category:"Action",keywords:["runtime","defaults","model","routing","런타임"],group:"Action",subtitle:"GET /api/v1/dashboard/runtime-defaults (read-only)",run:async()=>{if(!y(v.peek())){n("로그인된 세션에서만 런타임 기본값을 조회할 수 있습니다.","info");return}const e=await q("/api/v1/dashboard/runtime-defaults");if(!e.ok){n(`런타임 기본값 조회 실패: ${e.error.message}`,"warning");return}try{const s=ue(e.value);n(`Default runtime: ${s.default_runtime_id??"없음"} (${s.runtimes.length} configured)`,"success")}catch(s){n(`런타임 스키마 확인 필요: ${s instanceof Error?s.message:String(s)}`,"warning")}}}]:[]),r}function de(t,r){if(r.length===0)return f`<span>${t}</span>`;const a=[];let i=0;for(const[l,p]of r)l>i&&a.push(t.slice(i,l)),p>l&&(a.push(f`<mark class="ap-cmdk-mark">${t.slice(l,p)}</mark>`),i=p);return i<t.length&&a.push(t.slice(i)),f`<span>${a}</span>`}function fe(){const t=K.value,r=v.value,[a,i]=D(""),[l,p]=D(0),A=_(null),e=_(null),s=_(null);z({containerRef:A,active:t,initialFocus:()=>e.current});const P=x(()=>le(r),[r,F.value,H.value]),T=x(()=>ae(P),[P]),k=x(()=>T.search(a,30),[T,a]);if(R(()=>{p(0)},[a,t]),R(()=>{if(!t)return;i(""),p(0),queueMicrotask(()=>e.current?.focus());const o=d=>{d.isComposing||d.keyCode===229||d.key==="Escape"&&(d.preventDefault(),d.stopPropagation(),$())};return window.addEventListener("keydown",o,!0),()=>{window.removeEventListener("keydown",o,!0)}},[t]),R(()=>{if(!t)return;s.current?.querySelector(".ap-cmdk-item.is-selected")?.scrollIntoView?.({block:"nearest"})},[l,t]),!t)return null;const C=o=>{o&&($(),o.run())};return f`
    <div
      class="cmdk-backdrop"
      role="presentation"
      data-testid="command-palette-backdrop"
      onClick=${o=>{o.target===o.currentTarget&&$()}}
    >
      <div
        ref=${A}
        class="ap-cmdk-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="명령 팔레트"
        onKeyDown=${o=>{if(!(o.isComposing||o.keyCode===229)){if(o.key==="Escape"){o.preventDefault(),o.stopPropagation(),$();return}if(o.key==="ArrowDown"){o.preventDefault(),p(d=>k.length===0?0:(d+1)%k.length);return}if(o.key==="ArrowUp"){o.preventDefault(),p(d=>k.length===0?0:(d-1+k.length)%k.length);return}o.key==="Enter"&&(o.preventDefault(),C(k[l]?.item))}}}
      >
        <div class="ap-cmdk-input-row">
          <${O} name="search" size=${16} className="ap-muted" />
          <input
            ref=${e}
            type="text"
            class="ap-cmdk-input"
            role="combobox"
            aria-expanded="true"
            aria-controls="ap-cmdk-list"
            aria-activedescendant=${k[l]?`ap-cmdk-opt-${l}`:void 0}
            aria-autocomplete="list"
            placeholder="Search routes, Account:, Provider:, Setting:, theme, or actions…"
            value=${a}
            onInput=${o=>i(o.currentTarget.value)}
          />
          <kbd class="ap-kbd">ESC</kbd>
        </div>

        <div ref=${s} id="ap-cmdk-list" class="ap-cmdk-list" role="listbox" aria-label="명령 결과">
          ${k.length===0?f`<div class="ap-cmdk-empty">일치하는 명령이 없습니다.</div>`:k.map((o,d)=>{const{item:g,labelRanges:G}=o,E=d===l;return f`
                  <button
                    key=${g.id}
                    id=${`ap-cmdk-opt-${d}`}
                    type="button"
                    role="option"
                    aria-selected=${E?"true":"false"}
                    class=${`ap-cmdk-item${E?" is-selected":""}${g.locked?" is-locked":""}`}
                    data-command-id=${g.id}
                    onMouseEnter=${()=>p(d)}
                    onClick=${()=>C(g)}
                  >
                    <div class="ap-cmdk-item-main">
                      <span class="ap-cmdk-group">${g.group}</span>
                      <span class="ap-cmdk-label">
                        ${de(g.label,G)}
                      </span>
                      ${g.locked&&f`<${O} name="lock" size=${12} />`}
                    </div>
                    <div class="ap-cmdk-item-meta">
                      <span class="ap-cmdk-sub mono">${g.subtitle}</span>
                      ${g.shortcut&&f`<kbd class="ap-kbd">${g.shortcut}</kbd>`}
                    </div>
                  </button>
                `})}
        </div>

        <footer class="ap-cmdk-foot">
          <span>↑↓ 이동 · ↵ 실행 · ESC 닫기</span>
          <span class="mono">Account: ≠ Provider:</span>
        </footer>
      </div>
    </div>
  `}export{fe as CommandPalette,le as buildPaletteCommands};
