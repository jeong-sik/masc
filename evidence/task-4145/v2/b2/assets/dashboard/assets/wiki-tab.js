import{d as r,A as L,y as M,q as V,T as Ve,m as n}from"./vendor.js";import{M as ze}from"./markdown-renderer.js";import{O as dt,a as ut,z as O,Y as se,T as q,B as U,K as pt,P as kt,ad as gt,o as He,a0 as vt,n as Qe}from"./index.js";import{K as Ye}from"./core.js";import{M as $t}from"./master-detail.js";import{R as Je}from"./refresh-button.js";import{V as bt}from"./virtual-list.js";import{d as mt}from"./markdown.js";import{e as N,a as m,b as ae,c as ie,d as ft,f as I,g as ht,h as et,i as wt}from"./wire-decode.js";import{WIKI_SOURCES as Xe,formatRelativeTime as Ie,WIKI_LINK_KINDS as yt}from"./index2.js";import"./type-guards.js";import"./table.js";import"./useSelector.js";import"./lazy-component.js";import"./attachment-gallery.js";import"./copyable-code.js";import"./toast.js";function _t(l,t){return mt(l,t).map(s=>({kind:s.added?"added":s.removed?"removed":"equal",text:s.value}))}function Ct(l){const t="GET /api/v1/wiki",s=N(l,t),g=m(s,"pages",t),d=m(s,"unreadable_pages",t),R=m(s,"tags",t),k=ae(s,"sources",t),c=ae(s,"lint",t),v={total_findings:typeof c.total_findings=="number"?c.total_findings:0,counts:ae(c,"counts",`${t} lint`),log_hole_suppressed:c.log_hole_suppressed===!0,orphans:ie(c,"orphans",`${t} lint`),duplicate_title_candidates:m(c,"duplicate_title_candidates",`${t} lint`),findings:m(c,"findings",`${t} lint`)};return{...s,pages_total:typeof s.pages_total=="number"?s.pages_total:g.length,pages_readable:typeof s.pages_readable=="number"?s.pages_readable:g.length,pages_unreadable:typeof s.pages_unreadable=="number"?s.pages_unreadable:d.length,pages:g,unreadable_pages:d,tags:R,sources:k,lint:v}}function St(l){const t="GET /api/v1/wiki/lint",s=N(l,t);return{...s,counts:ae(s,"counts",t),duplicate_title_candidates:m(s,"duplicate_title_candidates",t),findings:m(s,"findings",t)}}function Rt(l){const t="GET /api/v1/wiki/log",s=N(l,t);return{...s,entries:m(s,"entries",t)}}function xt(l){const t="GET /api/v1/wiki/search",s=N(l,t),d=ft(s,"results",t).map((R,k)=>{const c=`${t} results[${k}]`,v=N(R,c),E=m(v,"snippets",c),W=ie(v,"tags",c);return{...v,snippets:E,tags:W}});return{...s,results:d}}function Lt(l){return yt.includes(l)}function It(l,t){const s=I(l,"kind",t);if(!Lt(s))throw new Error(`${t}: "kind" 필드의 링크 종류 "${s}" 를 모릅니다.`);const g=l.exists;if(g!==null&&typeof g!="boolean")throw new Error(`${t}: "exists" 필드는 boolean 이나 null 이어야 합니다 (${wt(g)} 수신).`);return{text:I(l,"text",t),kind:s,target:I(l,"target",t),raw:I(l,"raw",t),line:et(l,"line",t),exists:g}}function Ze(l){const t="GET /api/v1/wiki/:slug",s=N(l,t),g=I(s,"slug",t),d=I(s,"sha256",t),R=I(s,"body_markdown",t),k=ht(s,"frontmatter",t),c=I(k,"title",`${t} frontmatter`),v=et(k,"revision",`${t} frontmatter`),E=ie(k,"tags",`${t} frontmatter`),W=ie(s,"backlinks",t),z=m(s,"outgoing_links",t).map((T,f)=>It(T,`${t} outgoing_links[${f}]`)),j=m(s,"lint_findings",t);return{...s,slug:g,sha256:d,body_markdown:R,frontmatter:{...k,title:c,revision:v,tags:E},backlinks:W,outgoing_links:z,lint_findings:j}}function zt(l){const t=dt("admin",ut.value),[s,g]=r("pages"),[d,R]=r(null),k=O.observe("kn:wiki:lint").value,c=O.observe("kn:wiki:log").value,v=k.kind==="value"?k.data:null,E=c.kind==="value"?c.data:null,[W,z]=r(!0),[j,T]=r(null),[f,Ee]=r(""),[H,tt]=r(""),[oe,nt]=r("updated"),[We,Pe]=r(""),[Q,G]=r(null),[Te,le]=r(!1),[h,y]=r(l.entityId??null),[i,re]=r(null),[Y,De]=r(null),J=L(null),[D,K]=r(!1),[w,_]=r(!1),[ce,de]=r(""),[X,ue]=r(""),[pe,ke]=r(""),[Ke,ge]=r("observation"),[Ae,ve]=r(""),[$e,be]=r(""),[Fe,me]=r(""),[fe,he]=r(null),[Be,we]=r(null),[A,Me]=r(!1),[Z,x]=r(null),[b,P]=r(null),Oe=L(async()=>{}),ye=L(!1),ee=L(null),C=L(!0),qe=L(0),_e=L(null),Ce=L(null);M(()=>(C.current=!0,()=>{C.current=!1,_e.current?.abort(),ee.current?.abort()}),[]),M(()=>{t&&D&&(K(!1),_(!1),P(null))},[t,D]);const te=V(async(e="mount")=>{const a=++qe.current,u=se();z(!0),T(null);const o=new URLSearchParams({sort:oe});f&&o.set("tag",f),H&&o.set("source",H);const p=await O.fetch(`kn:wiki:index:${o.toString()}`,S=>q(`/api/v1/wiki?${o.toString()}`,{signal:S,decode:Ct}),{ttlMs:12e3,topics:["wiki","wiki_updated"],reason:e});!C.current||qe.current!==a||!U(u)||(z(!1),p.kind==="value"?(R(p.data),pt(),y(S=>{const F=p.data.pages;return l.entityId&&F.some(B=>B.slug===l.entityId)?l.entityId:S&&F.some(B=>B.slug===S)?S:F[0]?.slug??null})):p.kind==="failed"&&(p.error.kind==="decode"&&R(null),T(p.error.message)))},[oe,f,H,l.entityId]);M(()=>{te("mount")},[te]);const Se=V(e=>{O.fetch("kn:wiki:lint",a=>q("/api/v1/wiki/lint",{signal:a,decode:St}),{reason:e,topics:["wiki","wiki_updated"]})},[]),Re=V(e=>O.fetch("kn:wiki:log",a=>q("/api/v1/wiki/log?limit=100",{signal:a,decode:Rt}),{reason:e,topics:["wiki","wiki_updated"]}),[]);M(()=>{s==="lint"&&Se("mount"),s==="log"&&Re("mount")},[s,Se,Re]);const st=V(async e=>{_e.current?.abort();const a=e.trim();if(!a){G(null),le(!1);return}const u=new AbortController;_e.current=u;const o=se();le(!0);const p=await q(`/api/v1/wiki/search?q=${encodeURIComponent(a)}&limit=30`,{signal:u.signal,decode:xt});!C.current||u.signal.aborted||!U(o)||(le(!1),p.ok?(T(null),G(p.value)):p.error.kind!=="aborted"&&p.error.kind!=="epoch_stale"&&(p.error.kind==="decode"&&G(null),T(`위키 검색 실패: ${p.error.message}`)))},[]),xe=V(async(e,a)=>{const u=se();De(null);const o=await q(`/api/v1/wiki/${encodeURIComponent(e)}`,{signal:a,decode:Ze});return!C.current||a?.aborted||!U(u)?null:o.ok?(re(o.value),o.value):(o.error.kind==="decode"&&re(null),De(o.error.message),null)},[]);M(()=>{if(J.current?.abort(),!h||w)return;K(!1),re(null),P(null),Ce.current===h?Ce.current=null:x(null);const e=new AbortController;return J.current=e,xe(h,e.signal),()=>{e.abort()}},[h,w,xe]);const Ue=e=>{t||(_(!1),K(!0),P(null),x(null),de(e.slug),ue(e.frontmatter.title),ke(e.frontmatter.summary),ge(e.frontmatter.source),ve(e.frontmatter.tags.join(", ")),be(e.body_markdown),me(""),he(e.sha256),we(e.frontmatter.revision))},at=()=>{t||(_(!0),K(!0),P(null),x(null),de(""),ue(""),ke(""),ge("observation"),ve(""),be(""),me("create page"),he(null),we(null))},ne=async e=>{if(t||ye.current)return;const a=ce.trim();if(!a||!X.trim()){x({kind:"err",message:"Slug와 페이지 제목을 모두 입력하세요."});return}const u=se();ee.current?.abort();const o=new AbortController;ee.current=o,ye.current=!0,Me(!0),x(null);const p=Ae.split(",").map($=>$.trim()).filter(Boolean),S={title:X.trim(),summary:pe.trim(),source:Ke,tags:p,body:$e,note:Fe.trim()||"dashboard edit"},F=e?.sha256??fe,B=e?.revision??Be;w||(F&&(S.expected_sha256=F),B!==null&&(S.expected_revision=B));try{const $=await vt("PUT",`/api/v1/wiki/${encodeURIComponent(a)}`,S,{signal:o.signal});if(!C.current||!U(u)||o.signal.aborted)return;if(!$.ok){if($.error.kind==="conflict_cas"||$.error.status===409||$.error.code==="conflict_cas"){const Le=await q(`/api/v1/wiki/${encodeURIComponent(a)}`,{signal:o.signal,decode:Ze});if(!C.current||!U(u)||o.signal.aborted)return;Le.ok?P({serverPage:Le.value,localBody:$e,localTitle:X,localSummary:pe,message:$.error.message||"409 conflict_cas: 다른 작성자가 페이지를 먼저 수정했습니다."}):x({kind:"err",message:`409 CAS 충돌이 발생했으나 최신 페이지를 다시 읽지 못했습니다: ${Le.error.message}`});return}x({kind:"err",message:`저장 실패: ${$.error.message}`});return}if(Ce.current=$.value.slug,P(null),_(!1),K(!1),y($.value.slug),x(null),He(`${$.value.slug} (rev ${$.value.revision}) ${$.value.action==="created"?"생성":"저장"} 완료`,"success"),O.invalidateTopic("wiki"),await te("manual"),!C.current||!U(u)||o.signal.aborted)return;J.current?.abort();const Ge=new AbortController;J.current=Ge,await xe($.value.slug,Ge.signal)}finally{ee.current===o&&(ye.current=!1,C.current&&Me(!1))}};Oe.current=()=>ne(),M(()=>{if(!D)return;const e=a=>{a.isComposing||a.keyCode===229||(a.metaKey||a.ctrlKey)&&a.key.toLowerCase()==="s"&&(a.preventDefault(),A||Oe.current())};return window.addEventListener("keydown",e),()=>window.removeEventListener("keydown",e)},[D,A]);const it=Ve(()=>b?_t(b.serverPage.body_markdown,b.localBody):[],[b]),ot=d?d.pages:[],lt=n`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <div class="kn-chips" role="tablist" aria-label="Wiki 보기">
          <button type="button" role="tab" class="kn-chip" aria-selected=${s==="pages"} onClick=${()=>g("pages")}>
            Pages <span class="kn-chip-count">${d?d.pages_total:W?"…":"—"}</span>
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${s==="lint"} onClick=${()=>g("lint")}>
            Lint <span class="kn-chip-count">${d?.lint?d.lint.total_findings:W?"…":"—"}</span>
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${s==="log"} onClick=${()=>g("log")}>
            Log
          </button>
        </div>
        <div class="kn-actions">
          ${!t&&n`<button type="button" class="btn-primary" data-opens-detail onClick=${at}>+ 새 페이지</button>`}
          <${Je} onRefresh=${()=>te("manual")} />
        </div>
      </div>

      ${s==="pages"&&n`
        <div class="kn-filter-bar">
          <form
            class="kn-search-row"
            onSubmit=${e=>{e.preventDefault(),st(We)}}
          >
            <input
              type="search"
              class="kn-input kn-search-input"
              placeholder="Wiki 전문 검색 (GET /api/v1/wiki/search)…"
              value=${We}
              onInput=${e=>{const a=e.target.value;Pe(a),a.trim()||G(null)}}
              aria-label="Wiki 검색"
            />
            <button type="submit" class="btn-ghost" disabled=${Te}>
              ${Te?"검색 중…":"검색"}
            </button>
          </form>

          <div class="kn-toolbar">
            <select
              class="kn-select"
              value=${H}
              onChange=${e=>tt(e.target.value)}
              aria-label="출처 필터"
            >
              <option value="">전체 출처</option>
              ${Xe.map(e=>n`<option key=${e} value=${e}>${e}</option>`)}
            </select>
            <select
              class="kn-select"
              value=${oe}
              onChange=${e=>nt(e.target.value)}
              aria-label="페이지 정렬"
            >
              <option value="updated">최근 수정순</option>
              <option value="title">제목순</option>
              <option value="rank">연결 순위순</option>
            </select>
            ${d&&(d.tags?.length??0)>0&&n`
              <${kt}
                align="right"
                triggerLabel=${f?`태그: #${f} ▾`:`태그 (${(d.tags??[]).length}) ▾`}
                triggerClassName="btn-ghost"
                triggerTestId="wiki-tag-filter"
                popoverTestId="wiki-tag-filter-menu"
                popoverClassName="kn-tag-popover"
                ariaLabel="태그 필터"
                items=${[{id:"__all__",testId:"wiki-tag-all",label:"전체 태그",active:f==="",onSelect:()=>Ee("")},...(d.tags??[]).slice(0,24).map(e=>({id:e.tag,testId:`wiki-tag-${e.tag}`,label:`#${e.tag} (${e.count})`,active:f===e.tag,onSelect:()=>Ee(f===e.tag?"":e.tag)}))]}
              />
            `}
          </div>
        </div>

        ${j&&n`<div class="kn-notice kn-notice--err kn-inset" role="alert">${j}</div>`}

        ${Q?n`
              <div class="kn-search-results">
                <div class="kn-row-meta">
                  <span>검색 결과: <strong>${Q.count}</strong>건 ("${Q.query}")</span>
                  <button type="button" class="btn-ghost kn-btn-compact" onClick=${()=>{Pe(""),G(null)}}>
                    검색 닫기
                  </button>
                </div>
                ${(Q.results??[]).map(e=>n`
                  <button
                    key=${e.slug}
                    type="button"
                    class="kn-row-btn"
                    data-selected=${h===e.slug?"true":"false"}
                    data-opens-detail
                    onClick=${()=>{_(!1),y(e.slug)}}
                  >
                    <div class="kn-row-top">
                      <span class="kn-row-title">${e.title}</span>
                      <span class="kn-badge kn-badge--info">${e.match_tier}</span>
                    </div>
                    <div class="kn-row-meta">
                      <span class="mono">${e.slug}</span>
                      <span>rev ${e.revision}</span>
                    </div>
                    ${e.snippets?.[0]&&n`
                      <div class="kn-sub-line">
                        L${e.snippets[0].line}: ${e.snippets[0].text}
                      </div>
                    `}
                  </button>
                `)}
              </div>
            `:W&&!d?n`<div class="kn-detail-pad"><span class="dtable-absent">Wiki 인덱스 불러오는 중…</span></div>`:j&&!d?null:n`
                  <${bt}
                    items=${ot}
                  estimateSize=${76}
                  height="100%"
                  ariaLabel="Wiki 페이지 목록"
                  getItemKey=${e=>e.slug}
                  empty=${n`<div class="kn-detail-pad"><span class="dtable-absent">등록된 Wiki 페이지가 없습니다.</span></div>`}
                  renderItem=${e=>n`
                    <button
                      type="button"
                      class="kn-row-btn"
                      data-selected=${!w&&h===e.slug?"true":"false"}
                      onClick=${()=>{_(!1),y(e.slug)}}
                    >
                      <div class="kn-row-top">
                        <span class="kn-row-title">${e.title}</span>
                        <span class="kn-badge">${e.source}</span>
                      </div>
                      <div class="kn-row-meta">
                        <span class="mono">${e.slug}</span>
                        <span class="tnum">rev ${e.revision}</span>
                        <span class="tnum">← ${e.backlink_count}</span>
                        <span>${Ie(e.updated)}</span>
                      </div>
                    </button>
                  `}
                />
              `}
      `}

      ${s==="lint"&&n`
        <div class="kn-detail-pad kn-scroll-pad">
          <div class="kn-section-head">
            <h3 class="kn-section-title">Wiki Lint Findings</h3>
            <button type="button" class="btn-ghost" onClick=${()=>Se("manual")}>다시 검사</button>
          </div>
          ${k.kind==="failed"||k.kind==="absent"||k.kind==="unreported"?n`<div class="kn-notice kn-notice--err" role="alert">Lint 보고서 조회 실패: ${k.kind==="failed"?k.error.message:k.reason??"응답을 확인할 수 없습니다."}</div>`:v?n`
                <div class="kn-chips">
                  ${Object.entries(v.counts??{}).map(([e,a])=>n`
                    <span key=${e} class=${`kn-badge ${a>0?"kn-badge--warn":"kn-badge--ok"}`}>
                      ${e}: ${a}
                    </span>
                  `)}
                </div>
                ${(v.duplicate_title_candidates??[]).length>0&&n`
                  <div class="kn-notice kn-notice--warn">
                    중복 제목 후보 ${(v.duplicate_title_candidates??[]).length}쌍 감지됨
                  </div>
                `}
                ${(v.findings??[]).length===0?n`<div class="kn-notice kn-notice--ok">Lint 경고가 없습니다 (0).</div>`:(v.findings??[]).map((e,a)=>n`
                      <button
                        key=${`${e.kind}-${e.subject}-${a}`}
                        type="button"
                        class="kn-row-btn kn-card-row"
                        data-opens-detail=${e.page??e.subject?!0:void 0}
                        onClick=${()=>{const u=e.page??e.subject;u&&(_(!1),y(u))}}
                      >
                        <div class="kn-row-top">
                          <span class="kn-badge kn-badge--warn">${e.kind}</span>
                          <span class="mono kn-sub-id">${e.page??e.subject}</span>
                        </div>
                        <div class="kn-body-sm">
                          ${e.reason??e.target??e.subject} ${e.line?`(L${e.line})`:""}
                        </div>
                      </button>
                    `)}
              `:n`<span class="dtable-absent">Lint 보고서 불러오는 중…</span>`}
        </div>
      `}

      ${s==="log"&&n`
        <div class="kn-detail-pad kn-scroll-pad">
          <div class="kn-section-head">
            <h3 class="kn-section-title">Wiki Revision Log</h3>
            <${Je} onRefresh=${()=>Re("manual")} />
          </div>
          ${c.kind==="failed"||c.kind==="absent"||c.kind==="unreported"?n`<div class="kn-notice kn-notice--err" role="alert">Wiki 로그 조회 실패: ${c.kind==="failed"?c.error.message:c.reason??"응답을 확인할 수 없습니다."}</div>`:E?(E.entries??[]).length===0?n`<span class="dtable-absent">기록된 Wiki 로그가 없습니다.</span>`:(E.entries??[]).map(e=>n`
                  <button
                    key=${e.idx}
                    type="button"
                    class="kn-row-btn kn-card-row"
                    data-opens-detail
                    onClick=${()=>{_(!1),y(e.page)}}
                  >
                    <div class="kn-row-top">
                      <span class="mono">${e.page}</span>
                      <span class="kn-badge kn-badge--info">${e.action} · r${e.revision}</span>
                    </div>
                    <div class="kn-row-meta">
                      ${e.author&&n`<${Ye} id=${e.author} size="sm" />`}
                      <span>${Ie(e.written_at_unix)}</span>
                      ${e.note&&n`<span>${e.note}</span>`}
                    </div>
                  </button>
                `):n`<span class="dtable-absent">로그 불러오는 중…</span>`}
        </div>
      `}
    </div>
  `,Ne=Ve(()=>{const e=new Map((d?.pages??[]).map(o=>[o.slug,o.summary])),a=new Map,u=new Map;for(const o of i?.outgoing_links??[]){if(o.kind!=="page"||o.exists!==!0)continue;const p=`#${gt(`/knowledge/wiki/${encodeURIComponent(o.target)}`).path}`;a.set(o.raw,{href:p,title:e.get(o.target)||void 0}),u.set(p,o.target)}return{rewrites:a,slugByHref:u}},[i,d]),rt=e=>{if(e.button!==0||e.metaKey||e.ctrlKey||e.shiftKey||e.altKey)return;const a=e.target instanceof Element?e.target.closest("a[href]"):null,u=a?Ne.slugByHref.get(a.getAttribute("href")??""):void 0;u&&(e.preventDefault(),h&&Qe(`/knowledge/wiki/${encodeURIComponent(h)}`,{replace:!0}),Qe(`/knowledge/wiki/${encodeURIComponent(u)}`),y(u))},je=h!==null&&!w&&i===null&&Y===null,ct=D&&!t?n`
        <div class="kn-detail-pad">
          <div class="kn-section-head">
            <div>
              <h2 class="kn-heading-tight">
                ${w?"새 Wiki 페이지 작성":`편집: ${ce}`}
              </h2>
              ${!w&&fe&&n`
                <div class="mono kn-sub-id">
                  CAS Lock: rev ${Be??"없음"} · sha256 ${fe.slice(0,12)}…
                </div>
              `}
            </div>
            <div class="kn-actions">
              <button type="button" class="btn-primary" disabled=${A} onClick=${()=>{ne()}}>
                ${A?"저장 중…":"CAS 저장 (PUT)"}
              </button>
              <button
                type="button"
                class="btn-ghost"
                data-opens-master=${w?!0:void 0}
                onClick=${()=>{K(!1),_(!1),P(null)}}
              >
                취소
              </button>
            </div>
          </div>

          ${Z&&n`
            <div class="kn-notice kn-notice--err" role="alert">${Z.message}</div>
          `}

          ${b&&n`
            <section class="kn-section kn-conflict-box" role="alert" aria-label="409 CAS 충돌 복구">
              <div class="kn-section-head">
                <strong class="kn-conflict-title">409 conflict_cas — 동시 편집 충돌 감지</strong>
                <span class="mono kn-sub-id">
                  서버 최신 rev ${b.serverPage.frontmatter.revision} · ${b.serverPage.sha256.slice(0,10)}…
                </span>
              </div>
              <div class="kn-body-sm">${b.message}</div>
              <div class="kn-sub-id">
                Diff (- 서버 최신본 / + 내 로컬 초안):
              </div>
              <pre class="kn-diff-box">${it.map((e,a)=>n`
                <span
                  key=${a}
                  class=${e.kind==="added"?"kn-diff-added":e.kind==="removed"?"kn-diff-removed":"kn-diff-equal"}
                >${e.kind==="added"?"+ ":e.kind==="removed"?"- ":"  "}${e.text}</span>
              `)}</pre>
              <div class="kn-actions">
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{Ue(b.serverPage),He("서버 최신 리비전으로 에디터를 다시 불러왔습니다.","info")}}
                >
                  서버 최신본으로 다시 불러오기 (Reload)
                </button>
                <button
                  type="button"
                  class="kn-btn-warn"
                  disabled=${A}
                  onClick=${()=>{he(b.serverPage.sha256),we(b.serverPage.frontmatter.revision),ne({sha256:b.serverPage.sha256,revision:b.serverPage.frontmatter.revision})}}
                >
                  최신 리비전 기준으로 내 수정본 저장 (Rebase & Retry)
                </button>
              </div>
            </section>
          `}

          <div class="kn-grid-auto">
            <div class="kn-field">
              <label for="wiki-slug" class="kn-field-label">Slug</label>
              <input
                id="wiki-slug"
                class="kn-input mono"
                disabled=${!w}
                value=${ce}
                onInput=${e=>de(e.target.value)}
                placeholder="예: architecture-notes"
              />
            </div>
            <div class="kn-field">
              <label for="wiki-title" class="kn-field-label">제목</label>
              <input
                id="wiki-title"
                class="kn-input"
                value=${X}
                onInput=${e=>ue(e.target.value)}
              />
            </div>
            <div class="kn-field">
              <label for="wiki-source" class="kn-field-label">출처 (source)</label>
              <select
                id="wiki-source"
                class="kn-select"
                value=${Ke}
                onChange=${e=>ge(e.target.value)}
              >
                ${Xe.map(e=>n`<option key=${e} value=${e}>${e}</option>`)}
              </select>
            </div>
          </div>

          <input
            type="text"
            class="kn-input"
            placeholder="요약 (summary)"
            value=${pe}
            onInput=${e=>ke(e.target.value)}
            aria-label="페이지 요약"
          />
          <div class="kn-grid-2">
            <input
              type="text"
              class="kn-input"
              placeholder="태그 (쉼표 구분)"
              value=${Ae}
              onInput=${e=>ve(e.target.value)}
              aria-label="태그"
            />
            <input
              type="text"
              class="kn-input"
              placeholder="변경 메모 (commit note)"
              value=${Fe}
              onInput=${e=>me(e.target.value)}
              aria-label="변경 메모"
            />
          </div>

          <textarea
            class="kn-textarea kn-textarea--editor"
            value=${$e}
            onInput=${e=>be(e.target.value)}
            onKeyDown=${e=>{e.isComposing||e.keyCode===229||(e.metaKey||e.ctrlKey)&&e.key==="Enter"&&!A&&(e.preventDefault(),ne())}}
            aria-label="Markdown 본문 편집기"
          />
        </div>
      `:i?n`
          <div class="kn-detail-pad">
            ${Z&&n`<div class="kn-notice kn-notice--err" role="alert">${Z.message}</div>`}
            <div class="kn-section-head">
              <div class="kn-min-w-0">
                <div class="kn-row-meta">
                  <span class="mono">${i.slug}</span>
                  <span class="kn-badge">${i.frontmatter.source}</span>
                  <span class="mono tnum">rev ${i.frontmatter.revision}</span>
                  <span class="mono">sha256:${i.sha256.slice(0,12)}</span>
                </div>
                <h2 class="kn-heading">${i.frontmatter.title}</h2>
                ${i.frontmatter.summary&&n`
                  <${ze} class="kn-subcopy" text=${i.frontmatter.summary} />
                `}
              </div>
              <div class="kn-actions">
                ${!t&&n`
                  <button type="button" class="btn-primary" onClick=${()=>Ue(i)}>
                    CAS 편집
                  </button>
                `}
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>l.onInspect({title:`Wiki: ${i.frontmatter.title}`,subtitle:`${i.slug} · rev ${i.frontmatter.revision}`,kind:"wiki",data:i})}
                >
                  메타데이터
                </button>
              </div>
            </div>

            <div class="kn-row-meta">
              <${Ye} id=${i.frontmatter.author} size="sm" />
              <span>수정: ${Ie(i.frontmatter.updated)}</span>
              ${(i.frontmatter.tags??[]).map(e=>n`<span key=${e} class="kn-badge">#${e}</span>`)}
            </div>

            ${(i.lint_findings??[]).length>0&&n`
              <div class="kn-notice kn-notice--warn">
                이 페이지에 Lint 경고 ${(i.lint_findings??[]).length}건이 있습니다:
                ${(i.lint_findings??[]).map(e=>e.kind).join(", ")}
              </div>
            `}

            <article class="kn-md-panel" onClick=${rt}>
              <${ze} text=${i.body_markdown} document linkRewrites=${Ne.rewrites} />
            </article>

            <details class="ap-disclosure" data-testid="wiki-links-disclosure">
              <summary class="ap-disclosure-trigger">
                <span>연결 문서: Backlinks ${(i.backlinks??[]).length} · Outgoing ${(i.outgoing_links??[]).length}</span>
                <span aria-hidden="true">▸</span>
              </summary>
              <div class="ap-disclosure-body">
                <div class="kn-grid-links">
                  <section class="kn-section">
                    <h3 class="kn-section-title">Backlinks (${(i.backlinks??[]).length})</h3>
                    ${(i.backlinks??[]).length===0?n`<span class="dtable-absent">없음</span>`:n`
                          <div class="kn-chips">
                            ${(i.backlinks??[]).map(e=>n`
                              <button key=${e} type="button" class="kn-chip mono" onClick=${()=>y(e)}>
                                ${e}
                              </button>
                            `)}
                          </div>
                        `}
                  </section>
                  <section class="kn-section">
                    <h3 class="kn-section-title">Outgoing Links (${(i.outgoing_links??[]).length})</h3>
                    ${(i.outgoing_links??[]).length===0?n`<span class="dtable-absent">없음</span>`:n`
                          <div class="kn-chips">
                            ${(i.outgoing_links??[]).map((e,a)=>n`
                              <button
                                key=${`${e.target}-${a}`}
                                type="button"
                                class="kn-chip"
                                onClick=${()=>{e.kind==="page"&&e.exists&&y(e.target)}}
                              >
                                ${e.text||e.target}
                                ${e.exists===!1&&n`<span class="kn-badge kn-badge--err">broken</span>`}
                              </button>
                            `)}
                          </div>
                        `}
                  </section>
                </div>
              </div>
            </details>
          </div>
        `:je?n`<div class="kn-detail-pad"><span class="dtable-absent">Wiki 페이지 불러오는 중…</span></div>`:Y?n`<div class="kn-detail-pad"><div class="kn-notice kn-notice--err" role="alert">${Y}</div></div>`:null;return n`
    <${$t}
      master=${lt}
      detail=${ct}
      hasSelection=${D||i!==null||je||Y!==null}
      selectionKey=${w?"__new__":h}
      linkedKey=${l.entityId??null}
      masterLabel="Wiki 인덱스"
      detailLabel="Wiki 본문"
      emptyDetail=${n`<div class="kn-detail-pad"><span class="dtable-absent">${t?"Wiki 페이지를 선택하세요.":'Wiki 페이지를 선택하거나 "+ 새 페이지"를 눌러 문서를 작성하세요.'}</span></div>`}
    />
  `}export{zt as WikiTab};
