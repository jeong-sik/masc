import{d,A as V,y as w,q,T as rt,m as e}from"./vendor.js";import{c as ct}from"./copyable-code.js";import{M as F}from"./markdown-renderer.js";import{a as _,s as lt,S as G,Y as dt,z as ut,A as Q,V as ft,B as mt,Z as pt,P as bt,o as Y}from"./index.js";import{K as Z}from"./core.js";import{M as kt}from"./master-detail.js";import{R as vt}from"./refresh-button.js";import{V as $t}from"./virtual-list.js";import{isRecord as k,decodePublishedArtifactItem as J,asNonEmptyString as W,asString as $,asSafeInt as ht,formatBytes as X,formatRelativeTime as gt}from"./index2.js";import"./toast.js";import"./markdown.js";import"./type-guards.js";import"./table.js";import"./useSelector.js";import"./lazy-component.js";import"./attachment-gallery.js";function Bt(c){const D=_.value,tt=lt.value,I=D.kind==="single_user_local",H=G(D),[p,B]=d({artifacts:[],diagnostics:[]}),[at,L]=d(!0),[N,A]=d(null),[b,C]=d("all"),[S,et]=d(""),[f,R]=d(c.entityId??null),[j,U]=d(null),[a,M]=d(null),[T,h]=d(null),nt=f!==null&&a===null&&T===null,E=V(null),g=V(!0);w(()=>(g.current=!0,()=>{g.current=!1,E.current?.abort()}),[]),w(()=>{U(null)},[c.entityId]);const x=q(async(t="mount")=>{const i=_.peek();if(!G(i)){B({artifacts:[],diagnostics:[]}),i.kind!=="single_user_local"&&(R(null),M(null)),L(!1),A(null);return}const l=dt();L(!0),A(null);const r=await ut.fetch("kn:artifacts:list",async s=>{const n=await Q("/api/v1/published-artifacts",{signal:s});if(!n.ok)return n;const y=[],v=[];if(k(n.value)){if(Array.isArray(n.value.artifacts))for(const o of n.value.artifacts){const u=J(o);u&&y.push(u)}if(Array.isArray(n.value.diagnostics))for(const o of n.value.diagnostics){if(!k(o))continue;const u=W(o.id),m=W(o.error);u&&m&&v.push({id:u,error:m})}}return ft({artifacts:y,diagnostics:v})},{ttlMs:15e3,topics:["artifacts"],reason:t});!g.current||!mt(l)||(L(!1),r.kind==="value"?(B(r.data),pt(),R(s=>c.entityId&&r.data.artifacts.some(n=>n.id===c.entityId)?c.entityId:s&&r.data.artifacts.some(n=>n.id===s)?s:r.data.artifacts[0]?.id??null)):r.kind==="failed"&&A(r.error.message))},[c.entityId]);w(()=>{x("mount")},[x,I,H,tt]);const K=q(async(t,i,l)=>{if(_.peek().kind!=="single_user_local")return;h(null);const r=i!==null?`?revision=${i}`:"",s=await Q(`/api/v1/published-artifacts/${encodeURIComponent(t)}${r}`,{signal:l});if(l?.aborted)return;if(!s.ok){h(s.error.message);return}if(!k(s.value)){h("아티팩트 문서 형식이 올바르지 않습니다.");return}const n=J(s.value.artifact);if(!n){h("아티팩트 메타데이터를 해석하지 못했습니다.");return}const y=$(s.value.content,""),v=[];if(Array.isArray(s.value.revisions))for(const o of s.value.revisions){if(!k(o))continue;const u=ht(o.revision);if(u===null)continue;const m=k(o.body)?o.body:null,z=m&&k(m._blob)?m._blob:m;v.push({revision:u,title:$(o.title,n.title),createdAt:$(o.created_at,""),sha256:(z?$(z.sha256,""):"")||$(o.sha256,"")})}l?.aborted||M({artifact:n,content:y,revisions:v})},[]);w(()=>{if(E.current?.abort(),M(null),!f)return;const t=new AbortController;return E.current=t,K(f,j,t.signal),()=>{t.abort()}},[f,j,K]);const O=rt(()=>{const t=S.trim().toLowerCase();return p.artifacts.filter(i=>!(b!=="all"&&i.format!==b||t&&!i.title.toLowerCase().includes(t)&&!i.summary.toLowerCase().includes(t)&&!i.id.toLowerCase().includes(t)))},[p.artifacts,b,S]),P=async(t,i)=>{const l=await ct(t);g.current&&(l?Y(`${i} 복사됨`,"success"):Y("클립보드 복사를 지원하지 않는 환경입니다.","warning"))},st=t=>{if(typeof document>"u"||typeof URL>"u"||typeof URL.createObjectURL!="function")return;const i=t.artifact.format==="html"?"html":"md",l=t.artifact.format==="html"?"text/html;charset=utf-8":"text/markdown;charset=utf-8",r=new Blob([t.content],{type:l}),s=URL.createObjectURL(r),n=document.createElement("a");n.href=s,n.download=`${t.artifact.id}-r${t.artifact.revision}.${i}`,n.click(),URL.revokeObjectURL(s)},it=e`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <h2 class="kn-pane-title">Artifacts <span class="kn-chip-count">(${O.length})</span></h2>
        <${vt} onRefresh=${()=>x("manual")} />
      </div>

      <div class="kn-filter-bar">
        <div class="kn-chips" role="group" aria-label="아티팩트 형식 필터">
          <button type="button" class="kn-chip" aria-pressed=${b==="all"} onClick=${()=>C("all")}>
            All <span class="kn-chip-count">${p.artifacts.length}</span>
          </button>
          <button type="button" class="kn-chip" aria-pressed=${b==="html"} onClick=${()=>C("html")}>
            HTML
          </button>
          <button type="button" class="kn-chip" aria-pressed=${b==="markdown"} onClick=${()=>C("markdown")}>
            Markdown
          </button>
        </div>
        <input
          type="search"
          class="kn-input"
          placeholder="아티팩트 제목, 요약, ID 검색…"
          value=${S}
          onInput=${t=>et(t.target.value)}
          aria-label="아티팩트 검색"
        />
      </div>

      ${!I&&e`
        <div class="kn-notice kn-notice--info kn-inset" data-testid="artifacts-mode-notice" role="status">
          발행된 아티팩트 조회는 싱글유저 로컬 세션에서 지원됩니다.
        </div>
      `}
      ${I&&!H&&e`
        <div class="kn-notice kn-notice--info kn-inset" data-testid="artifacts-admin-locked" role="status">
          아티팩트 목록 조회(<code>/api/v1/published-artifacts</code>)는 토큰 기반 관리자 권한이 필요합니다.
        </div>
      `}
      ${N&&e`<div class="kn-notice kn-notice--err kn-inset" role="alert">${N}</div>`}
      ${p.diagnostics.length>0&&e`
        <div class="kn-notice kn-notice--warn kn-inset">
          읽기 진단 경고 ${p.diagnostics.length}건
        </div>
      `}

      ${at&&p.artifacts.length===0?e`<div class="kn-detail-pad"><span class="dtable-absent">아티팩트 불러오는 중…</span></div>`:e`
            <${$t}
              items=${O}
              estimateSize=${76}
              height="100%"
              ariaLabel="발행된 아티팩트 목록"
              getItemKey=${t=>t.id}
              empty=${e`<div class="kn-detail-pad"><span class="dtable-absent">발행된 HTML/Markdown 아티팩트가 없습니다.</span></div>`}
              renderItem=${t=>e`
                <button
                  type="button"
                  class="kn-row-btn"
                  data-selected=${f===t.id?"true":"false"}
                  onClick=${()=>{R(t.id),U(null)}}
                >
                  <div class="kn-row-top">
                    <span class="kn-row-title">${t.title}</span>
                    <span class=${`kn-badge ${t.format==="html"?"kn-badge--info":"kn-badge--ok"}`}>
                      ${t.format.toUpperCase()}
                    </span>
                  </div>
                  <div class="kn-row-meta">
                    <${Z} id=${t.author} size="sm" />
                    <span class="mono tnum">r${t.revision}</span>
                    <span class="tnum">${X(t.bytes)}</span>
                    <span>${gt(t.createdAt)}</span>
                  </div>
                </button>
              `}
            />
          `}
    </div>
  `,ot=a?e`
        <div class="kn-detail-pad">
          <div class="kn-section-head">
            <div class="kn-min-w-0">
              <div class="kn-row-meta">
                <span class="mono">${a.artifact.id}</span>
                <span class=${`kn-badge ${a.artifact.format==="html"?"kn-badge--info":"kn-badge--ok"}`}>
                  ${a.artifact.format.toUpperCase()}
                </span>
                <span class="mono tnum">rev ${a.artifact.revision}</span>
                <span class="tnum">${X(a.artifact.bytes)}</span>
              </div>
              <h2 class="kn-heading">${a.artifact.title}</h2>
              ${a.artifact.summary&&e`
                <${F} class="kn-subcopy" text=${a.artifact.summary} />
              `}
            </div>
            <div class="kn-actions">
              <button type="button" class="btn-ghost" onClick=${()=>{P(a.content,"본문")}}>본문 복사</button>
              <button type="button" class="btn-primary" onClick=${()=>st(a)}>다운로드</button>
              <${bt}
                align="right"
                triggerLabel="⋯"
                triggerClassName="btn-ghost"
                triggerTestId="artifact-detail-actions"
                popoverTestId="artifact-detail-actions-menu"
                ariaLabel="아티팩트 추가 작업"
                items=${[{id:"copy-sha",testId:"artifact-action-copy-sha",label:"SHA-256 복사",description:a.artifact.sha256?`${a.artifact.sha256.slice(0,12)}…`:"없음",disabled:!a.artifact.sha256,onSelect:()=>{P(a.artifact.sha256,"SHA-256")}},{id:"metadata",testId:"artifact-action-metadata",label:"메타데이터",onSelect:()=>c.onInspect({title:`Artifact: ${a.artifact.title}`,subtitle:`${a.artifact.id} · r${a.artifact.revision}`,kind:"artifact",data:a.artifact})}]}
              />
            </div>
          </div>

          <div class="kn-row-meta">
            <${Z} id=${a.artifact.author} size="sm" />
            <span class="mono kn-sha256" data-testid="artifact-sha256" title=${a.artifact.sha256||void 0}>
              SHA-256: ${a.artifact.sha256||"없음"}
            </span>
            ${a.artifact.goalId&&e`
              <button type="button" class="btn-ghost kn-btn-compact" onClick=${()=>c.onNavigate(`/work/goals/${encodeURIComponent(a.artifact.goalId)}`)}>
                Goal: ${a.artifact.goalId} →
              </button>
            `}
            ${a.artifact.taskId&&e`
              <button type="button" class="btn-ghost kn-btn-compact" onClick=${()=>c.onNavigate(`/work/tasks/${encodeURIComponent(a.artifact.taskId)}`)}>
                Task: ${a.artifact.taskId} →
              </button>
            `}
            ${a.revisions.length>1&&e`
              <select
                class="kn-select"
                value=${String(a.artifact.revision)}
                onChange=${t=>U(Number(t.target.value))}
                aria-label="리비전 선택"
              >
                ${a.revisions.map(t=>e`
                  <option key=${t.revision} value=${String(t.revision)}>rev ${t.revision} (${t.sha256.slice(0,8)})</option>
                `)}
              </select>
            `}
          </div>

          ${a.artifact.format==="html"?e`
                <iframe
                  class="kn-artifact-frame"
                  sandbox=""
                  srcDoc=${a.content}
                  title=${`Sandboxed HTML Artifact: ${a.artifact.title}`}
                />
              `:e`
                <article class="kn-md-panel">
                  <${F} text=${a.content} document />
                </article>
              `}
        </div>
      `:nt?e`<div class="kn-detail-pad"><span class="dtable-absent">아티팩트 본문 불러오는 중…</span></div>`:T?e`<div class="kn-detail-pad"><div class="kn-notice kn-notice--err" role="alert">${T}</div></div>`:null;return e`
    <${kt}
      master=${it}
      detail=${ot}
      hasSelection=${f!==null}
      selectionKey=${f}
      linkedKey=${c.entityId??null}
      masterLabel="아티팩트 목록"
      detailLabel="아티팩트 미리보기"
      emptyDetail=${e`<div class="kn-detail-pad"><span class="dtable-absent">HTML 또는 Markdown 아티팩트를 선택해 미리보세요.</span></div>`}
    />
  `}export{Bt as ArtifactsTab};
