import{d as w,A as C,q as S,y as P,T as N,m as t}from"./vendor.js";import{M as at}from"./markdown-renderer.js";import{a as J,O as L,Y as K,B as Q,s as lt}from"./index.js";import{j as rt,k as it,T as ct,l as ut,m as pt,n as dt,r as bt,o as kt,t as gt,p as $t,q as V,u as vt,v as ft}from"./index3.js";function W(r){return r==null?"":ft(r)}const mt=new TextEncoder;function yt(r){return r.truncated_to!==void 0?!0:r.result_bytes===void 0?!1:typeof r.output=="string"?r.result_bytes>mt.encode(r.output).length:!1}function Et(r){const{keeperName:b,entry:s}=r,U=J.value,Z=U.kind==="single_user_local"&&!L("admin",U),e=s.execution_id?.trim()||"",[o,v]=w(()=>e&&Z?{status:"loading"}:null),[F,j]=w(!1),[O,q]=w(!1),[E,G]=w(!1),[x,M]=w(null),k=C(!0),a=C(null),Y=C(o);Y.current=o;const h=C({keeperName:b,executionId:e});h.current={keeperName:b,executionId:e};const g=C(null),c=S(()=>{a.current?.abort(),a.current=null},[]),A=S(async(n,i)=>{!await rt(i)||!k.current||(M(n),g.current&&clearTimeout(g.current),g.current=setTimeout(()=>{g.current=null,k.current&&M(null)},1500))},[]),u=S(async(n=!1)=>{const i=J.peek();if(!e||i.kind!=="single_user_local"||L("admin",i)){v(null);return}if(a.current&&!n)return;c();const l=new AbortController;a.current=l;const $=K(),R=b,_=e;v({status:"loading"});try{const d=await it(R,_,ct,l.signal);if(!k.current||!Q($)||a.current!==l||l.signal.aborted||h.current.keeperName!==R||h.current.executionId!==_)return;if(!d.ok){if(d.error.kind==="aborted"||d.error.kind==="epoch_stale")return;v(ut(void 0,d.error));return}v(pt(void 0,d.value))}finally{a.current===l&&(a.current=null)}},[c,e,b]),B=S(async n=>{const i=J.peek();if(i.kind!=="single_user_local"||L("admin",i))return;const l=Y.current;if(!e||!l||l.status!=="loaded"||l.eof||l.isBinary||a.current)return;const $=new AbortController;a.current=$;const R=K(),_=b,d=e,H=()=>k.current&&Q(R)&&a.current===$&&!$.signal.aborted&&h.current.keeperName===_&&h.current.executionId===d;try{await dt({keeperName:_,executionId:d,initialState:l,maxPages:n,signal:$.signal,isCurrent:H,onUpdate:nt=>{H()&&v(nt)}})}finally{a.current===$&&(a.current=null)}},[e,b]);P(()=>(k.current=!0,()=>{k.current=!1,c(),g.current&&(clearTimeout(g.current),g.current=null)}),[c]),P(()=>{let n=K();return lt.subscribe(i=>{i!==n&&(n=i,c(),k.current&&u())})},[c,u]),P(()=>{j(!1),q(!1),G(!1),M(null),e?u(!0):(c(),v(null))},[b,e,s.ts,s.tool,u,c]);const T=N(()=>W(s.input),[s.input]),tt=N(()=>W(s.output),[s.output]),z=N(()=>JSON.stringify(s,null,2),[s]),p=o?.status==="loaded",f=p?o.displayContent??"":tt,st=bt(s,p&&o.isError),m=kt(o??void 0),I=yt(s),D=(p?o.eof&&!o.isBinary:!I)?gt(f):null,X=t`
    <pre
      class=${O?"kp-block-pre kp-block-pre--expanded":"kp-block-pre"}
      data-testid="tool-call-inspector-output"
    >${f}</pre>
  `,ot=!!(e&&p&&!o.eof&&!o.isBinary),y=[];s.turn!==void 0&&y.push(`Turn #${s.turn}`),s.record_kind!=="tool_call"&&y.push(s.record_kind),s.model&&y.push(s.model),e&&y.push(`exec: ${e.slice(0,12)}${e.length>12?"…":""}`);const et=y.length>0;return t`
    <div class="kp-inspector" data-testid="tool-call-inspector">
      <div class="kp-pill-row" data-testid="tool-call-inspector-meta">
        <span class="kp-pill" data-tone="info">${s.tool}</span>
        <span class="kp-pill" data-tone=${st}>
          ${s.disposition??s.wire_outcome}
        </span>
        <span class="kp-pill">${Math.round(s.duration_ms)}ms</span>
        ${s.failure_class&&t`
          <span class="kp-pill" data-tone="bad">${s.failure_class}</span>
        `}
        ${p&&m?t`
              <span class="kp-pill" data-tone=${o.eof===!1?"warn":"ok"}>
                ${m}${o.isBinary?" · 바이너리":""}${o.eof===!1?" · 일부 표시":" · 전체"}
              </span>
            `:s.result_bytes!==void 0&&t`
              <span class="kp-pill" data-tone=${I?"warn":"default"}>
                ${$t(s.result_bytes)}${I?" · 잘림":""}
              </span>
            `}
      </div>

      ${et&&t`
        <details class="ap-disclosure" data-testid="tool-call-inspector-secondary-meta">
          <summary class="ap-disclosure-trigger">
            <span>실행 메타데이터 (${y.join(" · ")})</span>
            <span aria-hidden="true">▸</span>
          </summary>
          <div class="ap-disclosure-body">
            <div class="kp-pill-row">
              ${s.turn!==void 0&&t`
                <span class="kp-pill">Turn #${s.turn}</span>
              `}
              ${s.record_kind!=="tool_call"&&t`
                <span class="kp-pill">${s.record_kind}</span>
              `}
              ${s.model&&t`
                <span class="kp-pill">${s.model}</span>
              `}
              ${e&&t`
                <span class="kp-pill">exec: ${e}</span>
              `}
            </div>
          </div>
        </details>
      `}

      <!-- Input (Args) -->
      <section class="kp-inspector-section" aria-label="입력 (Args)">
        <div class="kp-block-subbar">
          <span class="kp-block-sublabel">Input (Args)</span>
          <div class="kp-block-subactions">
            ${T&&t`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${()=>{A("input",T)}}
              >
                ${x==="input"?"복사됨":"복사"}
              </button>
            `}
            ${V(T)&&t`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${()=>j(n=>!n)}
              >
                ${F?"축소":"전체 높이"}
              </button>
            `}
          </div>
        </div>
        ${T?t`
              <pre
                class=${F?"kp-block-pre kp-block-pre--expanded":"kp-block-pre"}
                data-testid="tool-call-inspector-input"
              >${T}</pre>
            `:t`<div class="kp-block-status">입력 인자 없음</div>`}
      </section>

      <!-- Output (Result) -->
      <section class="kp-inspector-section" aria-label="출력 (Result)">
        <div class="kp-block-subbar">
          <div class="kp-pill-row">
            <span class="kp-block-sublabel">Output (Result)</span>
            ${p?t`<span class="kp-pill" data-tone="ok">원본 결과</span>`:e?t`<span class="kp-pill" data-tone="info">미리보기</span>`:null}
            ${m&&t`<span class="kp-pill">${m}</span>`}
          </div>
          <div class="kp-block-subactions">
            ${f&&t`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${()=>{A("output",f)}}
              >
                ${x==="output"?"복사됨":"복사"}
              </button>
            `}
            ${V(f)&&t`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${()=>q(n=>!n)}
              >
                ${O?"축소":"전체 높이"}
              </button>
            `}
          </div>
        </div>

        ${o?.status==="loading"&&t`
          <div class="kp-block-status" data-testid="tool-call-inspector-loading">
            원본 전체 결과 불러오는 중…
          </div>
        `}

        ${o?.status==="pending"&&t`
          <div class="kp-block-status">
            도구 실행 중 — 결과 준비 대기 중…
            ${" "}
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>{u(!0)}}
            >
              다시 확인
            </button>
          </div>
        `}

        ${o?.status==="unavailable"&&t`
          <div class="kp-block-status">
            저장된 원본 결과 없음 (${o.detail??"unavailable"}) — 로그 미리보기 표시
          </div>
        `}

        ${o?.status==="error"&&t`
          <div class="kp-tool-result-error" role="alert">
            <span>원본 결과 조회 실패 (${o.detail??"error"})</span>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>{u(!0)}}
            >
              ${o.sourceChanged?"처음부터 다시 불러오기":"다시 시도"}
            </button>
          </div>
        `}

        ${f?D===null?X:t`
              <${at} text=${D} />
              <details open=${O||void 0}>
                <summary>저장 참조</summary>
                ${X}
              </details>
            `:p?t`<div class="kp-block-status">(빈 출력 · 0 B)</div>`:t`<div class="kp-block-status">출력 결과 없음</div>`}

        ${ot&&t`
          <div class="kp-tool-result-pager" data-testid="tool-call-inspector-pager">
            <span class="kp-pill" data-tone="warn">
              ${o?.loadingMore?`불러오는 중… (${m??""})`:`표시 중 ${m??""}`}
            </span>
            <div class="kp-block-subactions">
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                disabled=${o?.loadingMore===!0}
                onClick=${()=>{B(1)}}
              >
                더 불러오기 (+16KB)
              </button>
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                disabled=${o?.loadingMore===!0}
                onClick=${()=>{B(vt)}}
              >
                끝까지 불러오기
              </button>
            </div>
          </div>
        `}

        ${p&&o.loadMoreError&&t`
          <div class="kp-tool-result-error" role="alert" data-testid="tool-call-inspector-load-more-error">
            <span>${o.loadMoreError}</span>
            <div class="kp-block-subactions">
              ${o.loadMoreConflict?t`
                    <button
                      type="button"
                      class="btn-ghost kp-toggle-btn"
                      onClick=${()=>{u(!0)}}
                    >
                      처음부터 다시 불러오기
                    </button>
                  `:t`
                    <button
                      type="button"
                      class="btn-ghost kp-toggle-btn"
                      onClick=${()=>{B(1)}}
                    >
                      다시 시도
                    </button>
                    <button
                      type="button"
                      class="btn-ghost kp-toggle-btn"
                      onClick=${()=>{u(!0)}}
                    >
                      처음부터 다시 불러오기
                    </button>
                  `}
            </div>
          </div>
        `}
      </section>

      <!-- Raw JSON Toggle -->
      <div class="kp-inspector-section">
        <div class="kp-block-subbar">
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            data-testid="tool-call-raw-toggle"
            aria-pressed=${E?"true":"false"}
            onClick=${()=>G(n=>!n)}
          >
            ${E?"원본 JSON 숨기기":"원본 JSON 보기"}
          </button>
          ${E&&t`
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${()=>{A("raw",z)}}
            >
              ${x==="raw"?"복사됨":"JSON 복사"}
            </button>
          `}
        </div>
        ${E&&t`
          <pre class="kp-block-pre" data-testid="tool-call-inspector-raw">${z}</pre>
        `}
      </div>
    </div>
  `}export{Et as K};
