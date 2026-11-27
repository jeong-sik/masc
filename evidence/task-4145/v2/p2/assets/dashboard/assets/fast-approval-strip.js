import{d as g,A as M,y as S,m as i}from"./vendor.js";import{a as C,c as A,p as F,b as U,d as W,e as Q,i as V,f as Y,s as y,g as z,m as B,h as X,n as f,j as Z,k as ss,l as as,u as ts,t as es,r as os,o as O,q as ns}from"./index.js";import{T as is}from"./target-locked-action.js";function cs(){const $=C.value,_=$.kind==="single_user_local"&&A($),x=F.value,K=U.value,L=W.value,T=Q.value,b=V.value,l=Y.value,[h,q]=g(null),c=M(null),[I,E]=g(()=>y.peek()),[k,G]=g(null),[P,w]=g(null),s=x[0]??null,r=K[0]??null,p=L[0]??null,d=T[0]??null;S(()=>{s&&s.approvalId!==k?(G(s.approvalId),w(s.revision),E(y.peek())):!s&&k!==null&&(G(null),w(null))},[s?.approvalId,s?.revision,k]);const v=s?k===s.approvalId&&P!==null?P:s.revision:null,m=(e,a)=>{const o=C.peek();if(o.kind!=="single_user_local"||!A(o)){O("도구 승인 결정은 싱글유저 관리자 세션에서만 실행할 수 있습니다.","info");return}const t=e.approvalId;c.current!==t&&(c.current=t,q(t),ns(e,a).then(n=>{n.ok||O(`${a==="approve"?"승인":"거절"} 실패: ${n.message}`,"error")}).finally(()=>{c.current===t&&(c.current=null),q(n=>n===t?null:n)}))};S(()=>{if(!s&&!r&&!p&&!d)return;const e=a=>{if(a.defaultPrevented||a.isComposing||a.keyCode===229||z.peek()||B.peek()||typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]')||a.metaKey||a.ctrlKey)return;const o=a.code==="KeyY"?"y":a.code==="KeyN"?"n":a.code==="KeyJ"?"j":"",t=a.altKey&&o?o:a.key.toLowerCase(),n=X(a.target);if(t==="j"&&!n&&!a.altKey){a.preventDefault(),f("/work/inbox");return}if(!s)return;const J=a.altKey&&!a.shiftKey&&(t==="y"||t==="n");if(n&&!J||!n&&a.altKey&&t!=="y"&&t!=="n")return;const R=C.peek();if(R.kind!=="single_user_local"||!A(R))return;const N=y.peek()!==I,j=Z.peek()!==s.workspaceId,H=v!==null&&s.revision!==v;N||j||H||h===s.approvalId||c.current===s.approvalId||(t==="y"?(a.preventDefault(),m(s,"approve")):t==="n"&&(a.preventDefault(),m(s,"deny")))};return window.addEventListener("keydown",e),()=>window.removeEventListener("keydown",e)},[s,r,p,d,I,v,h]);const D=x.length+K.length+L.length+T.length,u=ss(D,b.length>0);if(!s&&!r&&!p&&!d){if(!as($)||b.length===0)return null;const e=b.every(o=>o.state.kind==="unbridged"),a=b.map(o=>`${o.label}(${ts(o.state)})`).join(" · ");return i`
      <section
        class=${`ap-fast-strip ap-fast-strip--ask${l?" is-mobile":""}`}
        role="status"
        aria-label="HITL 대기열 일부 미확인"
        data-testid="fast-approval-strip"
        data-hitl-unchecked="true"
      >
        <div class="ap-fast-row">
          <div class="ap-fast-summary">
            <span class="ap-fast-pill">HITL · ${u}</span>
            <span class="ap-fast-question">
              ${e?"멀티 계정 미지원 소스: ":"미확인 소스: "}${a}
            </span>
          </div>
          <div class="ap-fast-actions">
            <button
              type="button"
              class="btn-ghost ap-fast-btn"
              onClick=${()=>es()}
            >
              Quick-Peek
            </button>
          </div>
        </div>
      </section>
    `}if(s){const e=h===s.approvalId;return i`
      <section
        class=${`ap-fast-strip${l?" is-mobile":""}`}
        role="region"
        aria-label="긴급 도구 승인 대기"
        data-testid="fast-approval-strip"
      >
        <${is}
          className="ap-fast-tla"
          target=${{workspaceId:s.workspaceId,keeper:s.keeper,requestId:s.approvalId,revision:v??s.revision}}
          currentRevision=${s.revision}
          lockedEpoch=${I}
          onRefresh=${()=>{w(s.revision),E(y.peek()),os()}}
        >
          ${a=>i`
            <div class="ap-fast-row">
              <div class="ap-fast-summary">
                <span class="ap-fast-pill">APPROVAL · ${u}</span>
                <strong class="ap-fast-keeper">${s.keeper}</strong>
                <code class="ap-fast-tool">${s.tool||s.toolCallId}</code>
                ${!l&&s.question&&i`
                  <span class="ap-fast-question">${s.question}</span>
                `}
              </div>
              <div class="ap-fast-actions">
                ${_?i`
                      <button
                        type="button"
                        class="btn-primary ap-fast-btn"
                        disabled=${a.locked||e}
                        onClick=${()=>m(s,"approve")}
                      >
                        승인 <kbd class="ap-kbd">Y</kbd>
                      </button>
                      <button
                        type="button"
                        class="btn-ghost ap-fast-btn ap-fast-deny"
                        disabled=${a.locked||e}
                        onClick=${()=>m(s,"deny")}
                      >
                        거절 <kbd class="ap-kbd">N</kbd>
                      </button>
                    `:i`<span class="ap-fast-question" data-testid="fast-approval-admin-locked">관리자 전용</span>`}
                <button
                  type="button"
                  class="btn-ghost ap-fast-btn"
                  onClick=${()=>f("/work/inbox")}
                >
                  Inbox <kbd class="ap-kbd">J</kbd>
                </button>
              </div>
            </div>
          `}
        <//>
      </section>
    `}return r?i`
      <section
        class=${`ap-fast-strip ap-fast-strip--ask${l?" is-mobile":""}`}
        role="region"
        aria-label="Keeper 질문 대기"
        data-testid="fast-approval-strip"
      >
        <div class="ap-fast-row">
          <div class="ap-fast-summary">
            <span class="ap-fast-pill">ASK · ${u}</span>
            <strong class="ap-fast-keeper">${r.keeper}</strong>
            <span class="ap-fast-question">${r.prompt}</span>
          </div>
          <div class="ap-fast-actions">
            <button
              type="button"
              class="btn-primary ap-fast-btn"
              onClick=${()=>f("/work/inbox")}
            >
              답변하기 <kbd class="ap-kbd">J</kbd>
            </button>
          </div>
        </div>
      </section>
    `:p?i`
      <section
        class=${`ap-fast-strip${l?" is-mobile":""}`}
        role="region"
        aria-label="Channel Gate 승인 대기"
        data-testid="fast-approval-strip"
      >
        <div class="ap-fast-row">
          <div class="ap-fast-summary">
            <span class="ap-fast-pill">GATE · ${u}</span>
            <strong class="ap-fast-keeper">${p.keeper}</strong>
            <code class="ap-fast-tool">${p.toolName}</code>
          </div>
          <div class="ap-fast-actions">
            <button
              type="button"
              class="btn-primary ap-fast-btn"
              onClick=${()=>f("/work/inbox")}
            >
              Inbox <kbd class="ap-kbd">J</kbd>
            </button>
          </div>
        </div>
      </section>
    `:i`
    <section
      class=${`ap-fast-strip ap-fast-strip--ask${l?" is-mobile":""}`}
      role="region"
      aria-label="Goal 완료 확인 대기"
      data-testid="fast-approval-strip"
    >
      <div class="ap-fast-row">
        <div class="ap-fast-summary">
          <span class="ap-fast-pill">GOAL CONFIRM · ${u}</span>
          <strong class="ap-fast-keeper">${d.goalId}</strong>
          <span class="ap-fast-question">${d.title}</span>
        </div>
        <div class="ap-fast-actions">
          <button
            type="button"
            class="btn-primary ap-fast-btn"
            onClick=${()=>f("/work/inbox")}
          >
            Inbox <kbd class="ap-kbd">J</kbd>
          </button>
        </div>
      </div>
    </section>
  `}export{cs as FastApprovalStrip};
