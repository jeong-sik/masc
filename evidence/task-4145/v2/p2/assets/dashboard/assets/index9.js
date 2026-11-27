import{m as s,d as v,A as C,y as O,q as de,T as Y,a as Ce}from"./vendor.js";import{f as Ht,D as Gt,a as Vt,K as te}from"./core.js";import{s as Lt,a as V,aQ as Be,aL as Wt,aR as zt,A as Te,B as U,C as Bt,aM as Ut,P as lt,ah as qt,aD as ct,aj as jt,O as Jt,z as D,aK as Xt,Y as we,Q as Xe,o as Ue,aS as dt,ap as ut,X as Yt,F as pt,T as Qt}from"./index.js";import{r as Zt}from"./sse-reader.js";import{i as It}from"./type-guards.js";import{I as en}from"./inline-spinner.js";import{f as me,S as tn}from"./format-time.js";import{V as nn}from"./virtual-list.js";import"./command-search.js";import"./toast.js";import{c as sn}from"./markdown.js";import{D as ae}from"./data-table.js";import{k as se,f as ft,e as Ct,a as rn,j as an,g as Fe,d as ce}from"./wire-decode.js";import{u as on,n as ln}from"./now-signal.js";import{c as cn}from"./unified-diff.js";import{R as dn}from"./refresh-button.js";import"./format-string.js";import"./table.js";import"./useSelector.js";import"./shared-ticker.js";const un="x-masc-sse-idle-timeout-ms",pn=1e3;function fn(e){const t=typeof e=="string"?e.toUpperCase():"INFO";return t==="DEBUG"||t==="WARN"||t==="ERROR"?t:"INFO"}function $t(e){if(!It(e)||!Array.isArray(e.entries))return{reset:!1,entries:[]};const t=e.reset===!0,n=[];for(const r of e.entries){if(!r||typeof r!="object")continue;const i=r,a=typeof i.seq=="number"?i.seq:null,d=typeof i.ts=="string"?i.ts:new Date().toISOString(),f=Date.parse(d),$=Number.isFinite(f)?f/1e3:Date.now()/1e3,k=i.details&&typeof i.details=="object"&&!Array.isArray(i.details)?i.details:{};n.push({id:a===null?`log:unknown:${d}:${n.length}`:`log:${a}`,kind:"LOG",seq:a,tsUnix:$,tsDisplay:d.replace("T"," ").slice(11,19),level:fn(i.level),source:typeof i.source=="string"?i.source:"structured",module:typeof i.module=="string"?i.module:"",keeper:typeof i.keeper_name=="string"&&i.keeper_name?i.keeper_name:null,message:typeof i.message=="string"?i.message:"",details:k})}return{reset:t,entries:n}}function $n(e){switch(e){case"ERROR":return"var(--err-fg)";case"WARN":return"var(--warn-fg)";case"INFO":return"var(--info-fg)";case"DEBUG":return"var(--fg-3)"}}function He(e,t,n){const r=n?e.filter(a=>a.kind!=="LOG"):[...e],i=new Set(r.map(a=>a.id));for(const a of t)i.has(a.id)||(i.add(a.id),r.push(a));return r.sort((a,d)=>d.tsUnix-a.tsUnix||(d.seq??0)-(a.seq??0)),r.slice(0,pn)}function bn(e){const t=Lt.value;return s`<${mn} ...${e} key=${t} epoch=${t} />`}function mn({epoch:e,...t}){const[n,r]=v([]),[i,a]=v("ALL"),[d,f]=v("ALL"),[$,k]=v(""),[I,h]=v(null),[E,P]=v("connecting"),[w,F]=v(0),[g,_]=v({kind:"loading"}),[p,T]=v(!1),[H,Q]=v(0),z=C(!1);z.current=p;const J=C({entries:[],resetLogs:!1}),u=C({entries:[],resetLogs:!1,scheduled:!1}),B=C(null),X=C(!0);O(()=>(X.current=!0,()=>{X.current=!1,B.current?.abort(),u.current.entries=[],u.current.resetLogs=!1,u.current.scheduled=!1}),[]);const Z=C(!1),m=V.value,A=Be(m),x=m.kind==="single_user_local"&&m.role!=="player"?Wt.value:null,o=x!==null&&zt.value,l=de(()=>{const c=u.current;if(c.scheduled=!1,!X.current){c.entries=[],c.resetLogs=!1;return}if(!c.resetLogs&&c.entries.length===0)return;const b=c.entries,S=c.resetLogs;if(c.entries=[],c.resetLogs=!1,z.current){const R=J.current,K=He(R.entries,b,S);J.current={entries:K,resetLogs:R.resetLogs||S},Q(K.length);return}r(R=>He(R,b,S))},[]),L=de((c,b)=>{const S=u.current;b&&(S.resetLogs=!0,S.entries=S.entries.filter(R=>R.kind!=="LOG"));for(let R=0;R<c.length;R++)S.entries.push(c[R]);S.scheduled||(S.scheduled=!0,queueMicrotask(l))},[l]),ve=de(()=>{if(l(),z.current){const c=J.current;J.current={entries:[],resetLogs:!1},Q(0),z.current=!1,T(!1),(c.resetLogs||c.entries.length>0)&&r(b=>He(b,c.entries,c.resetLogs))}else z.current=!0,T(!0)},[l]),Ne=de((c=!1)=>{if(!A)return;B.current?.abort();const b=new AbortController;B.current=b;const{signal:S}=b;_({kind:"loading"}),Te("/api/v1/dashboard/logs?limit=200",{signal:S,decode:R=>{if(!It(R)||!Array.isArray(R.entries))throw new Error("서버가 로그 목록을 반환하지 않았습니다.");return $t(R).entries}}).then(R=>{!X.current||S.aborted||!U(e)||!c&&Z.current||(R.ok?(_({kind:"ready",observedAt:Date.now()}),L(R.value,c)):_({kind:"failed",message:R.error.message}))})},[e,A,L]);O(()=>{if(!A){B.current?.abort();return}Ne(!1);const c=Bt(b=>{if(!U(e))return;const S=Date.now()/1e3,R=new Date(S*1e3).toISOString(),K=b.data&&typeof b.data=="object"&&!Array.isArray(b.data)?b.data:{raw:b.raw},ge={id:`evt:${b.id??S}:${b.event}:${Math.random().toString(36).slice(2,7)}`,kind:"EVT",seq:null,tsUnix:S,tsDisplay:R.replace("T"," ").slice(11,19),level:"INFO",source:"observer_sse",module:b.event,keeper:typeof K.keeper=="string"?K.keeper:null,message:typeof K.summary=="string"?K.summary:typeof K.type=="string"?K.type:b.event,details:K};L([ge],!1)});return()=>{B.current?.abort(),c()}},[e,A,Ne,L]),O(()=>{if(!x)return;const c=Ut("infra-logs",b=>{const S=V.peek();if(S.kind!=="single_user_local"||S.role==="player")return;P("connecting");const R=qt("/api/v1/dashboard/logs/stream?limit=200"),K={Accept:"text/event-stream",[ct]:x},ge=jt();ge&&(K.Authorization=`Bearer ${ge}`),(async()=>{try{const ie=await Ht(R,{method:"GET",credentials:"same-origin",headers:K,signal:b},Gt),ye=ie.body;if(b.aborted||!U(e)){ye?.cancel().catch(()=>{});return}const Me=ie.headers.get(un),Ke=Me!==null&&/^[1-9][0-9]*$/.test(Me)?Number(Me):NaN;if(!ie.ok||!ye||!ie.headers.get("content-type")?.toLowerCase().startsWith("text/event-stream")||ie.headers.get(ct)!==x||!Number.isSafeInteger(Ke)||Ke>2147483647){ye?.cancel().catch(()=>{}),P("error");return}let it=!1;await Zt(ye,(Ys,Ft)=>{if(b.aborted||!U(e))return;const le=$t(JSON.parse(Ft));if(!it){if(!le.reset)throw new Error("The log stream did not send its initial snapshot");it=!0,Z.current=!0,P("live")}(le.entries.length>0||le.reset)&&(_({kind:"ready",observedAt:Date.now()}),L(le.entries,le.reset))},{signal:b,idleTimeoutMs:Ke})}catch{}finally{!b.aborted&&U(e)&&P("error")}})()});return()=>{c.release()}},[x,e,w,L]);const ne=x!==null&&E==="live",st=x!==null&&E==="connecting",Mt=x!==null&&E==="error",rt=p||o,De=g.kind==="failed"?g.message:null,Kt=A?p?`⏸ PAUSED${H>0?` (+${H})`:""}`:o?"⏸ PAUSED (hidden)":ne?"● LIVE SSE":st?"CONNECTING":g.kind==="ready"?"○ SNAPSHOT":g.kind==="failed"?"○ UNAVAILABLE":"LOADING":"○ ADMIN ONLY",at=Y(()=>{const c=$.trim().toLowerCase();return n.filter(b=>!(i==="LOGS"&&b.kind!=="LOG"||i==="EVENTS"&&b.kind!=="EVT"||d!=="ALL"&&b.level!==d||c&&!`${b.module} ${b.keeper??""} ${b.message}`.toLowerCase().includes(c)))},[n,i,d,$]),ot=c=>{U(e)&&(h(c),t.onInspect({title:`${c.kind} · ${c.module||c.source}`,subtitle:`${c.tsDisplay} · ${c.level}${c.seq!==null?` · #${c.seq}`:""}`,kind:"infra_log_entry",data:c,render:()=>s`
        <div data-testid="logs-kv-inspector" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
          <div class="wka-card" style=${{fontSize:"var(--fs-12)"}}>
            <div style=${{fontWeight:600,marginBottom:"var(--sp-1)"}}>${c.message}</div>
            <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
              source=${c.source} · module=${c.module||"없음"} · keeper=${c.keeper??"없음"}
            </div>
          </div>
          <div class="wka-card">
            <h4 style=${{margin:"0 0 var(--sp-1)",fontSize:"var(--fs-12)"}}>Structured K/V Details</h4>
            <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap"}}>
              ${JSON.stringify(c.details,null,2)}
            </pre>
          </div>
        </div>
      `}))};return s`
    <div class="v2-logs-surface" data-testid="infra-logs-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">6 INFRA · ACTIVITY & LOGS</span>
          <h1>통합 활동 · 로그 타임라인 (LOG + EVT)</h1>
        </div>
        <div class="v2-logs-head-actions">
          <span
            class="mono"
            data-testid="logs-stream-status"
            role="status"
            style=${{padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",border:`1px solid ${p||o?"var(--warn-border)":ne?"var(--ok-border)":"var(--line-2)"}`,background:p||o?"var(--warn-soft)":ne?"var(--ok-soft)":"var(--bg-2)",color:p||o?"var(--warn-fg)":ne?"var(--ok-fg)":"var(--fg-2)"}}
          >
            ${A&&!rt&&(st||!ne&&g.kind==="loading")&&s`<${en} /> `}
            ${Kt}
            ${A&&!rt&&!ne&&g.kind==="ready"&&s`
              · <time dateTime=${new Date(g.observedAt).toISOString()} title="마지막 로그 확인">
                ${me(g.observedAt/1e3)}
              </time>
            `}
          </span>
          ${Mt&&!o&&s`
            <button
              type="button"
              class="btn-ghost"
              data-testid="logs-reconnect-btn"
              aria-label="실시간 로그 스트림 연결이 끊겼습니다. 다시 연결"
              title="실시간 로그 스트림 연결이 끊겼습니다. 클릭하여 다시 연결합니다."
              onClick=${()=>{P("connecting"),F(c=>c+1)}}
            >
              다시 연결
            </button>
          `}
          <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            ${at.length} / ${n.length}
          </span>
        </div>
      </header>

      ${De&&s`<div class="ap-error" role="alert">로그 조회 실패: ${De}</div>`}

      <section class="v2-logs-panel" style=${{overflow:"visible"}}>
        <div
          class="v2-logs-toolbar"
          style=${{borderTopLeftRadius:"var(--radius-md)",borderTopRightRadius:"var(--radius-md)"}}
        >
          <${lt}
            triggerLabel=${s`<span>종류: <strong class="mono">${i}</strong> ▾</span>`}
            triggerTestId="logs-kind-filter"
            popoverTestId="logs-kind-menu"
            ariaLabel=${`타임라인 종류 (${i})`}
            items=${["ALL","LOGS","EVENTS"].map(c=>({id:c,label:c,active:i===c,testId:`logs-kind-option-${c}`,onSelect:()=>a(c)}))}
          />

          <${lt}
            triggerLabel=${s`<span>레벨: <strong class="mono">${d}</strong> ▾</span>`}
            triggerTestId="logs-level-filter"
            popoverTestId="logs-level-menu"
            ariaLabel=${`로그 레벨 필터 (${d})`}
            items=${["ALL","DEBUG","INFO","WARN","ERROR"].map(c=>({id:c,label:c,active:d===c,testId:`logs-level-option-${c}`,onSelect:()=>f(c)}))}
          />

          <input
            type="search"
            aria-label="로그 검색"
            placeholder="모듈 / Keeper / 메시지 검색…"
            value=${$}
            onInput=${c=>k(c.target.value)}
            style=${{flex:"1 1 180px",minWidth:0,minHeight:"var(--btn-h, 32px)",fontSize:"var(--fs-12)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
          />

          <button
            type="button"
            class="btn-ghost tnum"
            data-testid="logs-pause-toggle"
            aria-pressed=${p?"true":"false"}
            style=${{minWidth:"124px",justifyContent:"center"}}
            onClick=${ve}
          >
            ${p?`▶ 재개${H>0?` (+${H})`:""}`:"⏸ 일시정지"}
          </button>

          <button
            type="button"
            class="btn-ghost"
            data-testid="logs-refresh-btn"
            disabled=${!A}
            onClick=${()=>Ne(!0)}
          >
            새로고침
          </button>

          <button
            type="button"
            class="btn-ghost"
            onClick=${()=>{J.current={entries:[],resetLogs:!1},Q(0),r([]),h(null)}}
          >
            버퍼 비우기
          </button>
        </div>

        <div style=${{overflowX:"auto",minWidth:0,borderBottomLeftRadius:"var(--radius-md)",borderBottomRightRadius:"var(--radius-md)"}}>
          <div class="v2-logs-table-header mono" aria-hidden="true" style=${{minWidth:"520px"}}>
            <span>TIME</span>
            <span>KIND</span>
            <span>LEVEL</span>
            <span>MODULE</span>
            <span>MESSAGE</span>
          </div>

          <${nn}
            items=${at}
            estimateSize=${34}
            height=${460}
            ariaLabel="통합 로그 및 이벤트 타임라인"
            getItemKey=${c=>c.id}
            empty=${De?null:s`
              <div style=${{padding:"var(--sp-4)"}} class="dtable-absent" data-testid=${A?void 0:"logs-admin-locked"}>
                ${A?g.kind==="loading"?"로그 불러오는 중…":"표시할 로그 또는 이벤트가 없습니다.":"관리자(Admin) 권한이 필요한 활동·로그 뷰입니다."}
              </div>`}
            renderItem=${c=>{const b=I?.id===c.id;return s`
                <div
                  class="v2-logs-row v2-logs-line mono"
                  role="button"
                  tabIndex=${0}
                  onClick=${()=>ot(c)}
                  onKeyDown=${S=>{S.isComposing||S.keyCode===229||(S.key==="Enter"||S.key===" ")&&(S.preventDefault(),ot(c))}}
                  style=${{cursor:"pointer",background:b?"var(--bg-4)":void 0,height:"34px",minWidth:"520px",overflow:"hidden"}}
                >
                  <span class="tnum" style=${{color:"var(--fg-3)"}}>${c.tsDisplay}</span>
                  <span style=${{color:c.kind==="EVT"?"var(--brass-1)":"var(--fg-2)"}}>${c.kind}</span>
                  <span style=${{color:$n(c.level),fontWeight:600}}>${c.level}</span>
                  <span style=${{color:"var(--fg-2)",overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>
                    ${c.module||c.keeper||"system"}
                  </span>
                  <span style=${{color:"var(--fg-1)",overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>
                    ${c.message}
                  </span>
                </div>
              `}}
          />
        </div>
      </section>
    </div>
  `}function hn(e,t){if(!bt(e)||e.id!==t||e.status!=="active"||!bt(e.advance))throw new Error("Malformed repository sync response");const n=e.advance,r=i=>typeof i=="number"&&Number.isSafeInteger(i)&&i>=0;switch(n.state){case"advanced":if(r(n.behind))return{state:n.state,behind:n.behind};break;case"already_current":return{state:n.state};case"skipped_dirty":if(r(n.staged)&&r(n.unstaged)&&r(n.conflicted))return{state:n.state,staged:n.staged,unstaged:n.unstaged,conflicted:n.conflicted};break;case"skipped_not_on_default_branch":if(typeof n.current_branch=="string")return{state:n.state,current_branch:n.current_branch};break;case"fast_forward_refused":if(r(n.behind)&&typeof n.reason=="string")return{state:n.state,behind:n.behind,reason:n.reason};break;case"advance_inspect_failed":if(typeof n.reason=="string")return{state:n.state,reason:n.reason};break}throw new Error("Malformed repository advance outcome")}function bt(e){return e!==null&&typeof e=="object"&&!Array.isArray(e)}Vt();Ce(null);Ce(!1);Ce(!1);Ce(new Map);function vn(e){switch(e.state){case"advanced":return{message:`원격의 새 커밋 ${e.behind}개를 작업 트리에 반영했습니다.`,tone:"success"};case"already_current":return{message:"작업 트리가 이미 원격과 같습니다.",tone:"success"};case"skipped_dirty":{const t=[];return e.conflicted>0&&t.push(`충돌 ${e.conflicted}`),e.unstaged>0&&t.push(`수정 ${e.unstaged}`),e.staged>0&&t.push(`staged ${e.staged}`),{message:`원격은 가져왔습니다. ${t.length>0?`커밋 안 된 변경(${t.join(" · ")})`:"커밋 안 된 변경"}이 있어 작업 트리는 그대로 두었습니다.`,tone:"warning"}}case"skipped_not_on_default_branch":return{message:`원격은 가져왔습니다. 작업 트리가 기본 브랜치가 아닌 ${e.current_branch}에 있어 그대로 두었습니다.`,tone:"warning"};case"fast_forward_refused":return{message:`원격은 가져왔습니다. 새 커밋 ${e.behind}개를 작업 트리에 반영하지 못했습니다: ${e.reason}`,tone:"warning"};case"advance_inspect_failed":return{message:`원격은 가져왔습니다. 작업 트리 상태를 확인하지 못했습니다: ${e.reason}`,tone:"warning"}}}function gn(e,t){const n=typeof e=="string"?e:"";switch(n){case"active":return{kind:"active"};case"paused":return{kind:"paused"};case"cloning":return{kind:"cloning"};case"error":return{kind:"error",message:typeof t=="string"&&t!==""?t:null};default:return{kind:"unknown",raw:n}}}const yn={error:0,unknown:1,cloning:2,paused:3,active:4};function kn(e){switch(e.kind){case"active":return{text:"정상",tone:"neutral"};case"paused":return{text:"일시정지",tone:"neutral"};case"cloning":return{text:"가져오는 중",tone:"info"};case"error":return{text:"오류",tone:"bad"};case"unknown":return{text:e.raw===""?"상태 미보고":e.raw,tone:"warn"}}}function Ye(e,t){if(e.status.kind!=="cloning"||e.auto_sync!==!0||e.sync_interval===null||e.updated_at===null)return null;const n=t-e.updated_at;return n>e.sync_interval?{ageSec:n,intervalSec:e.sync_interval}:null}function _n(e,t){return e.status.kind!=="cloning"||e.sync_interval===null||e.updated_at===null?!1:t-e.updated_at<=e.sync_interval}function Re(e){const t=Math.max(0,Math.round(e));return t<60?`${t}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function Sn(e,t){if(e.updated_at===null)return{text:"기록 없음",tone:"neutral"};const n=Re(t-e.updated_at);switch(e.status.kind){case"active":return{text:`${n} 전`,tone:"neutral"};case"cloning":return{text:`${n} 전 시작`,tone:Ye(e,t)===null?"neutral":"warn"};case"error":return{text:`${n} 전 실패`,tone:"bad"};case"paused":return{text:`${n} 전 멈춤`,tone:"neutral"};case"unknown":return{text:`${n} 전 기록`,tone:"neutral"}}}function W(e){return e!==null&&typeof e=="object"&&!Array.isArray(e)}const qe="GET /api/v1/repositories";function wn(e,t){const n=`${qe} repositories[${t}]`,r=ft(e,"id",n).trim(),i=ft(e,"name",n).trim();if(r===""||i==="")throw new Error(`${n}: "id"와 "name" 필드는 비어 있을 수 없습니다.`);return{id:r,name:i,local_path:typeof e.resolved_local_path=="string"?e.resolved_local_path:typeof e.local_path=="string"?e.local_path:null,status:gn(e.status,e.error_message),auto_sync:typeof e.auto_sync=="boolean"?e.auto_sync:null,sync_interval:typeof e.sync_interval=="number"&&e.sync_interval>0?e.sync_interval:null,updated_at:typeof e.updated_at=="number"&&e.updated_at>0?e.updated_at:null}}function Rn(e){if(!W(e)||!Array.isArray(e.repositories))throw new Error(`${qe}: the answer has no \`repositories\` list`);return se(e.repositories,"repositories",qe).map(wn)}function fe(e){return typeof e=="number"&&Number.isSafeInteger(e)&&e>=0?e:null}const xn=new Intl.NumberFormat("ko-KR");function y(e){return xn.format(e)}function Qe(e){const t=e.lastIndexOf("/",e.length-2);return t===-1?{dir:null,name:e}:{dir:e.slice(0,t+1),name:e.slice(t+1)}}function En(e,t){const n=new Map;for(const r of e){const i=t(r),a=n.get(i);a?a.push(r):n.set(i,[r])}return[...n].map(([r,i])=>{const a=[...i].sort((d,f)=>f.at-d.at);return{path:r,writes:a,lastAt:a[0].at,keepers:[...new Set(a.map(d=>d.keeper))],failed:a.filter(d=>!d.succeeded).length}}).sort((r,i)=>i.lastAt-r.lastAt||(r.path<i.path?-1:r.path>i.path?1:0))}const An=new Intl.Collator(void 0,{numeric:!0,sensitivity:"base"});function Ln(e){let t=null;for(const n of e)(t===null||An.compare(n.name,t.name)<0)&&(t=n);return t}const In=["passing","failing","running","none"],Cn=["approved","changes_requested","waiting","none"],Tn=["mergeable","conflicting","unknown"],On=["reviewed_on_head","not_reviewed_on_head","review_history_incomplete","unknown"];function ke(e,t){return typeof t=="string"&&e.includes(t)?t:null}function pe(e){return typeof e=="string"&&e!==""?e:null}function Pn(e){if(!W(e))return null;const t=fe(e.number),n=ke(In,e.checks),r=ke(Cn,e.review),i=ke(Tn,e.mergeable),a=ke(On,e.head_review);return t===null||typeof e.draft!="boolean"||!n||!r||!i||!a?null:{number:t,draft:e.draft,checks:n,review:r,mergeable:i,headReview:a,author:pe(e.author),keeper:pe(e.keeper),title:pe(e.title)}}function Nn(e){if(!W(e))throw new Error("pulls: failure is not an object");const t=()=>{const r=fe(e.status);if(r===null)throw new Error("pulls: failure.status is not a number");return r},n=()=>{if(typeof e.message!="string")throw new Error("pulls: failure.message is not a string");return e.message};switch(e.kind){case"repository_not_visible":return{kind:"repository_not_visible"};case"token_rejected":return{kind:"token_rejected"};case"rate_limited":if(e.reset_at!==null&&typeof e.reset_at!="number")throw new Error("pulls: failure.reset_at is neither a number nor null");return{kind:"rate_limited",resetAt:e.reset_at};case"forbidden":return{kind:"forbidden",status:t()};case"http_status":return{kind:"http_status",status:t()};case"graphql_errors":if(!Array.isArray(e.messages)||!e.messages.every(r=>typeof r=="string"))throw new Error("pulls: failure.messages is not a list of strings");return{kind:"graphql_errors",messages:e.messages};case"transport_failed":return{kind:"transport_failed",message:n()};case"response_unreadable":return{kind:"response_unreadable",message:n()};default:throw new Error("pulls: unknown failure kind")}}function Dn(e){if(!W(e))throw new Error("pulls: repository entry has no pulls state");const t=()=>{if(typeof e.observed_at!="number")throw new Error("pulls: observed_at is not a number");return e.observed_at};switch(e.state){case"not_read":return{kind:"not_read"};case"not_github":return{kind:"not_github"};case"read":{if(!Array.isArray(e.pulls))throw new Error("pulls: read state has no pulls list");const n=e.pulls.map(Pn),r=n.filter(a=>a!==null),i=fe(e.undecodable);if(i===null)throw new Error("pulls: undecodable is not a count");return{kind:"read",observedAt:t(),pulls:r,unreadable:i+(n.length-r.length)}}case"failed":return{kind:"failed",observedAt:t(),failure:Nn(e.failure)};default:throw new Error("pulls: unknown pulls state")}}function Mn(e){if(!W(e))throw new Error("pulls: reader is not an object");const t=n=>{const r=e[n];if(typeof r!="string")throw new Error(`pulls: reader.${n} is not a string`);return r};switch(e.state){case"not_declared":return{kind:"not_declared"};case"declaration_invalid":return{kind:"declaration_invalid",reason:t("reason")};case"keeper_missing":return{kind:"keeper_missing",keeper:t("keeper")};case"token_unavailable":return{kind:"token_unavailable",keeper:t("keeper"),reason:t("reason")};case"ready":return{kind:"ready",keeper:t("keeper")};default:throw new Error("pulls: unknown reader state")}}function Kn(e){if(!W(e))throw new Error("pulls: keepers is not an object");switch(e.state){case"not_listed":return{kind:"not_listed"};case"listed":return{kind:"listed"};case"list_failed":if(typeof e.reason!="string")throw new Error("pulls: keepers.reason is not a string");return{kind:"list_failed",reason:e.reason};default:throw new Error("pulls: unknown keepers state")}}function Fn(e){if(!W(e)||!Array.isArray(e.repositories))throw new Error("pulls: missing repositories");const t=new Map;for(const n of e.repositories){if(!W(n)||typeof n.repository_id!="string")throw new Error("pulls: entry has no repository_id");t.set(n.repository_id,{slug:pe(n.slug),pulls:Dn(n.pulls)})}return{reader:Mn(e.reader),keepers:Kn(e.keepers),repositoriesError:pe(e.repositories_error),byRepo:t}}function Hn(e){switch(e.kind){case"ready":return null;case"not_declared":return"PR을 읽을 Keeper가 정해져 있지 않습니다.";case"declaration_invalid":return`PR을 읽을 Keeper 설정을 읽지 못했습니다: ${e.reason}`;case"keeper_missing":return`PR을 읽기로 한 Keeper(${e.keeper})가 없습니다.`;case"token_unavailable":return`Keeper(${e.keeper})의 GitHub 토큰을 쓸 수 없습니다: ${e.reason}`}}function Gn(e){switch(e.kind){case"repository_not_visible":return"이 토큰으로는 저장소가 보이지 않습니다.";case"token_rejected":return"GitHub가 토큰을 거절했습니다.";case"rate_limited":return"GitHub 요청 한도에 걸렸습니다.";case"forbidden":return`GitHub가 요청을 막았습니다(HTTP ${e.status}).`;case"http_status":return`GitHub가 HTTP ${e.status} 응답을 보냈습니다.`;case"graphql_errors":return`GitHub가 오류로 답했습니다: ${e.messages.join(" / ")}`;case"transport_failed":return`GitHub에 연결하지 못했습니다: ${e.message}`;case"response_unreadable":return`GitHub 응답을 읽지 못했습니다: ${e.message}`}}const Vn={passing:{text:"통과",tone:"neutral"},failing:{text:"실패",tone:"bad"},running:{text:"도는 중",tone:"info"},none:{text:"없음",tone:"neutral"}},Wn={approved:{text:"승인",tone:"ok"},changes_requested:{text:"변경 요청",tone:"warn"},waiting:{text:"대기",tone:"neutral"},none:{text:"요청 없음",tone:"neutral"}},zn={mergeable:{text:"가능",tone:"neutral"},conflicting:{text:"충돌",tone:"bad"},unknown:{text:"미확인",tone:"neutral"}},Bn={failing:0,running:1,none:2,passing:3},Un={changes_requested:0,waiting:1,none:2,approved:3},qn={conflicting:0,unknown:1,mergeable:2};function Tt(e){return!e.draft&&e.checks==="passing"&&e.review==="approved"&&e.headReview==="reviewed_on_head"&&e.mergeable==="mergeable"}function Ot(e){let t=0,n=0,r=0,i=0;for(const a of e)a.mergeable==="conflicting"&&(t+=1),a.checks==="failing"&&(n+=1),a.review==="changes_requested"&&(r+=1),Tt(a)&&(i+=1);return{total:e.length,conflicting:t,checksFailing:n,changesRequested:r,ready:i}}function Pt(e,t){switch(t){case"all":return e;case"conflicting":return e.filter(n=>n.mergeable==="conflicting");case"checksFailing":return e.filter(n=>n.checks==="failing");case"changesRequested":return e.filter(n=>n.review==="changes_requested");case"ready":return e.filter(Tt)}}function jn(e,t){return`https://github.com/${e}/pull/${t}`}function Jn(e){if(e===null)return{kind:"none"};if(!W(e)||typeof e.name!="string")throw new Error("git status: upstream is not an object with a name");if(e.ahead===null&&e.behind===null)return{kind:"gone",name:e.name};const t=fe(e.ahead),n=fe(e.behind);if(t===null||n===null)throw new Error("git status: upstream ahead/behind are not counts");return{kind:"tracking",name:e.name,ahead:t,behind:n}}function Xn(e){if(!W(e)||typeof e.path!="string")throw new Error("git status: a change has no path");const t=n=>{const r=e[n];if(typeof r!="boolean")throw new Error(`git status: change.${n} is not a boolean`);return r};return{path:e.path,staged:t("staged"),unstaged:t("unstaged"),untracked:t("untracked"),conflicted:t("conflicted")}}function Yn(e){if(!W(e)||!W(e.branch)||!Array.isArray(e.changes))throw new Error("git status: missing branch or changes");const t=e.branch.head;if(t!==null&&typeof t!="string")throw new Error("git status: head is neither a name nor null");return{head:t===null?{kind:"detached"}:{kind:"branch",name:t},upstream:Jn(e.branch.upstream),changes:e.changes.map(Xn)}}function Qn(e){let t=0,n=0,r=0,i=0;for(const a of e)a.staged&&(t+=1),a.unstaged&&(n+=1),a.untracked&&(r+=1),a.conflicted&&(i+=1);return{total:e.length,staged:t,unstaged:n,untracked:r,conflicted:i}}function Zn(e){return e.kind==="branch"?{text:e.name,tone:"neutral"}:{text:"detached HEAD",tone:"warn"}}function es(e){switch(e.kind){case"none":return{text:"추적 브랜치 없음",tone:"neutral"};case"gone":return{text:"원격 브랜치 삭제됨",tone:"warn"};case"tracking":{const{ahead:t,behind:n}=e;if(t===0&&n===0)return{text:"같음",tone:"ok"};const r=[];return n>0&&r.push(`${y(n)}커밋 뒤`),t>0&&r.push(`${y(t)}커밋 앞`),{text:r.join(" · "),tone:n>0?"warn":"info"}}}}function ts(e){return e.kind==="none"?null:e.name}function ns(e){return e.total===0?{text:"깨끗함",tone:"ok"}:e.conflicted>0?{text:`충돌 ${y(e.conflicted)} · ${y(e.total)}파일`,tone:"bad"}:{text:`${y(e.total)}파일`,tone:"neutral"}}function ss(e){const t=[];return e.staged>0&&t.push(`staged ${y(e.staged)}`),e.unstaged>0&&t.push(`수정 ${y(e.unstaged)}`),e.untracked>0&&t.push(`새 파일 ${y(e.untracked)}`),t.length>0?t.join(" · "):null}function rs(e){return e.conflicted?"충돌":e.untracked?"새 파일":e.staged?"staged":"수정"}const as=["충돌","staged","수정","새 파일"];function os(e){const t=new Map;for(const n of e){const r=rs(n),i=t.get(r);i?i.push(n.path):t.set(r,[n.path])}return as.flatMap(n=>{const r=t.get(n);return r?[{kind:n,paths:r}]:[]})}function is(e){const t=new Map;for(const n of e){const{dir:r,name:i}=Qe(n),a=t.get(r??"./");a?a.push(i):t.set(r??"./",[i])}return[...t].map(([n,r])=>({dir:n,names:r})).sort((n,r)=>r.names.length-n.names.length||(n.dir<r.dir?-1:n.dir>r.dir?1:0))}const ls=3,cs=6;function q(e){return s`<span class="rp-chip" data-tone=${e.tone??"neutral"}>${e.children}</span>`}function Se(e){const{text:t,tone:n}=e.fact;return n==="warn"||n==="bad"?s`<${q} tone=${n}>${t}<//>`:n==="ok"?s`<span class="rp-plain rp-toned" data-tone="ok">${t}</span>`:s`<span class="rp-plain">${t}</span>`}function Oe(){return on(),ln.value,Date.now()/1e3}function xe(e){const t=Oe()-e.atSec,n=e.what?` ${e.what}`:"",r=t<tn?`방금${n}`:`${Re(t)} 전${n}`;return s`<span class="rp-section-note rp-nowrap" title=${me(e.atSec)}>${r}</span>`}function ds(){const[e,t]=v(0);return O(()=>{const n=Date.now(),r=setInterval(()=>t(Math.floor((Date.now()-n)/1e3)),1e3);return()=>clearInterval(r)},[]),e}function Ze(e){const t=ds();return s`${e.what}${t>=ls?` ${t}초째`:""}`}function et(e){return s`<div class="rp-empty" role="status"><${Ze} what=${`${e.what} 불러오는 중…`} /></div>`}function tt(e){return s`
    <div class="rp-notice" data-tone="bad" role="alert">
      <span>${e.what} 조회 실패: ${e.message}</span>
      <button type="button" class="btn-ghost" onClick=${e.onRetry}>다시 시도</button>
    </div>
  `}function N(e){return s`
    <div class="rp-fact">
      <dt>${e.label}</dt>
      <dd>
        <span class="rp-fact-v rp-toned" data-tone=${e.tone??"neutral"}>${e.value}</span>
        <span class="rp-fact-sub">${e.sub}</span>
      </dd>
    </div>
  `}const j=["브랜치","원격과 차이","커밋 안 된 변경"];function us(e,t,n){if(e.kind==="value"){const i=Qn(e.data.changes),a=Zn(e.data.head),d=es(e.data.upstream),f=ns(i),$=ss(i),k=ts(e.data.upstream);return s`
      <${N} label=${j[0]} value=${s`<span class="mono">${a.text}</span>`} tone=${a.tone} />
      <${N}
        label=${j[1]}
        value=${d.text}
        tone=${d.tone}
        sub=${k&&s`<span class="mono">${k}</span>`}
      />
      <${N}
        label=${j[2]}
        value=${f.text}
        tone=${f.tone}
        sub=${$&&s`<span>${$}</span>${n}`}
      />
    `}if(e.kind==="failed")return s`
      <${N}
        label=${j[0]}
        value="조회 실패"
        tone="bad"
        sub=${s`<span>${e.error.message}</span><button type="button" class="rp-textbtn" onClick=${t}>다시 시도</button>`}
      />
      <${N} label=${j[1]} value="–" />
      <${N} label=${j[2]} value="–" />
    `;if(e.kind==="absent")return s`
      <${N} label=${j[0]} value="로컬 클론 없음" sub=${e.reason&&s`<span>${e.reason}</span>`} />
      <${N} label=${j[1]} value="–" />
      <${N} label=${j[2]} value="–" />
    `;const r=e.kind==="loading";return j.map((i,a)=>s`
    <${N}
      key=${i}
      label=${i}
      value=${r?a===0?s`<${Ze} what="확인 중…" />`:"…":"미보고"}
    />
  `)}function ps(e,t,n){const r="Keeper가 쓴 파일 · 24시간";if(e===null)return s`<${N} label=${r} value="관리자 전용" />`;if(e.kind==="value"){const{changes:i,unattributed:a}=e.data,d=i.length>0?`쓰기 ${y(i.length)}회`:a>0?`어느 저장소인지 모르는 기록 ${y(a)}건`:void 0;return s`<${N} label=${r} value=${`${y(t)}개`} sub=${d} />`}return e.kind==="failed"?s`
      <${N}
        label=${r}
        value="조회 실패"
        tone="bad"
        sub=${s`<button type="button" class="rp-textbtn" onClick=${n}>다시 시도</button>`}
      />
    `:s`
    <${N}
      label=${r}
      value=${e.kind==="loading"?s`<${Ze} what="확인 중…" />`:"미보고"}
    />
  `}function _e(e){return e!==null&&e.kind==="value"&&e.stale}function fs(e){const[t,n]=v(!1),r=e.git.kind==="value"?e.git.data.changes:[],i=r.length>0&&s`
    <button
      type="button"
      class="rp-textbtn"
      aria-expanded=${t}
      onClick=${()=>n(a=>!a)}
    >
      ${t?"목록 접기":"목록 보기"}
    </button>
  `;return s`
    <dl
      class="rp-facts"
      aria-busy=${e.git.kind==="loading"||_e(e.git)||_e(e.activity)}
      data-rereading=${_e(e.git)||_e(e.activity)}
    >
      ${us(e.git,e.onRetryGit,i)}
      ${ps(e.activity,e.fileCount,e.onRetryActivity)}
    </dl>
    ${t&&r.length>0&&s`
      <div class="rp-files" aria-label="커밋 안 된 파일">
        ${os(r).map(a=>s`
          <section key=${a.kind} class="rp-files-group">
            <h4>${a.kind} ${y(a.paths.length)}</h4>
            ${is(a.paths).map(d=>s`
              <details key=${d.dir} class="rp-dir" open=${d.names.length<=cs}>
                <summary><span class="mono">${d.dir}</span> <span class="rp-count">${y(d.names.length)}</span></summary>
                <ul>
                  ${d.names.map(f=>s`<li key=${f}>${f}</li>`)}
                </ul>
              </details>
            `)}
          </section>
        `)}
      </div>
    `}
  `}const $s=80,bs=560;function ms(e){return[{id:"number",header:"번호",sortable:!0,sortValue:t=>t.number,cell:t=>e?s`<a class="rp-link rp-nowrap mono" href=${jn(e,t.number)} target="_blank" rel="noreferrer">#${t.number}</a>`:s`<span class="rp-nowrap mono">#${t.number}</span>`},{id:"title",header:"제목",sortable:!0,sortValue:t=>(t.title??"").toLowerCase(),cell:t=>s`
        <span class="rp-pr-title" title=${t.title??void 0}>
          ${t.draft&&s`<span class="rp-draft">Draft</span>`}${t.title??"(제목 없음)"}
        </span>
      `},{id:"author",header:"작성",sortable:!0,sortValue:t=>t.keeper??t.author??"",cell:t=>t.keeper?s`<${te} id=${t.keeper} size="sm" />`:s`<span class="rp-plain rp-nowrap">${t.author??"미보고"}</span>`},{id:"checks",header:"CI",sortable:!0,sortValue:t=>Bn[t.checks],cell:t=>s`<${Se} fact=${Vn[t.checks]} />`},{id:"review",header:"리뷰",sortable:!0,sortValue:t=>Un[t.review],cell:t=>s`
        <${Se} fact=${Wn[t.review]} />
        ${t.headReview==="not_reviewed_on_head"&&(t.review==="approved"||t.review==="changes_requested")&&s`<div class="rp-fact-sub rp-nowrap">최신 커밋은 리뷰 전</div>`}
      `},{id:"mergeable",header:"병합",sortable:!0,sortValue:t=>qn[t.mergeable],cell:t=>s`<${Se} fact=${zn[t.mergeable]} />`}]}function hs(e){const t=Ot(e.pulls),n=(r,i,a,d)=>a>0&&s`
    <button
      type="button"
      class="rp-chip rp-chip-btn"
      data-tone=${d}
      aria-pressed=${e.filter===r}
      onClick=${()=>e.onFilter(e.filter===r?"all":r)}
    >
      ${i} ${a}
    </button>
  `;return s`
    <div class="rp-chips" role="group" aria-label="PR 걸러 보기">
      ${n("conflicting","충돌",t.conflicting,"bad")}
      ${n("checksFailing","CI 실패",t.checksFailing,"bad")}
      ${n("changesRequested","변경 요청",t.changesRequested,"warn")}
      ${n("ready","병합 준비",t.ready,"ok")}
      ${e.filter!=="all"&&s`
        <span class="rp-section-note">${y(Pt(e.pulls,e.filter).length)}건만 표시</span>
        <button type="button" class="rp-textbtn" onClick=${()=>e.onFilter("all")}>전체 보기</button>
      `}
    </div>
  `}function vs(e){const t=Ot(e.pulls);return s`
    <span class="rp-chips">
      <span class="rp-count">${t.total}</span>
      ${e.unreadable>0&&s`<${q} tone="warn">읽지 못함 ${y(e.unreadable)}<//>`}
      ${t.conflicting>0&&s`<${q} tone="bad">충돌 ${t.conflicting}<//>`}
      ${t.checksFailing>0&&s`<${q} tone="bad">CI 실패 ${t.checksFailing}<//>`}
      ${t.changesRequested>0&&s`<${q} tone="warn">변경 요청 ${t.changesRequested}<//>`}
      ${t.ready>0&&s`<${q} tone="ok">병합 준비 ${t.ready}<//>`}
    </span>
  `}function gs(e){const{snapshot:t,entry:n}=e,r=Y(()=>ms(n?.slug??null),[n?.slug]);if(t.kind==="loading")return s`<${et} what="GitHub PR" />`;if(t.kind==="failed")return s`<${tt} what="GitHub PR" message=${t.error.message} onRetry=${e.onRetry} />`;if(t.kind!=="value")return s`<div class="rp-empty">서버가 GitHub PR을 보내지 않았습니다.</div>`;if(t.data.repositoriesError!==null)return s`
      <div class="rp-notice" data-tone="bad" role="alert">
        저장소 목록을 읽지 못해 PR을 가져오지 못했습니다: ${t.data.repositoriesError}
      </div>
    `;if(!n||n.pulls.kind==="not_read")return s`
      <div class="rp-empty">${Hn(t.data.reader)??"아직 이 저장소의 PR을 읽지 않았습니다."}</div>
    `;if(n.pulls.kind==="not_github")return s`<div class="rp-empty">GitHub 저장소가 아니어서 PR을 읽지 않습니다.</div>`;if(n.pulls.kind==="failed")return s`<div class="rp-notice" data-tone="bad" role="alert">${Gn(n.pulls.failure)}</div>`;const{pulls:i,unreadable:a}=n.pulls,d=Pt(i,e.filter),f=d.length>$s,{keepers:$}=t.data;return s`
    ${a>0&&s`
      <div class="rp-notice" data-tone="warn">PR ${y(a)}건은 응답을 읽지 못해 표에 없습니다.</div>
    `}
    ${i.length===0?s`<div class="rp-empty">열린 PR이 없습니다.</div>`:s`
          <${ae}
            data=${d}
            columns=${r}
            getRowId=${k=>String(k.number)}
            initialSort=${{id:"number",desc:!0}}
            maxHeight=${f?bs:void 0}
            caption="열린 GitHub PR"
            className=${f?"rp-pulls":"rp-pulls rp-pulls-flow"}
          />
        `}
    ${$.kind==="list_failed"&&i.length>0&&s`
      <p class="rp-section-note">
        Keeper 목록을 읽지 못해 작성자를 GitHub 계정 이름으로만 보여 줍니다: ${$.reason}
      </p>
    `}
  `}const Ee="infra:repositories",Ae="infra:repository-pulls",$e=e=>`infra:repo-git:${e}`,be=e=>`infra:repo-activity:${e}`,nt=2e4,ys=3e4;function he(e){return e.kind==="single_user_local"}function Le(e){return he(e)&&!Jt("admin",e)}function Pe(e){return Promise.resolve(D.observe(e).peek())}function ks(e){const t="GET /api/v1/ide/repository-activity",n=Ct(e,t),r=rn(n,"changes",t);return{repo_id:typeof n.repo_id=="string"?n.repo_id:"",window_hours:typeof n.window_hours=="number"?n.window_hours:24,incomplete:typeof n.incomplete=="number"?n.incomplete:0,unattributed:typeof n.unattributed=="number"?n.unattributed:0,changes:r}}function ee(e){return he(V.peek())?D.fetch(Ee,t=>Te("/api/v1/repositories",{signal:t,decode:Rn}),{ttlMs:nt,topics:["repositories"],reason:e}):Pe(Ee)}function oe(e){return he(V.peek())?D.fetch(Ae,t=>Te("/api/v1/repositories/pulls",{signal:t,decode:Fn}),{ttlMs:ys,topics:["repositories"],reason:e}):Pe(Ae)}function ue(e,t){return he(V.peek())?D.fetch($e(e),n=>Te(`/api/v1/git/status?repo_id=${encodeURIComponent(e)}`,{signal:n,decode:Yn}),{ttlMs:nt,topics:["repositories"],reason:t}):Pe($e(e))}function re(e,t){return Le(V.peek())?D.fetch(be(e),n=>Xt({method:"GET",path:`/api/v1/ide/repository-activity?repo_id=${encodeURIComponent(e)}&window_hours=24`,envelope:"ok_data",decode:ks,signal:n}),{ttlMs:nt,topics:["repository_activity"],reason:t}):Pe(be(e))}function Ie(e,t){O(()=>{e.kind==="value"&&e.stale&&t()},[e])}const _s=300,Ss=8,ws=340;function Nt(e){const t=Oe(),n=kn(e.repo.status),r=Ye(e.repo,t)!==null;return s`<${Se} fact=${r?{text:n.text,tone:"warn"}:n} />`}function Rs(e){const t=Sn(e.repo,Oe()),n=e.repo.updated_at;return s`
    <span class="rp-toned rp-nowrap" data-tone=${t.tone} title=${n!==null?me(n):void 0}>
      ${t.text}
    </span>
  `}function xs(e){const t=Ye(e.repo,Oe());return t===null?null:s`
    <div class="rp-notice" data-tone="warn" role="status">
      ${Re(t.intervalSec)}마다 동기화하는 저장소인데 ${Re(t.ageSec)}째 가져오는 중입니다.
      가져오는 중인 저장소는 자동 동기화에서 빠집니다.
      ${e.canSync?"동기화를 누르면 다시 가져옵니다.":"관리자가 동기화하면 다시 가져옵니다."}
    </div>
  `}const mt=-1;function Es(e,t){if(e.kind!=="value")return mt;const n=e.data.byRepo.get(t);return n?.pulls.kind==="read"?n.pulls.pulls.length:mt}function As(e){const{pulls:t}=e;if(t.kind==="loading")return s`<span class="rp-plain">확인 중…</span>`;if(t.kind==="failed")return s`<span class="rp-toned" data-tone="bad">조회 실패</span>`;if(t.kind!=="value")return s`<span class="rp-plain">미보고</span>`;if(t.data.repositoriesError!==null)return s`<span class="rp-toned" data-tone="bad">조회 실패</span>`;const n=t.data.byRepo.get(e.repoId);return!n||n.pulls.kind==="not_read"?s`<span class="rp-plain">읽지 않음</span>`:n.pulls.kind==="not_github"?s`<span class="rp-plain">GitHub 아님</span>`:n.pulls.kind==="failed"?s`<${q} tone="bad">조회 실패<//>`:s`<${vs} pulls=${n.pulls.pulls} unreadable=${n.pulls.unreadable} />`}function Ls(e){const{pulls:t,selectedId:n,onSelect:r}=e,i=Y(()=>[{id:"name",header:"저장소",sortable:!0,sortValue:a=>a.name.toLowerCase(),cell:a=>s`
        <button
          type="button"
          class="rp-repo-btn"
          aria-pressed=${a.id===n}
          onClick=${d=>{d.stopPropagation(),r(a.id)}}
        >
          ${a.name}
        </button>
      `},{id:"status",header:"상태",sortable:!0,sortValue:a=>yn[a.status.kind],cell:a=>s`
        <span class="rp-chips">
          <${Nt} repo=${a} />
          ${a.auto_sync===!1&&s`<${q}>자동 동기화 꺼짐<//>`}
        </span>
      `},{id:"synced",header:"마지막 동기화",sortable:!0,sortValue:a=>a.updated_at??0,cell:a=>s`<${Rs} repo=${a} />`},{id:"pulls",header:"열린 PR",sortable:!0,sortValue:a=>Es(t,a.id),cell:a=>s`<${As} pulls=${t} repoId=${a.id} />`}],[t,n,r]);return s`
    <${ae}
      data=${e.repos}
      columns=${i}
      getRowId=${a=>a.id}
      selectedRowId=${n}
      onRowClick=${a=>r(a.id)}
      initialSort=${{id:"name"}}
      maxHeight=${e.repos.length>Ss?ws:void 0}
      caption="등록된 저장소"
      className="rp-repos"
    />
  `}function Is(e){const[t,n]=v(""),[r,i]=v(""),[a,d]=v("main"),[f,$]=v(!1),[k,I]=v(null),h=C(!0);O(()=>(h.current=!0,()=>{h.current=!1}),[]);const E=C(!1),P=async F=>{if(F.preventDefault(),E.current||!Le(V.peek()))return;const g=t.trim(),_=r.trim();if(!g||!_){I("이름과 Git URL(또는 로컬 경로)을 입력해 주세요.");return}const p=we();E.current=!0,$(!0),I(null);try{const T=await Xe("POST","/api/v1/repositories",{name:g,url:_,default_branch:a.trim()||"main",auto_sync:!0,sync_interval:_s});if(!h.current||!U(p))return;if(!T.ok){I(`저장소 등록 실패: ${T.error.message}`);return}e.onAdded(g)}finally{E.current=!1,h.current&&$(!1)}},w=(F,g,_,p,T)=>s`
    <label class="rp-field">
      <span>${F}</span>
      <input
        type="text"
        placeholder=${g}
        value=${_}
        required=${T}
        disabled=${f}
        onInput=${H=>p(H.target.value)}
      />
    </label>
  `;return s`
    <form class="rp-form" onSubmit=${P}>
      ${w("이름","masc",t,n,!0)}
      ${w("Git URL 또는 로컬 경로","https://github.com/owner/repo.git",r,i,!0)}
      ${w("기본 브랜치","main",a,d,!1)}
      <button type="submit" class="btn-primary" disabled=${f}>${f?"등록 중…":"등록"}</button>
      ${k!==null&&s`<div class="rp-notice rp-form-wide" data-tone="bad" role="alert">${k}</div>`}
    </form>
  `}const Ge=20,Ve=3,Cs=18,We=2;function Dt(e){const t=e.patch.split(`
`),n=e.fromFirstHunk?t.findIndex(d=>d.startsWith("@@")):-1,r=n>0?t.slice(n):t,i=r.length>e.maxLines?r.slice(0,e.maxLines):r,a=r.length-i.length;return s`
    <pre class="rp-diff">${i.map((d,f)=>s`<span key=${f} data-line=${cn(d)}>${d}</span>`)}${a>0&&s`<span data-line="cut">… ${y(a)}줄 더 있음</span>`}</pre>
  `}function Ts(e){const{file:t}=e,[n,r]=v(!1),[i,a]=v(Ve),{dir:d,name:f}=Qe(t.path),$=t.writes.slice(0,i),k=t.writes.length-$.length,I=t.keepers.length-We;return s`
    <li class="rp-file">
      <div class="rp-file-h">
        <button
          type="button"
          class="rp-file-toggle"
          aria-expanded=${n}
          title=${t.path}
          onClick=${()=>r(h=>!h)}
        >
          <span class="rp-file-caret" aria-hidden="true">${n?"▾":"▸"}</span>
          ${d!==null&&s`<span class="rp-file-dir">${d}</span>`}
          <span class="rp-file-name">${f}</span>
        </button>
        <span class="rp-file-meta">
          ${t.failed>0&&s`<${q} tone="bad">실패 ${y(t.failed)}<//>`}
          ${t.keepers.slice(0,We).map(h=>s`<${te} key=${h} id=${h} size="sm" />`)}
          ${I>0&&s`<span class="rp-section-note" title=${t.keepers.slice(We).join(", ")}>+${I}</span>`}
          <span class="rp-file-count">쓰기 ${y(t.writes.length)}회</span>
          <span class="rp-file-when"><${xe} atSec=${t.lastAt} /></span>
        </span>
      </div>
      ${n&&s`
        <ol class="rp-writes">
          ${$.map((h,E)=>s`
            <li key=${`${h.at}-${E}`} class="rp-write">
              <div class="rp-write-h">
                <span class="rp-section-note rp-nowrap">${me(h.at)}</span>
                <${te} id=${h.keeper} size="sm" />
                ${h.task_id!==null&&s`<span class="rp-section-note mono">${h.task_id}</span>`}
                ${!h.succeeded&&s`<${q} tone="bad">실패<//>`}
                <button type="button" class="rp-textbtn" onClick=${()=>e.onInspect(h)}>전체 Diff</button>
              </div>
              <${Dt} patch=${e.patchOf(h)} maxLines=${Cs} fromFirstHunk />
            </li>
          `)}
          ${k>0&&s`
            <li>
              <button type="button" class="rp-textbtn" onClick=${()=>a(h=>h+Ve)}>
                ${y(t.writes.length)}회 중 ${y($.length)}회 표시 · ${y(Math.min(Ve,k))}회 더 보기
              </button>
            </li>
          `}
        </ol>
      `}
    </li>
  `}function Os(e){const[t,n]=v(Ge),{activity:r,files:i}=e;if(r.kind==="loading")return s`<${et} what="Keeper가 쓴 파일" />`;if(r.kind==="failed")return s`<${tt} what="Keeper가 쓴 파일" message=${r.error.message} onRetry=${e.onRetry} />`;if(r.kind!=="value")return s`<div class="rp-empty">서버가 Keeper 파일 기록을 보내지 않았습니다.</div>`;const{incomplete:a,unattributed:d}=r.data,f=i.slice(0,t),$=i.length-f.length;return s`
    ${i.length===0?s`<div class="rp-empty">최근 24시간 동안 Keeper가 이 저장소에 쓴 파일이 없습니다.</div>`:s`
          <ul class="rp-filelist">
            ${f.map(k=>s`
              <${Ts} key=${k.path} file=${k} patchOf=${e.patchOf} onInspect=${e.onInspect} />
            `)}
          </ul>
        `}
    ${$>0&&s`
      <button type="button" class="btn-ghost rp-more" onClick=${()=>n(k=>k+Ge)}>
        ${y(i.length)}개 중 ${y(f.length)}개 표시 · ${y(Math.min(Ge,$))}개 더 보기
      </button>
    `}
    ${a>0&&s`
      <p class="rp-section-note">이 저장소의 변경 ${y(a)}건은 기록이 잘려 내용을 보여 줄 수 없습니다.</p>
    `}
    ${d>0&&s`
      <p class="rp-section-note">전체 Keeper 기록 ${y(d)}건은 파일 위치가 남지 않아 어느 저장소 것인지 알 수 없습니다.</p>
    `}
  `}const vr=[{id:"sandboxes",label:"Sandboxes"},{id:"repos",label:"Repos & 24h Changes"},{id:"logs",label:"Activity & Logs"}];function Ps(e){const t=e.trim().toLowerCase();return t==="repos"||t==="logs"?t:"sandboxes"}function Ns(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?"없음":new Date(e*1e3).toISOString().replace("T"," ").slice(5,19)}function je(e){if(typeof e=="string"&&e.trim())return e;if(e&&typeof e=="object"){const t=e;for(const n of["path","relative_path","file","file_path"])if(typeof t[n]=="string"&&t[n].trim())return t[n]}return"(경로 미보고)"}function Ds(e){if(typeof e=="string")return{before:"",after:e};if(e&&typeof e=="object"){const t=e;if(typeof t.unified_diff=="string")return{before:"",after:"",unified:t.unified_diff};if(typeof t.diff=="string")return{before:"",after:"",unified:t.diff};if(t.kind==="edit")return{before:typeof t.before=="string"?t.before:"",after:typeof t.after=="string"?t.after:""};if(t.kind==="write")return{before:"",after:typeof t.content=="string"?t.content:""};if(t.kind==="insert"){const i=typeof t.text=="string"?t.text:"",a=typeof t.line=="number"&&Number.isFinite(t.line)?Math.trunc(t.line):null,d=i.length>0?i.split(`
`):[""],f=a!==null&&a>0?a:1,$=d.map(k=>`+${k}`).join(`
`);return{before:"",after:i,unified:`@@ -${f},0 +${f},${d.length} @@
${$}`}}if(t.kind==="materialize")return{before:"",after:`[materialized content sha256=${typeof t.sha256=="string"&&t.sha256.trim()?t.sha256.trim():"unknown"}]`};const n=typeof t.before=="string"?t.before:typeof t.old_text=="string"?t.old_text:typeof t.old_string=="string"?t.old_string:"",r=typeof t.after=="string"?t.after:typeof t.new_text=="string"?t.new_text:typeof t.new_string=="string"?t.new_string:typeof t.content=="string"?t.content:JSON.stringify(e,null,2);return{before:n,after:r}}return{before:"",after:""}}const Ms=500,Ks="--rp-head-h",ht="가져오는 중…";function vt(e){const t=je(e.location),{before:n,after:r,unified:i}=Ds(e.change);return i||sn(`a/${t}`,`b/${t}`,n,r,"before","after",{context:3})}function Fs(){const e=C(null),t=C(null);return O(()=>{const n=e.current,r=t.current;if(n===null||r===null||typeof ResizeObserver>"u")return;const i=()=>{n.style.setProperty(Ks,`${Math.floor(r.getBoundingClientRect().height)}px`)};i();const a=new ResizeObserver(i);return a.observe(r),()=>a.disconnect()},[]),{card:e,head:t}}function Hs(e){const{dir:t,name:n}=Qe(e.path);return s`
    <span class="rp-path" title=${`서버의 로컬 클론 경로: ${e.path}`}>
      ${e.afterAddress&&s`<span class="rp-path-sep" aria-hidden="true">·</span>`}
      ${t!==null&&s`<span class="rp-path-dir">${t.slice(0,-1)}</span>`}
      <span class="rp-path-name">${t!==null?`/${n}`:n}</span>
    </span>
  `}function Gs(e){const{repo:t,pulls:n,unfinishedSync:r}=e,i=D.observe($e(t.id)).value,a=D.observe(be(t.id)).value,[d,f]=v("all"),{card:$,head:k}=Fs();O(()=>{ue(t.id,"mount"),re(t.id,"mount")},[e.canAdmin]);const I=`${t.status.kind}:${t.updated_at}`,h=C(I);O(()=>{h.current!==I&&(h.current=I,ue(t.id,"manual"),re(t.id,"manual"),oe("manual"))},[I]),Ie(i,()=>{ue(t.id,"mount")}),Ie(a,()=>{re(t.id,"mount")});const E=Y(()=>a.kind==="value"?En(a.data.changes,p=>je(p.location)):[],[a]),P=p=>{const T=vt(p);e.onInspect({title:je(p.location),subtitle:`${p.keeper} · ${me(p.at)}${p.task_id?` · ${p.task_id}`:""}`,kind:"repo_diff",data:p,render:()=>s`
        <div class="rp-section">
          <div class="rp-chips">
            <${te} id=${p.keeper} size="sm" />
            <${q} tone=${p.succeeded?"ok":"bad"}>${p.succeeded?"적용 성공":"실패"}<//>
            ${p.turn!==null&&s`<span class="rp-section-note">turn #${p.turn}</span>`}
          </div>
          <${Dt} patch=${T} maxLines=${Ms} />
        </div>
      `})},w=n.kind==="value"?n.data.byRepo.get(t.id):void 0,F=w?.pulls.kind==="read"?w.pulls.pulls:[],g=w&&(w.pulls.kind==="read"||w.pulls.kind==="failed")?w.pulls.observedAt:null,_=a.kind==="value"?a.data.changes.length:0;return s`
    <section class="rp-detail" ref=${$} aria-label=${`${t.name} 상세`}>
      <div class="rp-head" ref=${k}>
        <div class="rp-head-main">
          <div class="rp-head-title">
            <h2>${t.name}</h2>
            ${t.status.kind!=="active"&&s`<${Nt} repo=${t} />`}
          </div>
          <div class="rp-head-sub">
            ${w?.slug&&s`
              <a class="rp-link" href=${`https://github.com/${w.slug}`} target="_blank" rel="noreferrer">${w.slug}</a>
            `}
            ${t.local_path!==null&&s`<${Hs} path=${t.local_path} afterAddress=${!!w?.slug} />`}
          </div>
        </div>
        ${e.canAdmin&&s`
          <button type="button" class="btn-primary" data-wide-label=${ht} disabled=${e.syncing} onClick=${e.onSync}>
            <span>${e.syncing?ht:"동기화"}</span>
          </button>
        `}
      </div>

      <div class="rp-body">
        ${t.status.kind==="error"&&s`
          <div class="rp-notice" data-tone="bad" role="alert">
            ${t.status.message!==null?`마지막 동기화 실패: ${t.status.message}`:"마지막 동기화가 실패했습니다. 서버가 이유를 남기지 않았습니다."}
          </div>
        `}
        <${xs} repo=${t} canSync=${e.canAdmin} />
        ${r&&s`
          <div class="rp-notice" data-tone=${r.fact.tone}>
            <span role=${r.fact.tone==="bad"?"alert":"status"}>${r.fact.text}</span>
            <${xe} atSec=${r.atSec} what="동기화" />
          </div>
        `}

        <${fs}
          git=${i}
          activity=${e.canAdmin?a:null}
          fileCount=${E.length}
          onRetryGit=${()=>{ue(t.id,"manual")}}
          onRetryActivity=${()=>{re(t.id,"manual")}}
        />

        <section class="rp-section" aria-label="열린 GitHub PR">
          <div class="rp-section-h">
            <div class="rp-section-title">
              <h3>열린 PR${w?.pulls.kind==="read"?` ${y(F.length)}`:""}</h3>
              <${hs} pulls=${F} filter=${d} onFilter=${f} />
            </div>
            ${g!==null&&s`<${xe} atSec=${g} what="GitHub 확인" />`}
          </div>
          <${gs}
            snapshot=${n}
            entry=${w}
            filter=${d}
            onRetry=${()=>{oe("manual")}}
          />
        </section>

        <section class="rp-section" aria-label="Keeper가 쓴 파일">
          <div class="rp-section-h">
            <h3>최근 24시간 Keeper가 쓴 파일${e.canAdmin&&a.kind==="value"?` ${y(E.length)}`:""}</h3>
            ${e.canAdmin&&E.length>0&&s`
              <span class="rp-section-note">쓰기 ${y(_)}회 · 최근에 쓴 순</span>
            `}
          </div>
          ${e.canAdmin?s`
                <${Os}
                  activity=${a}
                  files=${E}
                  patchOf=${vt}
                  onInspect=${P}
                  onRetry=${()=>{re(t.id,"manual")}}
                />
              `:s`
                <div class="rp-empty" data-testid="infra-repo-activity-admin-locked" role="status">
                  Keeper가 쓴 파일 기록과 저장소 등록·동기화는 관리자 전용입니다.
                </div>
              `}
        </section>
      </div>
    </section>
  `}const Je=1e3,Vs=5e3,Ws=[];function zs(e){let t=null;for(const n of e.keys){const r=D.observe(n).value;r.kind==="value"&&(t===null||r.updatedAt<t)&&(t=r.updatedAt)}return t===null?null:s`<${xe} atSec=${t/Je} what="조회" />`}function Bs(e){const t=V.value,n=he(t),r=Le(t),i=D.observe(Ee).value,a=D.observe(Ae).value,[d,f]=v(null),[$,k]=v(!1),[I,h]=v(!1),[E,P]=v(new Set),[w,F]=v({}),g=C(!0);O(()=>(g.current=!0,()=>{g.current=!1}),[]);const _=i.kind==="value"?i.data:Ws,p=_.find(m=>m.id===d)??Ln(_),T=C(!1),H=C(new Set);O(()=>{p!==null&&p.id!==d&&f(p.id)},[p,d]),O(()=>{ee("mount"),oe("mount")},[n]),Ie(i,()=>{ee("mount")}),Ie(a,()=>{oe("mount")});const Q=_.some(m=>_n(m,Date.now()/Je)),z=C(!1);O(()=>{if(!Q)return;const m=setInterval(()=>{z.current||(z.current=!0,ee("manual").finally(()=>{z.current=!1}))},Vs);return()=>clearInterval(m)},[Q]);const J=async()=>{if(!T.current){T.current=!0,h(!0);try{await Promise.all([ee("manual"),oe("manual"),...p!==null?[ue(p.id,"manual"),re(p.id,"manual")]:[]])}finally{T.current=!1,g.current&&h(!1)}}},u=async m=>{const A=we();Ue(`저장소 '${m}' 등록 완료.`,"success"),k(!1),oe("manual");const M=await ee("manual");if(!g.current||!U(A))return;const x=M.kind==="value"?M.data.find(o=>o.name===m):void 0;x&&f(x.id)},B=async m=>{if(!Le(V.peek())||H.current.has(m.id))return;const A=we();H.current.add(m.id),P(M=>new Set(M).add(m.id));try{const M=await Xe("POST",`/api/v1/repositories/${encodeURIComponent(m.id)}/sync`,{},{decode:L=>hn(L,m.id)});if(!g.current||!U(A))return;const x=Date.now()/Je;let o=null,l=null;if(!M.ok)l={text:`동기화 실패: ${M.error.message}`,tone:"bad"};else{const L=vn(M.value);L.tone==="success"?o=`${m.name} 동기화 완료. ${L.message}`:l={text:L.message,tone:"warn"}}if(await ee("manual"),!g.current||!U(A))return;F(({[m.id]:L,...ve})=>l===null?ve:{...ve,[m.id]:{fact:l,atSec:x}}),o!==null&&Ue(o,"success"),D.invalidateKey($e(m.id)),D.invalidateKey(be(m.id))}finally{H.current.delete(m.id),g.current&&P(M=>{const x=new Set(M);return x.delete(m.id),x})}},X=[Ee,Ae,...p!==null?[$e(p.id)]:[],...p!==null&&r?[be(p.id)]:[]],Z=s`
    <div>
      <span class="ov-eyebrow">6 INFRA · REPOS</span>
      <h1>저장소</h1>
    </div>
  `;return n?s`
    <div class="ov" data-testid="infra-repos-tab">
      <header class="ov-head">
        ${Z}
        <div class="rp-head-actions">
          <${zs} keys=${X} />
          <button type="button" class="btn-ghost" disabled=${I} onClick=${()=>{J()}}>
            ${I?"새로고침 중…":"새로고침"}
          </button>
          ${r&&s`
            <button type="button" class="btn-ghost" aria-expanded=${$} onClick=${()=>k(m=>!m)}>
              ${$?"추가 취소":"저장소 추가"}
            </button>
          `}
        </div>
      </header>

      ${r&&$&&s`<${Is} onAdded=${m=>{u(m)}} />`}

      ${i.kind==="loading"&&s`<${et} what="저장소 목록" />`}
      ${i.kind==="failed"&&s`
        <${tt} what="저장소 목록" message=${i.error.message} onRetry=${()=>{ee("manual")}} />
      `}
      ${(i.kind==="absent"||i.kind==="unreported")&&s`
        <div class="rp-empty">서버가 저장소 목록을 보내지 않았습니다.</div>
      `}
      ${i.kind==="value"&&_.length===0&&s`
        <div class="rp-empty">등록된 저장소가 없습니다.</div>
      `}

      ${_.length>0&&s`
        <${Ls} repos=${_} pulls=${a} selectedId=${p?.id??null} onSelect=${f} />
      `}

      ${p!==null&&s`
        <${Gs}
          key=${p.id}
          repo=${p}
          pulls=${a}
          canAdmin=${r}
          syncing=${E.has(p.id)}
          unfinishedSync=${w[p.id]}
          onSync=${()=>{B(p)}}
          onInspect=${e.onInspect}
        />
      `}
    </div>
  `:s`
      <div class="ov" data-testid="infra-repos-tab">
        <header class="ov-head">${Z}</header>
        <div class="rp-empty" data-testid="infra-repos-mode-notice" role="status">
          저장소 목록과 Keeper 파일 기록(<span class="mono">/api/v1/repositories</span>, <span class="mono">/api/v1/ide/repository-activity</span>)은 single_user 모드 전용입니다.
        </div>
      </div>
    `}function gt(e){switch(e){case"matched":return{background:"var(--ok-soft)",border:"1px solid var(--ok-border)",color:"var(--ok-fg)"};case"mismatch":return{background:"var(--err-soft)",border:"1px solid var(--err-border)",color:"var(--err-fg)"};case"undeclared":return{background:"var(--idle-soft)",border:"1px solid var(--idle-border)",color:"var(--fg-3)"};case"unavailable":return{background:"var(--warn-soft)",border:"1px solid var(--warn-border)",color:"var(--warn-fg)"};default:return{background:"var(--bg-2)",border:"1px solid var(--line-2)",color:"var(--fg-2)"}}}function Us(e){switch(e){case"present":case"running":return{background:"var(--ok-soft)",border:"1px solid var(--ok-border)",color:"var(--ok-fg)"};case"probe_pending":return{background:"var(--info-soft)",border:"1px solid var(--info-border)",color:"var(--info-fg)"};case"absent":case"stopped":return{background:"var(--idle-soft)",border:"1px solid var(--idle-border)",color:"var(--fg-3)"};case"unavailable":case"error":return{background:"var(--warn-soft)",border:"1px solid var(--warn-border)",color:"var(--warn-fg)"};default:return{background:"var(--bg-2)",border:"1px solid var(--line-1)",color:"var(--fg-2)"}}}function yt(e){if(typeof e=="string"){const t=e.trim();return t?{status:t}:null}if(e&&typeof e=="object"&&typeof e.status=="string"){const t=e.status.trim();if(!t)return null;const n=[];return e.build_identity&&n.push(`build: ${e.build_identity}`),e.shim_identity&&n.push(`shim: ${e.shim_identity}`),e.server_identity&&n.push(`server: ${e.server_identity}`),e.detail&&n.push(e.detail),{status:t,tooltip:n.length>0?n.join(`
`):void 0}}return null}function kt(e){const t=e.presence??e.state??e.status;return typeof t=="string"&&t.trim().length>0?t.trim():null}function _t(e){if(e.agent_socket&&typeof e.agent_socket=="object"){const{status:t,path_basename:n,file_kind:r}=e.agent_socket;switch(t){case"socket_present":return{label:"소켓 경로 존재",tone:"muted",tooltip:n};case"socket_absent":return{label:"absent",tone:"muted",tooltip:n};case"non_socket":return{label:"non_socket",tone:"err",tooltip:r??n};case"unreadable":return{label:"unreadable",tone:"warn",tooltip:n};default:return t?{label:t,tone:"muted",tooltip:n}:null}}return typeof e.socket_present=="boolean"?e.socket_present?{label:"소켓 경로 존재",tone:"muted"}:{label:"missing",tone:"err"}:null}function St(e){const t=[];e.backend&&t.push(e.backend);const n=e.guest_size?.cpus,r=e.guest_size?.memory_mib;if(typeof n=="number"||typeof r=="number"){const i=[typeof n=="number"?`${n}c`:null,typeof r=="number"?`${r}MiB`:null].filter(Boolean);i.length>0&&t.push(i.join(" / "))}return e.network_mode&&t.push(`net:${e.network_mode}`),typeof e.pid=="number"&&t.push(`PID ${e.pid}`),t.length>0?t.join(" · "):null}function G(e){if(typeof e!="string")return null;const t=e.trim();return t.length>0?t:null}function ze(e){const t=new Set;for(const n of e){const r=G(n);r&&t.add(r)}return[...t]}function wt(e){if(Array.isArray(e.keeper_sessions))return ze(e.keeper_sessions.map(t=>t?.keeper));if(Array.isArray(e.accounts)){const t=[];for(const n of e.accounts)Array.isArray(n?.keepers)&&t.push(...n.keepers);return ze(t)}return Array.isArray(e.keepers)?ze(e.keepers):null}function Rt(e){if(!e.host)return"없음";const t=e.unix_user?`${e.unix_user}@`:"",n=typeof e.port=="number"&&e.port!==22?`:${e.port}`:"";return`${t}${e.host}${n}`}function xt(e){return e<10?`${e.toFixed(1)}ms`:`${Math.round(e)}ms`}const Et={display:"inline-flex",alignItems:"center",padding:"0 var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",fontWeight:600,whiteSpace:"nowrap"};function qs(e){switch(e){case"fresh":return{background:"var(--ok-soft)",border:"1px solid var(--ok-border)",color:"var(--ok-fg)"};case"warming":return{background:"var(--info-soft)",border:"1px solid var(--info-border)",color:"var(--info-fg)"};case"stale":return{background:"var(--warn-soft)",border:"1px solid var(--warn-border)",color:"var(--warn-fg)"};case"error":return{background:"var(--err-soft)",border:"1px solid var(--err-border)",color:"var(--err-fg)"}}}function js(e){if(typeof e=="number"&&Number.isFinite(e))return Number.isInteger(e)?String(e):e.toFixed(1);if(typeof e=="boolean")return e?"true":"false";if(typeof e=="string"){const t=e.trim();return t?t.length>28?`${t.slice(0,27)}…`:t:null}return null}function At(e){if(!e)return"미보고";const t=[],n=(i,a)=>{for(const[d,f]of Object.entries(i)){const $=js(f);$!==null?t.push(`${d}: ${$}`):a===0&&f&&typeof f=="object"&&!Array.isArray(f)&&n(f,1)}};if(n(e,0),t.length===0){const i=Object.keys(e).length;return i>0?`${i}개 항목`:"비어 있음"}const r=t.slice(0,3).join(" · ");return t.length>3?`${r} (+${t.length-3})`:r}function Js(e){const t="GET /api/v1/infra/sandboxes",n=Ct(e,t);Fe(n,"probe_state",t),Fe(n,"summary",t),Fe(n,"shim_parity",t);const r=se(ce(n,"unobserved_reasons",t),"unobserved_reasons",t),i=se(ce(n,"microvm_guests",t),"microvm_guests",t),a=se(ce(n,"ssh_pools",t),"ssh_pools",t),d=se(ce(n,"docker_keepers",t),"docker_keepers",t),f=se(ce(n,"ssh_unbound_keepers",t),"ssh_unbound_keepers",t);return{...n,unobserved_reasons:r,microvm_guests:i,ssh_pools:a,docker_keepers:d,ssh_unbound_keepers:f}}function Xs(e){const t=Lt.value,n=V.value,r=Be(n),i=dt(n),a=D.observe("infra:sandboxes").value,[d,f]=v(!1),[$,k]=v(null),[I,h]=v(null),[E,P]=v(!1),[w,F]=v(!1),g=C(!0);O(()=>(g.current=!0,()=>{g.current=!1}),[]);const _=de(o=>{const l=G(o);l&&e.onNavigate(`/keepers/${encodeURIComponent(l)}/config?section=sandbox`)},[e.onNavigate]),p=(o="mount")=>Be(V.peek())?D.fetch("infra:sandboxes",l=>Qt("/api/v1/infra/sandboxes",{signal:l,decode:Js}),{ttlMs:15e3,topics:["infra_sandboxes","sandboxes"],reason:o}):Promise.resolve();O(()=>{r&&p("mount")},[t,r]);const T=async()=>{if(!dt(V.peek()))return;const o=we();f(!0),k(null);const l=await Xe("POST","/api/v1/infra/sandboxes/probe",{});if(!(!g.current||!U(o))){if(f(!1),!l.ok){k(`샌드박스 프로브 실행 실패: ${l.error.message}`);return}Ue("샌드박스 프로브 요청이 접수되었습니다.","success"),p("manual")}},H=Y(()=>[{id:"name",header:"게스트 / Keeper",sortable:!0,sortValue:o=>G(o.keeper)??o.guest_name??o.name??o.id??"",cell:o=>{const l=G(o.keeper);return l?s`<span title=${o.guest_name??l}><${te} id=${l} size="sm" /></span>`:s`<span class="mono">${o.guest_name??o.name??o.id??"없음"}</span>`}},{id:"presence",header:"상태",sortable:!0,sortValue:o=>kt(o)??"",cell:o=>{const l=kt(o);return l?s`<span class="mono" style=${{...Et,...Us(l)}}>${l}</span>`:s`<span class="dtable-absent">없음</span>`}},{id:"socket",header:"소켓",sortable:!0,sortValue:o=>_t(o)?.label??"",cell:o=>{const l=_t(o);if(!l)return s`<span class="dtable-absent">미보고</span>`;const L=l.tone==="ok"?"var(--ok-fg)":l.tone==="err"?"var(--err-fg)":l.tone==="warn"?"var(--warn-fg)":"var(--fg-3)";return s`<span class="mono" title=${l.tooltip} style=${{color:L}}>${l.label}</span>`}},{id:"parity",header:"Shim Parity",sortable:!0,sortValue:o=>yt(o.shim_parity)?.status??"",cell:o=>{const l=yt(o.shim_parity);return l?s`
          <span
            class="mono"
            title=${l.tooltip}
            style=${{...Et,...gt(l.status)}}
          >
            ${l.status}
          </span>
        `:s`<span class="dtable-absent">미보고</span>`}},{id:"spec",header:"백엔드 / 사양",sortable:!0,sortValue:o=>St(o)??"",cell:o=>{const l=St(o);return l?s`<span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>${l}</span>`:s`<span class="dtable-absent">미보고</span>`}},{id:"actions",header:"설정",cell:o=>{const l=G(o.keeper);return l?s`
              <button
                type="button"
                class="btn-ghost v2-sandbox-row-btn"
                onClick=${()=>_(l)}
              >
                설정 →
              </button>
            `:s`<span class="dtable-absent">—</span>`}}],[_]),Q=Y(()=>[{id:"name",header:"SSH 풀",sortable:!0,accessor:o=>o.pool_name??o.name??o.id??o.host??null},{id:"host",header:"호스트",sortable:!0,sortValue:o=>Rt(o),cell:o=>s`
        <span class="mono" title=${o.remote_root??void 0} style=${{fontSize:"var(--fs-12)"}}>
          ${Rt(o)}
        </span>
      `},{id:"rtt",header:"RTT / 도달성",numeric:!0,sortable:!0,sortValue:o=>o.reachability?.status==="reachable"&&typeof o.reachability.rtt_ms=="number"?o.reachability.rtt_ms:typeof o.rtt_ms=="number"?o.rtt_ms:Number.POSITIVE_INFINITY,cell:o=>{if(o.reachability&&typeof o.reachability=="object"){if(o.reachability.status==="reachable"&&typeof o.reachability.rtt_ms=="number")return s`<span class="mono tnum" style=${{color:"var(--ok-fg)"}}>${xt(o.reachability.rtt_ms)}</span>`;if(o.reachability.status==="unreachable")return s`<span class="mono" title=${o.reachability.detail??void 0} style=${{color:"var(--err-fg)"}}>연결 불가</span>`;if(o.reachability.status==="probe_pending")return s`<span class="dtable-absent">측정 중</span>`}return typeof o.rtt_ms=="number"?s`<span class="mono tnum">${xt(o.rtt_ms)}</span>`:s`<span class="dtable-absent">미보고</span>`}},{id:"sessions",header:"활성 / 최대 세션",numeric:!0,cell:o=>s`
        <span class="mono tnum">
          ${typeof o.active_sessions=="number"?o.active_sessions:"미보고"} / ${typeof o.max_sessions=="number"?o.max_sessions:"없음"}
        </span>
      `},{id:"keepers",header:"연결 Keepers",sortable:!0,sortValue:o=>wt(o)?.length??-1,cell:o=>{const l=wt(o);return l?l.length===0?s`<span class="mono tnum">0</span>`:s`
          <div class="v2-sandbox-keeper-links" title=${l.join(", ")}>
            <span class="mono tnum">${l.length}</span>
            ${l.slice(0,4).map(L=>s`
              <button
                key=${L}
                type="button"
                class="btn-ghost v2-sandbox-keeper-chip"
                title=${`${L} 샌드박스 설정 열기`}
                onClick=${()=>_(L)}
              >
                ${L}
              </button>
            `)}
            ${l.length>4&&s`<span class="mono tnum">+${l.length-4}</span>`}
          </div>
        `:s`<span class="dtable-absent">미보고</span>`}}],[_]),z=Y(()=>[{id:"keeper",header:"Keeper",sortable:!0,sortValue:o=>G(o.keeper)??"",cell:o=>{const l=G(o.keeper);return l?s`<${te} id=${l} size="sm" />`:s`<span class="dtable-absent">없음</span>`}},{id:"binding_state",header:"바인딩 상태",accessor:o=>o.binding_state?.trim()||"unbound"},{id:"remote_endpoint",header:"지정 엔드포인트",accessor:o=>o.remote_endpoint?.trim()||"미지정"},{id:"actions",header:"설정",cell:o=>{const l=G(o.keeper);return l?s`
              <button
                type="button"
                class="btn-ghost v2-sandbox-row-btn"
                onClick=${()=>_(l)}
              >
                키퍼 설정 →
              </button>
            `:s`<span class="dtable-absent">—</span>`}}],[_]),J=Y(()=>[{id:"keeper",header:"Keeper",sortable:!0,sortValue:o=>G(o.keeper)??"",cell:o=>{const l=G(o.keeper);return l?s`<${te} id=${l} size="sm" />`:s`<span class="dtable-absent">없음</span>`}},{id:"container",header:"백엔드 / 컨테이너",cell:o=>s`<span class="mono" style=${{fontSize:"var(--fs-11)"}}>${o.container_id??o.backend??"없음"}</span>`},{id:"image",header:"네트워크 / 이미지",cell:o=>s`<span class="mono" style=${{fontSize:"var(--fs-11)"}}>${o.image??o.network_mode??"없음"}</span>`},{id:"status",header:"상태",accessor:o=>o.status??(o.backend?"declared":null)},{id:"actions",header:"설정",cell:o=>{const l=G(o.keeper);return l?s`
              <button
                type="button"
                class="btn-ghost v2-sandbox-row-btn"
                onClick=${()=>_(l)}
              >
                설정 →
              </button>
            `:s`<span class="dtable-absent">—</span>`}}],[_]),u=a.kind==="value"?a.data:null,B=u?u.unobserved_reasons:[],X=u?u.microvm_guests:[],Z=u?u.ssh_pools:[],m=u?u.docker_keepers:[],A=Y(()=>(u?.ssh_unbound_keepers??[]).filter(o=>an(o)),[u?.ssh_unbound_keepers]),M=u?u.summary.ssh_active_sessions===null?ut():Yt(u.summary.ssh_active_sessions):ut(),x=I??(u?u.shim_parity.status!=="matched":!1);return s`
    <div class="ov" data-testid="infra-sandboxes-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">6 INFRA · SANDBOXES</span>
          <h1>MicroVM · SSH 풀 · Docker · 볼륨 스토리지</h1>
          <p class="ov-sub">
            ${u?`마지막 측정: ${Ns(u.probe_state.measured_at_unix)}`:"V2 스냅샷 대기 중"}
          </p>
        </div>
        <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          ${u&&s`
            <span
              class="mono"
              data-testid="sandbox-probe-state"
              style=${{...qs(u.probe_state.kind),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",fontWeight:600}}
            >
              probe: ${u.probe_state.kind}
            </span>
          `}
          ${i&&s`
            <button
              type="button"
              class="btn-ghost"
              data-testid="sandbox-settings-btn"
              onClick=${()=>e.onNavigate("/settings?section=sandbox")}
            >
              Sandbox & SSH 설정 →
            </button>
            <button type="button" class="btn-primary v2-probe-btn" disabled=${d} onClick=${T}>
              ${d?"프로브 실행 중…":"지금 프로브 실행"}
            </button>
          `}
          <${dn} onRefresh=${()=>p("manual")} />
        </div>
      </header>

      ${$&&s`
        <div role="alert" class="ap-error">
          ${$}
        </div>
      `}

      ${r?a.kind==="loading"?s`<div class="wka-card dtable-absent">샌드박스 인벤토리 불러오는 중…</div>`:a.kind==="failed"?s`
                <div class="ap-error" role="alert">
                  ${a.error.kind==="forbidden"?"관리자(Admin) 권한이 필요한 플리트 샌드박스 뷰입니다 (HTTP 403).":`샌드박스 조회 실패: ${a.error.message}`}
                </div>
              `:a.kind==="absent"||a.kind==="unreported"?s`<div class="wka-card dtable-absent" data-testid="sandboxes-empty-status" role="status">${pt(a)}</div>`:null:s`<div class="wka-card dtable-absent" data-testid="sandboxes-admin-locked" role="status">관리자(Admin) 권한이 필요한 플리트 샌드박스 뷰입니다.</div>`}

      ${u&&s`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-4)",minWidth:0}}>
          ${u.probe_state.kind==="error"&&u.probe_state.error&&s`
            <div class="ap-error" role="alert">프로브 오류: ${u.probe_state.error}</div>
          `}

          <section class="ov-kpis" aria-label="샌드박스 요약 KPI">
            <div class="ov-kpi">
              <div class="ov-kpi-k">MicroVM 실행 / 선언</div>
              <div class="ov-kpi-v ok">${u.summary.microvm_running} / ${u.summary.microvm_declared}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">소켓 경로 존재 / Shim 불일치</div>
              <div class=${`ov-kpi-v ${u.summary.microvm_shim_mismatch>0?"bad":""}`}>
                ${u.summary.microvm_sockets_present} / ${u.summary.microvm_shim_mismatch}
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">SSH 풀 · Keepers / 세션</div>
              <div class="ov-kpi-v tnum">
                ${u.summary.ssh_pools} 풀 · ${u.summary.ssh_keepers}명 (${pt(M)} / ${u.summary.ssh_max_sessions})
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">Docker Keepers</div>
              <div class="ov-kpi-v">${u.summary.docker_keepers}</div>
            </div>
          </section>

          <!-- Shim Parity Disclosure (default-collapsed when matched) -->
          <section class="ap-disclosure" data-testid="sandbox-shim-parity" aria-label="Shim Parity 검증">
            <button
              type="button"
              class="ap-disclosure-trigger"
              data-testid="sandbox-shim-parity-toggle"
              aria-expanded=${x}
              onClick=${()=>h(!x)}
            >
              <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                <span>Shim Parity:</span>
                <span
                  class="mono"
                  style=${{...gt(u.shim_parity.status),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",fontWeight:600}}
                >
                  ${u.shim_parity.status}
                </span>
              </span>
              <span aria-hidden="true">${x?"▾":"▸"}</span>
            </button>
            ${x&&s`
              <div class="ap-disclosure-body" data-testid="sandbox-shim-parity-body">
                <div class="mono" style=${{display:"flex",flexWrap:"wrap",gap:"var(--sp-3)",fontSize:"var(--fs-11)",color:"var(--fg-2)",overflowWrap:"anywhere"}}>
                  <span>build: ${u.shim_parity.build_identity??"없음"}</span>
                  <span>shim: ${u.shim_parity.shim_identity??"없음"}</span>
                  <span>server: ${u.shim_parity.server_identity??"없음"}</span>
                </div>
                ${u.shim_parity.detail&&s`
                  <div style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>${u.shim_parity.detail}</div>
                `}
              </div>
            `}
          </section>

          <!-- Unobserved Reasons (Honesty contract) -->
          ${B.length>0&&s`
            <section class="ap-error sev-warn" data-testid="sandbox-unobserved-reasons">
              <strong>미관측 사유 (<span class="tnum">${B.length}</span>건):</strong>
              <ul style=${{margin:"var(--sp-1) 0 0",paddingLeft:"var(--sp-4)",fontSize:"var(--fs-12)"}}>
                ${B.map((o,l)=>s`
                  <li key=${`${o.scope}-${l}`}>
                    <span class="mono">${o.scope}</span>: ${o.reason}
                  </li>
                `)}
              </ul>
            </section>
          `}

          <!-- MicroVM Guests -->
          <section class="v2-sandbox-section">
            <div class="wka-h">
              <h3>MicroVM 게스트 (<span class="tnum">${X.length}</span>)</h3>
            </div>
            <${ae}
              data=${X}
              columns=${H}
              getRowId=${(o,l)=>o.guest_name??o.id??o.keeper??o.name??`vm-${l}`}
              virtualizeThreshold=${30}
              maxHeight=${320}
              emptyLabel="선언된 MicroVM 게스트 없음"
            />
          </section>

          <!-- SSH Pools -->
          <section class="v2-sandbox-section">
            <div class="wka-h">
              <h3>
                SSH 풀 (<span class="tnum">${Z.length}</span>)${A.length===0&&u.summary.ssh_unbound_keepers>0?s` · 미바인딩 Keeper <span class="tnum">${u.summary.ssh_unbound_keepers}</span>명`:""}
              </h3>
            </div>
            <${ae}
              data=${Z}
              columns=${Q}
              getRowId=${(o,l)=>o.pool_name??o.id??o.name??`ssh-${l}`}
              virtualizeThreshold=${30}
              maxHeight=${300}
              emptyLabel="등록된 SSH 풀 없음"
            />
          </section>

          ${A.length>0&&s`
            <section class="v2-sandbox-section" data-testid="sandbox-ssh-unbound">
              <div class="wka-h">
                <h3>미바인딩 SSH Keepers (<span class="tnum">${A.length}</span>)</h3>
                <span class="v2-sync-pill v2-sync-pill--warn">엔드포인트 연결 필요</span>
              </div>
              <${ae}
                data=${A}
                columns=${z}
                getRowId=${(o,l)=>G(o.keeper)??`unbound-${l}`}
                virtualizeThreshold=${30}
                maxHeight=${240}
                emptyLabel="미바인딩 SSH Keeper 없음"
              />
            </section>
          `}

          <!-- Docker Keepers -->
          <section class="v2-sandbox-section">
            <div class="wka-h">
              <h3>Docker Keepers (<span class="tnum">${m.length}</span>)</h3>
            </div>
            <${ae}
              data=${m}
              columns=${J}
              getRowId=${(o,l)=>o.container_id??o.keeper??`dk-${l}`}
              virtualizeThreshold=${30}
              maxHeight=${280}
              emptyLabel="실행 중인 Docker Keeper 없음"
            />
          </section>

          <!-- Volume GC & Host Storage (default-collapsed JSON with 1-line metric summaries) -->
          <section style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(280px, 1fr))",gap:"var(--sp-3)",minWidth:0}}>
            <div class="ap-disclosure" data-testid="sandbox-volume-gc">
              <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-1)",paddingRight:"var(--sp-2)"}}>
                <button
                  type="button"
                  class="ap-disclosure-trigger"
                  data-testid="sandbox-volume-gc-toggle"
                  aria-expanded=${E}
                  style=${{flex:"1 1 auto",minWidth:0}}
                  onClick=${()=>P(o=>!o)}
                >
                  <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",minWidth:0}}>
                    <span>Volume GC 리포트</span>
                    <span class="mono tnum" style=${{fontSize:"var(--fs-11)",fontWeight:400,color:"var(--fg-3)"}}>
                      ${At(u.volume_gc_report)}
                    </span>
                  </span>
                  <span aria-hidden="true">${E?"▾":"▸"}</span>
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  style=${{padding:"var(--sp-0) var(--sp-2)",fontSize:"var(--fs-11)",flexShrink:0}}
                  onClick=${()=>e.onInspect({title:"Volume GC Report",kind:"volume_gc",data:u.volume_gc_report,render:()=>s`<pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",whiteSpace:"pre-wrap",overflowWrap:"anywhere"}}>${JSON.stringify(u.volume_gc_report,null,2)}</pre>`})}
                >
                  [⤢] 원본
                </button>
              </div>
              ${E&&s`
                <div class="ap-disclosure-body" data-testid="sandbox-volume-gc-body">
                  <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap",overflowWrap:"anywhere",color:"var(--fg-2)"}}>
                    ${u.volume_gc_report?JSON.stringify(u.volume_gc_report,null,2):"없음"}
                  </pre>
                </div>
              `}
            </div>

            <div class="ap-disclosure" data-testid="sandbox-host-storage">
              <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-1)",paddingRight:"var(--sp-2)"}}>
                <button
                  type="button"
                  class="ap-disclosure-trigger"
                  data-testid="sandbox-host-storage-toggle"
                  aria-expanded=${w}
                  style=${{flex:"1 1 auto",minWidth:0}}
                  onClick=${()=>F(o=>!o)}
                >
                  <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",minWidth:0}}>
                    <span>호스트 스토리지</span>
                    <span class="mono tnum" style=${{fontSize:"var(--fs-11)",fontWeight:400,color:"var(--fg-3)"}}>
                      ${At(u.host_storage)}
                    </span>
                  </span>
                  <span aria-hidden="true">${w?"▾":"▸"}</span>
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  style=${{padding:"var(--sp-0) var(--sp-2)",fontSize:"var(--fs-11)",flexShrink:0}}
                  onClick=${()=>e.onInspect({title:"Host Storage",kind:"host_storage",data:u.host_storage,render:()=>s`<pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",whiteSpace:"pre-wrap",overflowWrap:"anywhere"}}>${JSON.stringify(u.host_storage,null,2)}</pre>`})}
                >
                  [⤢] 원본
                </button>
              </div>
              ${w&&s`
                <div class="ap-disclosure-body" data-testid="sandbox-host-storage-body">
                  <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap",overflowWrap:"anywhere",color:"var(--fg-2)"}}>
                    ${u.host_storage?JSON.stringify(u.host_storage,null,2):"없음"}
                  </pre>
                </div>
              `}
            </div>
          </section>
        </div>
      `}
    </div>
  `}function gr(e){switch(Ps(e.subroute)){case"sandboxes":return s`<${Xs} ...${e} />`;case"repos":return s`<${Bs} ...${e} />`;case"logs":return s`<${bn} ...${e} />`}}export{vr as INFRA_TABS,gr as InfraWorkspace,gr as default,Ps as normalizeInfraSubroute};
