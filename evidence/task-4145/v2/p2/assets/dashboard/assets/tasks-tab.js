import{d as k,T as ee,y as T,A as ws,q as ms,m as t}from"./vendor.js";import{M as Oe}from"./markdown-renderer.js";import{s as Xs,J as Ys,z as h,A as te,K as Zs,C as et,B as g,D as st,L as tt,M as at,N as $s,a as D,O as we,P as nt,o as j,Q as se}from"./index.js";import{I as Be}from"./inline-spinner.js";import{d as lt}from"./verification-coverage.js";import{K as me}from"./core.js";import{M as it}from"./master-detail.js";import{R as ot}from"./refresh-button.js";import{V as fs}from"./virtual-list.js";import{i as f,c as rt,f as ct,a as Ve,b as bs,d as y,e as z,g as je,h as hs,j as gs,r as ys,t as _s,k as dt,l as ut}from"./types.js";import"./markdown.js";import"./type-guards.js";import"./table.js";import"./useSelector.js";import"./keeper-state.js";import"./format-string.js";const xs="work:tasks:planning",As="work:tasks:execution",Rs=["task","tasks","task_updated","planning","backlog","verification","verification_requests","goal_projection_changed"],Cs=["schedules","schedule_store_changed","scheduled_automation_changed","scheduled_automation"];function Ds(n){if(!f(n)||!Array.isArray(n.tasks))throw new Error("태스크 목록 응답 형식이 잘못되었습니다.");const a=[];for(const c of n.tasks){const i=ut(c);i&&a.push(i)}return a}function kt(n){if(!f(n)||!Array.isArray(n.goals)&&!Array.isArray(n.tasks)){const i=f(n)&&n.ok===!1?y(n.reason):null;throw new Error(i??"계획 목록 응답 형식이 잘못되었습니다.")}const a=Array.isArray(n.tasks)?Ds(n):[],c=[];if(Array.isArray(n.goals))for(const i of n.goals){const o=dt(i);o.ok&&c.push(o.value)}return{tasks:a,goals:c}}function pt(n){const a=Ds(n),c=f(n)&&f(n.task_counts)?n.task_counts:null,i=f(n)&&f(n.projection_diagnostics)?n.projection_diagnostics:null,o=je(c?.total),v=je(c?.shown),p=o!==null&&v!==null?Math.max(0,o-v):0;return{tasks:a,omitted:p,retained:i?.cache_state==="stale"}}function G(n){const a={ttlMs:1e4,topics:Rs,reason:n};return Promise.all([h.fetch(xs,c=>te("/api/v1/dashboard/planning",{signal:c,decode:kt}),a),h.fetch(As,c=>te("/api/v1/dashboard/execution?light=true",{signal:c,decode:pt}),a)])}function Me(n,a){switch(a.kind){case"loading":case"value":return null;case"absent":case"unreported":case"failed":{const c=a.kind==="failed"?a.error.message:a.reason;return t`
        <div class="wk-notice wk-notice--warn wk-inset" role="alert">
          ${n} 조회 불가${c?` · ${c}`:""}
        </div>
      `}}}function Ts(n){const a=[],c=[];for(const p of n)p.observation.kind==="loading"?a.push(p.label):p.observation.kind==="value"&&(p.observation.stale||p.retained)&&c.push(p.label);const i=[];if(a.length>0&&i.push(`${a.join(", ")} 불러오는 중…`),c.length>0&&i.push(`${c.join(", ")} · 마지막 조회 결과`),i.length===0)return null;const o=i.join(" · "),v=c.length>0?"warn":"info";return t`
    <span class=${`wk-status-pill wk-status-pill--${v}`} role="status" title=${o}>
      ${a.length>0&&t`<${Be} />`}
      <span class="wk-status-pill-text">${o}</span>
    </span>
  `}function vt(n,a){if(!f(n)||!Array.isArray(n.requests))throw new Error("응답에 검증 이력이 없습니다");const c=[];for(const i of n.requests){if(!f(i))continue;const o=y(i.request_id),v=y(i.task_id);if(!o||v!==a)continue;const p=f(i.review_observation)?i.review_observation:null;c.push({requestId:o,taskId:v,taskTitle:z(i.task_title,v),submittedBy:z(i.submitted_by,"unknown"),createdAt:typeof i.created_at=="string"||typeof i.created_at=="number"?i.created_at:null,completionContract:hs(i.completion_contract),submittedEvidence:hs(i.submitted_evidence),reviewState:p?y(p.state):null,reviewDetail:p?y(p.detail):null})}return{rows:c,coverage:lt(n),malformedRows:n.requests.length-c.length}}function wt(n){switch(n){case"approved":return"ok";case"rejected":case"failed":case"commit_failed":case"execution_repair_required":return"err";case"running":case"execution_pending":return"info";case"unavailable":case"not_reviewed":case"cancelled":return"warn";default:return"idle"}}function Is(n,a){const c=y(n);if(c)return c;if(typeof a=="number"&&Number.isFinite(a)&&a>0)try{return new Date(a*1e3).toISOString()}catch{return null}return y(a)}function mt(n){if(!f(n))return{state:"unavailable",reason:"예약 자동화 응답 형식이 잘못되었습니다."};const a=y(n.schedule_store_read_error);if(a)return{state:"unavailable",reason:a};if(n.schedule_store_known===!1||n.status==="unknown")return{state:"unavailable",reason:"예약 저장소 상태를 확인할 수 없습니다."};if(!Array.isArray(n.requests))return{state:"unavailable",reason:"예약 자동화 응답 형식이 잘못되었습니다."};const c=[];for(const o of n.requests){if(!f(o))continue;const v=y(o.schedule_id);if(!v)continue;const p=f(o.last_wake)?o.last_wake:null,K=f(o.payload)&&o.payload.kind==="masc.keeper_wake"&&f(o.payload.body)?o.payload.body:null;c.push({scheduleId:v,scheduleInstanceId:z(o.schedule_instance_id,v),status:z(o.status,"scheduled"),source:z(o.source,"operator"),dueAt:Is(o.due_at_iso,o.due_at),nextDueAt:Is(o.next_due_at_iso,o.next_due_at),recurrenceKind:z(o.recurrence_kind,"one_shot"),recurrenceSummary:z(o.recurrence_summary,""),keeperName:y(o.payload_keeper_name)??y(o.payload_target),summary:y(o.payload_summary),message:typeof K?.message=="string"&&K.message.trim()?K.message:null,lastWakeStatus:p?y(p.status):null,lastWakeError:p?y(p.error):null})}const i=je(n.request_count)??c.length;return{state:"available",rows:c,totalCount:i,truncated:n.truncated===!0}}function Ss(n){switch(n){case"Todo":return"idle";case"Claimed":return"info";case"InProgress":return"info";case"AwaitingVerification":return"warn";case"Done":return"ok";case"Cancelled":return"err"}}function Kt(n){const a=Xs.value,c=Ys.value.query.view,[i,o]=k(()=>c==="schedules"?"schedules":"all"),[v,p]=k(!0),K=`work:schedules:active-only-${v}`,L=h.observe(xs).value,R=h.observe(As).value,P=h.observe(K).value,ae=L.kind==="value"?L.data:null,q=R.kind==="value"?R.data:null,m=P.kind==="value"?P.data:null,x=ee(()=>{const e=new Map;for(const s of ae?.tasks??[])e.set(s.id,s);for(const s of q?.tasks??[])e.set(s.id,s);return[...e.values()]},[ae,q]),H=L.kind==="value"&&!L.stale&&R.kind==="value"&&!R.stale&&!R.data.retained,W=P.kind==="value"&&!P.stale&&m?.state==="available";T(()=>{c==="schedules"&&o("schedules")},[c]);const[$e,Gs]=k(""),[ne,fe]=k(n.entityId??null),[be,he]=k(null);T(()=>{fe(n.entityId??null)},[n.entityId,a]),T(()=>{he(null)},[a]);const[ze,ge]=k(!1),[He,We]=k(""),[Ue,Fe]=k(""),[Je,Ks]=k(2),[ye,Qe]=k(""),[Xe,_e]=k(!1),[le,Ls]=k(""),[Ce,Ye]=k(""),[Ze,Ps]=k(300),[ie,qs]=k("one_shot"),[es,Ns]=k(3600),[Te,Ie]=k(""),[Se,xe]=k(""),[_,$]=k(null),[U,u]=k(null);T(()=>{$(null),u(null)},[a]);const[Ae,Re]=k(null),[Es,Os]=k(0),[oe,ss]=k([]),[ts,De]=k(null),[re,as]=k(!1),[Q,Ge]=k(null),[ns,ls]=k(!1),[is,Vs]=k(null),Ke=ws(null),X=ms(e=>h.fetch(K,s=>te(`/api/v1/dashboard/scheduled-automation?active_only=${v}`,{signal:s,decode:mt}),{ttlMs:1e4,topics:Cs,reason:e}),[K,v]),ce=ws(X);ce.current=X,T(()=>{G("mount")},[a]),T(()=>{X("mount")},[X,a]),T(()=>{(i==="schedules"?W:H)&&Zs()},[i,L,R,P,H,W]),T(()=>{fe(e=>e&&(!H||x.some(s=>s.id===e))?e:x[0]?.id??null)},[x,H,n.entityId,a]),T(()=>{m?.state==="available"&&he(e=>e&&(!W||m.rows.some(s=>s.scheduleId===e))?e:m.rows[0]?.scheduleId??null)},[m,W,a]),T(()=>{let e=null,s=!1,r=!1,d=!1;const b=(A,B,Z)=>{s||=A,r||=B,d||=Z,!e&&(e=setTimeout(()=>{e=null,g(a)&&(s&&G("sse"),r&&ce.current("sse"),d&&Os(Ne=>Ne+1),s=!1,r=!1,d=!1)},450))},M=et(A=>{if(!g(a))return;const B=st(A),Z=f(A.data)?A.data:null,Ne=f(Z?.payload)?Z.payload:Z,ks=B.includes("execution_snapshot")&&Ne?.execution_invalidated===!0;ks&&h.invalidateTopic("tasks");const ps=ks||B.some(Ee=>Rs.includes(Ee)),vs=B.some(Ee=>Cs.includes(Ee));!ps&&!vs||b(ps,vs,B.includes("verification")||B.includes("verification_requests"))}),S=()=>{g(a)&&(h.invalidateTopic("tasks"),h.invalidateTopic("schedules"))},ve=tt(A=>{S(),A==="observer_resync_required"&&b(!0,!0,!0)}),qe=at(()=>b(!0,!0,!0));let us=$s.peek();const Qs=$s.subscribe(A=>{A&&!us&&(S(),b(!0,!0,!0)),us=A});return()=>{M(),ve(),qe(),Qs(),e&&clearTimeout(e)}},[a]);const N=ee(()=>rt(x),[x]),Ms=ee(()=>{const e=ct(x,i),s=$e.trim().toLowerCase();return s?e.filter(r=>r.title.toLowerCase().includes(s)||r.id.toLowerCase().includes(s)||(r.assignee?.toLowerCase().includes(s)??!1)||(r.goalId?.toLowerCase().includes(s)??!1)):e},[x,i,$e]),l=ee(()=>x.find(e=>e.id===ne)??(ne===null?x[0]??null:null),[x,ne]),w=ee(()=>m?.state==="available"?m.rows.find(e=>e.scheduleId===be)??m.rows[0]??null:null,[m,be]),de=ms(async(e,s,r)=>{Ke.current?.abort();const d=new AbortController;Ke.current=d;const b=d.signal;Vs({epoch:a,taskId:e}),r||(ss([]),De(null)),as(!0),Ge(null),ls(!1);const M=new URLSearchParams({task_id:e,limit:"20"});s&&M.set("cursor",s);const S=await te(`/api/v1/dashboard/tasks/history/page?${M.toString()}`,{signal:b});if(b.aborted||!g(a))return;if(as(!1),!S.ok){if(S.error.kind==="conflict_cas"||S.error.status===409||S.error.code==="task_history_source_changed"){ls(!0),De(null),Ge("이력 원장이 변경되어 현재 커서가 만료되었습니다 (409 task_history_source_changed). 처음부터 다시 불러오세요.");return}Ge(S.error.message);return}const ve=Array.isArray(S.value.events)?S.value.events:[];ss(qe=>r?[...qe,...ve]:ve),De(S.value.next_cursor??null)},[a]),os=D.value,C=os.kind==="single_user_local",ue=C&&!we("admin",os),E=i==="schedules",I=l?.id??null,Y=is?.epoch===a&&is.taskId===I,O=Ae?.taskId===I&&Ae.epoch===a?Ae:null,F=O?.report??null,ke=F?.rows??[],V=[];if(F){const{coverage:e,malformedRows:s}=F;e.unreadableTotal!==null&&e.unreadableTotal>0&&V.push(`전체 검증 저장소에서 ${e.unreadableTotal}건 읽기 불가`),s>0&&V.push(`응답에서 ${s}건 표시 불가`),e.truncated&&V.push(e.total===null?"검증 이력 일부만 표시":`검증 이력 ${e.total}건 중 ${ke.length}건 표시`)}T(()=>{xe(""),Ie("")},[I,w?.scheduleId,i]),T(()=>{if(!(E||!I))return de(I,null,!1),()=>Ke.current?.abort()},[E,I,de]),T(()=>{if(E||!I||!C)return;const e=new AbortController,s={taskId:I,epoch:a},r=d=>d?.taskId===s.taskId&&d.epoch===s.epoch?d.report:null;return Re(d=>({...s,kind:"loading",report:r(d)})),te(`/api/v1/verification/requests?view=all&task_id=${encodeURIComponent(I)}&limit=10`,{signal:e.signal,decode:d=>vt(d,I)}).then(d=>{e.signal.aborted||!g(a)||(d.ok?Re({...s,kind:"ready",report:d.value}):d.error.kind!=="aborted"&&d.error.kind!=="epoch_stale"&&Re(b=>({...s,kind:"failed",report:r(b),message:d.error.message})))}),()=>{e.abort()}},[E,I,Es,C,a]);const rs=async e=>{if(e.preventDefault(),D.peek().kind!=="single_user_local")return;const s=He.trim();if(!s){u({kind:"err",message:"태스크 제목을 입력하세요."});return}$("create-task"),u(null);const r={title:s,description:Ue.trim(),priority:Je};ye.trim()&&(r.goal_id=ye.trim());const d=await gs("masc_add_task",r);if(g(a)){if($(null),!d.ok){u({kind:"err",message:`태스크 생성 실패: ${d.error.message}`});return}We(""),Fe(""),Qe(""),ge(!1),u(null),j(`태스크 "${s}" 생성 완료`,"success"),h.invalidateTopic("tasks"),await G("manual")}},pe=async(e,s)=>{if(D.peek().kind!=="single_user_local")return;$(s),u(null);const r=await gs("masc_transition",{task_id:e.id,action:s});if(g(a)){if($(null),!r.ok){u({kind:"err",message:`전환 실패 (${s}): ${r.error.message}`});return}u(null),j(`${e.id} → ${s} 적용됨`,"success"),h.invalidateTopic("tasks"),await G("manual")}},Bs=async e=>{const s=D.peek();if(s.kind!=="single_user_local"||we("admin",s))return;const r=bs(e);if(!r.ok){u({kind:"warn",message:r.error==="Already_assigned"?"이미 Goal에 연결된 태스크는 재할당하거나 해제할 수 없습니다 (Already_assigned).":"완료 또는 취소된 태스크에는 Goal을 연결할 수 없습니다."});return}const d=Te.trim();if(!d){u({kind:"err",message:"연결할 Goal을 선택하세요."});return}$("link-goal"),u(null);const b=await ys();if(!g(a))return;if(!b.ok){$(null),u({kind:"err",message:b.error.message});return}const M=await se("POST",`/api/v1/tasks/${encodeURIComponent(e.id)}/link-goal`,{goal_id:d,expected_workspace:_s(b.value)});if(g(a)){if($(null),!M.ok){u({kind:"err",message:`Goal 연결 실패: ${M.error.message}`});return}Ie(""),u(null),j(`${e.id} → Goal ${d} 연결 완료`,"success"),h.invalidateTopic("tasks"),await G("manual")}},js=async e=>{const s=D.peek();if(s.kind!=="single_user_local"||we("admin",s))return;$("cancel"),u(null);const r=await ys();if(!g(a))return;if(!r.ok){$(null),u({kind:"err",message:r.error.message});return}const d={task_id:e.id,expected_workspace:_s(r.value)};Se.trim()&&(d.reason=Se.trim());const b=await se("POST","/api/v1/dashboard/tasks/cancel",d);if(g(a)){if($(null),!b.ok){u({kind:"err",message:`태스크 취소 실패: ${b.error.message}`});return}xe(""),u(null),j(`태스크 ${e.id} 취소 완료`,"success"),h.invalidateTopic("tasks"),await G("manual")}},cs=async e=>{const s=D.peek();if(s.kind!=="single_user_local"||we("admin",s))return;$("delete"),u(null);const r=await se("POST","/api/v1/dashboard/tasks/delete",{task_id:e.id});if(g(a)){if($(null),!r.ok){u({kind:"err",message:`태스크 삭제 실패: ${r.error.message}`});return}u(null),j(`태스크 ${e.id} 삭제 완료`,"success"),h.invalidateTopic("tasks"),await G("manual")}},ds=async e=>{if(e.preventDefault(),D.peek().kind!=="single_user_local")return;if(!le.trim()||!Ce.trim()){u({kind:"err",message:"대상 Keeper와 예약 메시지를 입력하세요."});return}$("create-schedule"),u(null);const s={keeper_name:le.trim(),message:Ce.trim(),due_in_sec:Math.max(10,Math.trunc(Ze)),recurrence_kind:ie};ie==="interval"&&(s.recurrence_interval_sec=Math.max(60,Math.trunc(es)));const r=await se("POST","/api/v1/tools/masc_schedule_create",s);if(g(a)){if($(null),!r.ok){u({kind:"err",message:`예약 생성 실패: ${r.error.message}`});return}Ye(""),_e(!1),u(null),j(`${le.trim()} 예약 자동화 등록 완료`,"success"),h.invalidateTopic("schedules"),await ce.current("manual")}},zs=async e=>{if(D.peek().kind!=="single_user_local")return;$(`cancel-sched:${e}`),u(null);const s=await se("POST","/api/v1/tools/masc_schedule_cancel",{schedule_id:e,reason:"operator cancelled from dashboard"});if(g(a)){if($(null),!s.ok){u({kind:"err",message:`예약 취소 실패: ${s.error.message}`});return}u(null),j(`예약 ${e} 취소됨`,"success"),h.invalidateTopic("schedules"),await ce.current("manual")}},J=e=>H?String(e):"—",Hs=W&&m?.state==="available"?String(m.totalCount):"—",Le=[{id:"all",label:"All",count:J(N.all)},{id:"active",label:"Active",count:J(N.active)},{id:"awaiting_verify",label:"AwaitingVerify",count:J(N.awaiting_verify)},{id:"todo",label:"Todo",count:J(N.todo)},{id:"unlinked",label:"Unlinked",count:J(N.unlinked)},{id:"done",label:"Done",count:J(N.done+N.cancelled)},{id:"schedules",label:"Schedules",count:Hs}],Ws=Ts(E?[{label:"예약 목록",observation:P}]:[{label:"계획 목록",observation:L},{label:"실행 태스크",observation:R,retained:q?.retained}]),Pe=Le.find(e=>e.id===i)??Le[0],Us=Pe.id==="all"?"전체":Pe.label,Fs=t`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">
          ${i==="schedules"?"Scheduled Automation":"Tasks"}
        </h2>
        <div class="wk-pane-status-slot" data-testid="tasks-sync-slot">
          ${Ws}
        </div>
        <div class="wk-actions">
          ${C&&(i==="schedules"?t`<button type="button" class="btn-primary" onClick=${()=>_e(e=>!e)}>${Xe?"닫기":"+ 새 예약"}</button>`:t`<button type="button" class="btn-primary" onClick=${()=>ge(e=>!e)}>${ze?"닫기":"+ 새 태스크"}</button>`)}
          <${ot} onRefresh=${()=>E?X("manual"):G("manual")} />
        </div>
      </div>

      <div class="wk-filter-bar">
        <div class="wk-filter-row">
          <${nt}
            triggerLabel=${`상태: ${Us} (${Pe.count}) ▾`}
            triggerClassName="btn-ghost"
            triggerTestId="tasks-status-filter"
            popoverTestId="tasks-status-filter-menu"
            ariaLabel="태스크 상태 필터"
            items=${Le.map(e=>({id:e.id,testId:`tasks-filter-${e.id}`,label:`${e.id==="all"?"전체":e.label} (${e.count})`,active:i===e.id,separatorBefore:e.id==="schedules",onSelect:()=>o(e.id)}))}
          />
          ${i==="schedules"?t`
                <div class="wk-chips" role="group" aria-label="예약 범위 필터">
                  <button
                    type="button"
                    class="wk-chip"
                    aria-pressed=${v}
                    onClick=${()=>p(!0)}
                  >
                    활성만
                  </button>
                  <button
                    type="button"
                    class="wk-chip"
                    aria-pressed=${!v}
                    onClick=${()=>p(!1)}
                  >
                    전체 이력
                  </button>
                </div>
              `:t`
                <input
                  type="search"
                  class="wk-input wk-filter-search"
                  placeholder="태스크 제목, ID, 담당 Keeper, Goal ID 검색…"
                  value=${$e}
                  onInput=${e=>Gs(e.target.value)}
                  aria-label="태스크 검색"
                />
              `}
        </div>
      </div>

      ${C&&ze&&i!=="schedules"&&t`
        <form class="wk-form wk-inset" onSubmit=${rs}>
          <div class="wk-section-title">새 태스크 추가 (masc_add_task)</div>
          <div class="wk-field">
            <label for="new-task-title">제목</label>
            <input id="new-task-title" class="wk-input" required value=${He} onInput=${e=>We(e.target.value)} />
          </div>
          <div class="wk-field">
            <label for="new-task-desc">설명</label>
            <textarea
              id="new-task-desc"
              class="wk-textarea"
              value=${Ue}
              onInput=${e=>Fe(e.target.value)}
              onKeyDown=${e=>{e.isComposing||e.keyCode===229||(e.metaKey||e.ctrlKey)&&e.key==="Enter"&&_===null&&(e.preventDefault(),rs(e))}}
            />
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="new-task-pri">우선순위</label>
              <input id="new-task-pri" type="number" min="1" max="5" class="wk-input tnum" value=${Je} onInput=${e=>Ks(Number(e.target.value))} />
            </div>
            <div class="wk-field">
              <label for="new-task-goal">연결 Goal (선택 — 미지정 시 독립 태스크)</label>
              <select id="new-task-goal" class="wk-select" value=${ye} onChange=${e=>Qe(e.target.value)}>
                <option value="">(없음 — 독립 태스크)</option>
                ${ae?.goals.map(e=>t`<option key=${e.id} value=${e.id}>${e.title} (${e.phase})</option>`)}
              </select>
            </div>
          </div>
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${_!==null}>생성</button>
            <button type="button" class="btn-ghost" onClick=${()=>ge(!1)}>취소</button>
          </div>
        </form>
      `}

      ${C&&Xe&&i==="schedules"&&t`
        <form class="wk-form wk-inset" onSubmit=${ds}>
          <div class="wk-section-title">예약 자동화 생성 (POST /api/v1/tools/masc_schedule_create)</div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="sched-keeper">대상 Keeper</label>
              <input id="sched-keeper" class="wk-input" required value=${le} onInput=${e=>Ls(e.target.value)} placeholder="예: e-masc-the-leader" />
            </div>
            <div class="wk-field">
              <label for="sched-due">최초 실행 지연 (초)</label>
              <input id="sched-due" type="number" min="10" class="wk-input tnum" value=${Ze} onInput=${e=>Ps(Number(e.target.value))} />
            </div>
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="sched-repeat">반복 방식</label>
              <select id="sched-repeat" class="wk-select" value=${ie} onChange=${e=>qs(e.target.value)}>
                <option value="one_shot">1회 실행 (one_shot)</option>
                <option value="interval">주기 반복 (interval)</option>
              </select>
            </div>
            ${ie==="interval"&&t`
              <div class="wk-field">
                <label for="sched-interval">반복 간격 (초)</label>
                <input id="sched-interval" type="number" min="60" class="wk-input tnum" value=${es} onInput=${e=>Ns(Number(e.target.value))} />
              </div>
            `}
          </div>
          <div class="wk-field">
            <label for="sched-msg">메시지</label>
            <textarea
              id="sched-msg"
              class="wk-textarea"
              required
              value=${Ce}
              onInput=${e=>Ye(e.target.value)}
              onKeyDown=${e=>{e.isComposing||e.keyCode===229||(e.metaKey||e.ctrlKey)&&e.key==="Enter"&&_===null&&(e.preventDefault(),ds(e))}}
            />
          </div>
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${_!==null}>예약 등록</button>
            <button type="button" class="btn-ghost" onClick=${()=>_e(!1)}>취소</button>
          </div>
        </form>
      `}

      ${E?t`
            ${Me("예약 목록",P)}
            ${m?.state==="unavailable"&&t`
              <div class="wk-notice wk-notice--warn wk-inset" role="alert">예약 저장소 조회 불가 · ${m.reason}</div>
            `}
            ${m?.state==="available"&&t`
              ${m.truncated&&t`
                <div class="wk-notice wk-notice--warn wk-inset" role="note">
                  예약 목록이 표시 제한으로 일부만 표시됩니다 (${m.rows.length} / ${m.totalCount}건).
                </div>
              `}
              <${fs}
                items=${m.rows}
                estimateSize=${74}
                height="100%"
                ariaLabel="예약 자동화 목록"
                getItemKey=${e=>e.scheduleId}
                empty=${W?t`<div class="wk-detail-pad"><span class="dtable-absent">${v?"활성 예약이 없습니다 (0).":"기록된 예약 이력이 없습니다 (0)."}</span></div>`:null}
                renderItem=${e=>t`
                  <button
                    type="button"
                    class="wk-row-btn"
                    data-selected=${w?.scheduleId===e.scheduleId?"true":"false"}
                    onClick=${()=>he(e.scheduleId)}
                  >
                    <div class="wk-row-top">
                      <span class="wk-row-title">${e.summary??e.scheduleId}</span>
                      <span class="wk-badge wk-badge--info">${e.status}</span>
                    </div>
                    <div class="wk-row-meta">
                      ${e.keeperName&&t`<${me} id=${e.keeperName} size="sm" />`}
                      <span>${e.recurrenceSummary||e.recurrenceKind}</span>
                      <span>다음 실행: ${Ve(e.nextDueAt??e.dueAt)}</span>
                    </div>
                  </button>
                `}
              />
            `}
          `:t`
            ${Me("계획 목록",L)}
            ${Me("실행 태스크",R)}
            ${q!==null&&q.omitted>0&&t`
              <div class="wk-notice wk-inset" role="note">
                종료된 실행 태스크 ${q.omitted}건이 현재 목록의 표시 범위 밖에 있습니다.
              </div>
            `}
              <${fs}
                items=${Ms}
                estimateSize=${76}
                height="100%"
                ariaLabel="태스크 목록"
                getItemKey=${e=>e.id}
                empty=${H?t`<div class="wk-detail-pad"><span class="dtable-absent">${(q?.omitted??0)>0?"표시 범위에 해당하는 태스크가 없습니다.":"조건에 맞는 태스크가 없습니다."}</span></div>`:null}
                renderItem=${e=>t`
                  <button
                    type="button"
                    class="wk-row-btn"
                    data-selected=${l?.id===e.id?"true":"false"}
                    onClick=${()=>fe(e.id)}
                  >
                    <div class="wk-row-top">
                      <span class="wk-row-title">${e.title}</span>
                      <span class=${`wk-badge wk-badge--${Ss(e.status)}`}>${e.status}</span>
                    </div>
                    <div class="wk-row-meta">
                      <span class="mono">${e.id}</span>
                      <span class="mono">P${e.priority}</span>
                      ${e.assignee?t`<${me} id=${e.assignee} size="sm" />`:t`<span>미배정</span>`}
                      ${e.goalId?t`<span class="mono">Goal: ${e.goalId}</span>`:t`<span class="wk-badge wk-badge--idle">Unlinked</span>`}
                    </div>
                  </button>
                `}
              />
            `}
    </div>
  `,Js=i==="schedules"?w?t`
          <div class="wk-detail-pad">
            ${U&&t`<div class=${`wk-notice wk-notice--${U.kind}`} role="alert">${U.message}</div>`}
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <div class="mono wk-sub-id">${w.scheduleId}</div>
                <h2 class="wk-heading">${w.summary??"예약 자동화"}</h2>
              </div>
              <span class="wk-badge wk-badge--info">${w.status}</span>
            </div>
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">대상 Keeper</span>
                <span class="wk-kv-v">${w.keeperName?t`<${me} id=${w.keeperName} size="sm" />`:"없음"}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">반복 주기</span>
                <span class="wk-kv-v">${w.recurrenceSummary||w.recurrenceKind}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">예정 시각</span>
                <span class="wk-kv-v tnum">${w.nextDueAt??w.dueAt??"없음"}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">최근 실행 결과</span>
                <span class="wk-kv-v">${w.lastWakeStatus??"실행 이력 없음"}</span>
              </div>
            </div>
            ${w.message&&t`<${Oe} class="wk-prose" text=${w.message} />`}
            ${w.lastWakeError&&t`
              <div class="wk-notice wk-notice--err">최근 실패 사유: ${w.lastWakeError}</div>
            `}
            ${C?t`
                  <div class="wk-actions">
                    <button
                      type="button"
                      class="wk-btn-danger"
                      disabled=${_!==null}
                      onClick=${()=>{zs(w.scheduleId)}}
                    >
                      예약 취소
                    </button>
                  </div>
                `:t`<div class="wk-notice wk-notice--info" data-testid="schedule-mode-notice" role="status">예약 자동화 생성·취소는 싱글유저 로컬 세션 전용입니다.</div>`}
          </div>
        `:null:l?(()=>{const e=bs(l);return t`
            <div class="wk-detail-pad">
              ${U&&t`<div class=${`wk-notice wk-notice--${U.kind}`} role="alert">${U.message}</div>`}
              <div class="wk-section-head">
                <div class="wk-min-w-0">
                  <div class="mono wk-sub-id">${l.id}</div>
                  <h2 class="wk-heading">${l.title}</h2>
                </div>
                <span class=${`wk-badge wk-badge--${Ss(l.status)}`}>${l.status}</span>
              </div>

              <div class="wk-kv-grid">
                <div class="wk-kv">
                  <span class="wk-kv-k">담당자</span>
                  <span class="wk-kv-v">${l.assignee?t`<${me} id=${l.assignee} size="sm" />`:"없음"}</span>
                </div>
                <div class="wk-kv">
                  <span class="wk-kv-k">연결 Goal</span>
                  <span class="wk-kv-v">
                    ${l.goalId?t`
                          <button
                            type="button"
                            class="btn-ghost wk-btn-compact"
                            onClick=${()=>n.onNavigate(`/work/goals/${encodeURIComponent(l.goalId)}`)}
                          >
                            ${l.goalId} →
                          </button>
                        `:"없음 (독립 태스크)"}
                  </span>
                </div>
                <div class="wk-kv">
                  <span class="wk-kv-k">우선순위</span>
                  <span class="wk-kv-v tnum">P${l.priority}</span>
                </div>
                <div class="wk-kv">
                  <span class="wk-kv-k">검증 ID</span>
                  <span class="wk-kv-v mono">${l.verificationId??"없음"}</span>
                </div>
              </div>

              ${l.description&&t`
                <section class="wk-section">
                  <h3 class="wk-section-title">설명</h3>
                  <${Oe} class="wk-prose" text=${l.description} />
                </section>
              `}

              ${l.handoff.kind==="unreadable"&&t`
                <div class="wk-notice wk-notice--warn" role="note">이 태스크에 남은 인계 메모를 읽을 수 없습니다. 원본 검사에서 값을 확인하세요.</div>
              `}
              ${l.handoff.kind==="readable"&&t`
                <section class="wk-section" aria-label="인계 메모">
                  <h3 class="wk-section-title">인계 메모 (handoff)</h3>
                  <div class="wk-kv-grid">
                    <div class="wk-kv">
                      <span class="wk-kv-k">넘긴 이유</span>
                      <span class="wk-kv-v">${l.handoff.context.reason??"없음"}</span>
                    </div>
                    <div class="wk-kv">
                      <span class="wk-kv-k">다음 단계</span>
                      <span class="wk-kv-v">${l.handoff.context.next_step??"없음"}</span>
                    </div>
                    <div class="wk-kv">
                      <span class="wk-kv-k">실패 유형</span>
                      <span class="wk-kv-v">${l.handoff.context.failure_mode??"없음"}</span>
                    </div>
                    <div class="wk-kv">
                      <span class="wk-kv-k">남긴 이 / 시각</span>
                      <span class="wk-kv-v">${l.handoff.context.updated_by??"없음"} · ${Ve(l.handoff.context.updated_at)}</span>
                    </div>
                  </div>
                  ${l.handoff.context.summary&&t`<${Oe} class="wk-prose" text=${l.handoff.context.summary} />`}
                  ${(l.handoff.context.evidence_refs?.length??0)>0&&t`
                    <ul class="wk-prose">
                      ${l.handoff.context.evidence_refs?.map(s=>t`<li key=${s} class="mono">${s}</li>`)}
                    </ul>
                  `}
                </section>
              `}

              <section class="wk-section" aria-label="태스크 작업 제어">
                <h3 class="wk-section-title">Lifecycle Actions</h3>
                <div class="wk-actions">
                  ${C&&l.status==="Todo"&&t`
                    <button type="button" class="btn-primary" disabled=${_!==null} onClick=${()=>{pe(l,"claim")}}>
                      Claim (담당 잡기)
                    </button>
                  `}
                  ${C&&l.status==="Claimed"&&t`
                    <button type="button" class="btn-primary" disabled=${_!==null} onClick=${()=>{pe(l,"start")}}>
                      Start (진행 시작)
                    </button>
                    <button type="button" class="btn-ghost" disabled=${_!==null} onClick=${()=>{pe(l,"release")}}>
                      Release (담당 해제)
                    </button>
                  `}
                  ${C&&l.status==="InProgress"&&t`
                    <button type="button" class="btn-ghost" disabled=${_!==null} onClick=${()=>{pe(l,"release")}}>
                      Release
                    </button>
                  `}
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>n.onInspect({title:`Task: ${l.title}`,subtitle:`${l.id} · ${l.status}`,kind:"task",data:l})}
                  >
                    원본 검사
                  </button>
                </div>

                ${ue&&l.status!=="Done"&&l.status!=="Cancelled"&&t`
                  <div class="wk-row-wrap wk-mt-2">
                    <input
                      type="text"
                      class="wk-input wk-flex-input"
                      placeholder="취소 사유 (선택)"
                      value=${Se}
                      onInput=${s=>xe(s.target.value)}
                      aria-label="태스크 취소 사유"
                    />
                    <button type="button" class="wk-btn-warn" disabled=${_!==null} onClick=${()=>{js(l)}}>
                      Cancel Task
                    </button>
                    <button type="button" class="wk-btn-danger" disabled=${_!==null} onClick=${()=>{cs(l)}}>
                      Delete Task
                    </button>
                  </div>
                `}
                ${ue&&(l.status==="Done"||l.status==="Cancelled")&&t`
                  <div class="wk-actions wk-mt-1">
                    <button type="button" class="wk-btn-danger" disabled=${_!==null} onClick=${()=>{cs(l)}}>
                      Delete Task
                    </button>
                  </div>
                `}
                ${!ue&&t`
                  <div class="wk-muted-sm wk-mt-1" data-testid="task-admin-locked">
                    ${C?"태스크 취소·삭제 및 Goal 연결은 관리자 전용입니다.":"태스크 생성·전환·취소·삭제는 싱글유저 로컬 세션 전용입니다."}
                  </div>
                `}
              </section>

              ${C&&t`
                <section class="wk-section" aria-label="태스크 검증 판정">
                  <div class="wk-section-head">
                    <h3 class="wk-section-title">
                      Verification Verdicts <span class="wk-chip-count">(${O?.kind==="ready"&&V.length===0?ke.length:"—"})</span>
                    </h3>
                    <div class="wk-pane-status-slot">
                      ${(!O||O.kind==="loading")&&t`
                        <span
                          class="wk-status-pill wk-status-pill--info"
                          role="status"
                          title=${F?"검증 이력 갱신 중 · 마지막 조회 표시":"검증 이력을 불러오는 중…"}
                        >
                          <${Be} size="xs" />
                          <span class="wk-status-pill-text">
                            ${F?"갱신 중 · 마지막 조회":"검증 이력 불러오는 중…"}
                          </span>
                        </span>
                      `}
                    </div>
                  </div>
                  ${O?.kind==="failed"&&t`
                    <div class="wk-notice wk-notice--err" role="alert">검증 이력 조회 실패 · ${O.message}${F?" · 마지막 조회 표시":""}</div>
                  `}
                  ${V.length>0&&t`
                    <div class="wk-notice" role="status">${V.join(" · ")}</div>
                  `}
                  ${O?.kind==="ready"&&V.length===0&&ke.length===0&&t`<p class="wk-muted-sm">표시할 검증 이력이 없습니다.</p>`}
                  <div class="wk-stack-1">
                    ${ke.map(s=>t`
                      <div key=${s.requestId} class="wk-kv">
                        <div class="wk-row-top">
                          <span class="mono wk-sub-id" title=${s.requestId}>${s.requestId}</span>
                          <span class=${`wk-badge wk-badge--${wt(s.reviewState)}`}>
                            ${s.reviewState??"unobserved"}
                          </span>
                        </div>
                        <div class="wk-muted-sm">
                          제출: ${s.submittedBy}${s.createdAt?` · ${Ve(s.createdAt)}`:""}
                        </div>
                        ${s.reviewDetail&&t`<div class="wk-body-pre">${s.reviewDetail}</div>`}
                      </div>
                    `)}
                  </div>
                </section>
              `}

              <section class="wk-section" aria-label="Goal 연결">
                <h3 class="wk-section-title">Goal 연결 (set_task_goal — goalless 태스크 전용)</h3>
                ${ue?e.ok?t`
                      <div class="wk-row-wrap">
                        <select
                          class="wk-select wk-flex-input"
                          value=${Te}
                          onChange=${s=>Ie(s.target.value)}
                          aria-label="연결할 Goal 선택"
                        >
                          <option value="">Goal 선택…</option>
                          ${ae?.goals.map(s=>t`<option key=${s.id} value=${s.id}>${s.title} (${s.phase})</option>`)}
                        </select>
                        <button
                          type="button"
                          class="btn-primary"
                          disabled=${_!==null||!Te}
                          onClick=${()=>{Bs(l)}}
                        >
                          Goal 연결
                        </button>
                      </div>
                    `:t`
                      <div class="wk-notice">
                        ${e.error==="Already_assigned"?`이미 Goal(${l.goalId})에 연결되어 있습니다. constitution.xml 규약상 재할당/해제는 허용되지 않습니다 (Already_assigned).`:"종료된 태스크(Done/Cancelled)에는 Goal을 연결할 수 없습니다."}
                      </div>
                    `:t`<div class="wk-notice" data-testid="task-link-goal-admin-locked">${C?"Goal 연결은 관리자 전용입니다.":"Goal 연결은 싱글유저 로컬 관리자 세션 전용입니다."}</div>`}
              </section>

              <details
                class="ap-disclosure"
                data-testid="task-history-disclosure"
                aria-label="태스크 이력 타임라인"
                open=${Y&&!!Q||void 0}
              >
                <summary class="ap-disclosure-trigger">
                  <span>
                    이력 ${Y&&!re?`${oe.length}건`:"…"} · Task History Timeline
                  </span>
                  <span aria-hidden="true">▸</span>
                </summary>
                <div class="ap-disclosure-body">
                  <div class="wk-section-head">
                    <span class="wk-muted-sm">Cursor Paginated raw timeline</span>
                    <button
                      type="button"
                      class="btn-ghost"
                      onClick=${()=>{de(l.id,null,!1)}}
                    >
                      처음부터 다시 읽기
                    </button>
                  </div>
                  ${Y&&ns&&t`
                    <div class="wk-notice wk-notice--warn" role="alert">
                      ${Q}
                    </div>
                  `}
                  ${Y&&!ns&&Q&&t`
                    <div class="wk-notice wk-notice--err" role="alert">${Q}</div>
                  `}
                  ${!Y||re&&oe.length===0?t`<span class="dtable-absent" role="status"><${Be} /> 이력 불러오는 중…</span>`:oe.length===0?Q?null:t`<span class="dtable-absent">기록된 이력이 없습니다.</span>`:t`
                          <ol class="wk-timeline">
                            ${oe.map((s,r)=>t`
                              <li key=${`${s.source}-${s.offset}-${r}`} class="wk-timeline-item">
                                <div class="wk-row-top">
                                  <span class="mono wk-sub-id">
                                    ${s.source} · offset ${s.offset}
                                  </span>
                                </div>
                                <pre class="wk-code-preview">${typeof s.event=="string"?s.event:JSON.stringify(s.event,null,2)}</pre>
                              </li>
                            `)}
                          </ol>
                          ${ts&&t`
                            <button
                              type="button"
                              class="btn-ghost"
                              disabled=${re}
                              onClick=${()=>{de(l.id,ts,!0)}}
                            >
                              ${re?"불러오는 중…":"이전 이력 더 불러오기"}
                            </button>
                          `}
                        `}
                </div>
              </details>
            </div>
          `})():null;return t`
    <${it}
      master=${Fs}
      detail=${Js}
      hasSelection=${i==="schedules"?w!==null:l!==null}
      selectionKey=${i==="schedules"?be:ne}
      linkedKey=${n.entityId??null}
      masterLabel=${i==="schedules"?"예약 목록":"태스크 목록"}
      detailLabel=${i==="schedules"?"예약 상세":"태스크 상세"}
      emptyDetail=${t`<div class="wk-detail-pad"><span class="dtable-absent">항목을 선택하세요.</span></div>`}
    />
  `}export{Kt as TasksTab};
