import{A as h,d as y,y as E,_ as z,m as g}from"./vendor.js";const B='[role="listitem"], [data-opens-detail]',F="[data-opens-master]";function T(e,v){for(const r of e.composedPath()){if(r===e.currentTarget)return!1;if(r instanceof Element&&r.matches(v))return!0}return!1}function J(e){const v=e.hasSelection??!0,r=e.masterLabel??"목록",L=e.detailLabel??"상세 정보",D=h(null),f=h(null),c=h(null),w=e.selectionKey!==void 0,K=e.selectionKey===null,m=e.selectionKey??null,d=e.linkedKey??null,[S,$]=y("master"),[u,R]=y(d),[k,I]=y(null),s=u!==null&&m!==null&&(m===u&&v||m===k)||S==="detail"?"detail":"master",[M,P]=y(d);M!==d?(P(d),R(d),d===null?$(s):($("master"),I(s==="detail"?m:null))):k!==null&&m!==k&&I(null),K&&S==="detail"&&$("master");const o=t=>{$(t),R(null)};E(()=>{e.selectionKey!==void 0&&c.current&&(c.current.scrollTop=0)},[e.selectionKey]);const x=t=>{w&&(T(t,B)?o("detail"):u!==null&&o(s))},A=()=>{w&&u!==null&&o(s)},H=()=>{w&&u!==null&&o("detail")},N=t=>{w&&(T(t,F)?o("master"):u!==null&&o("detail"))},b=h(null);E(()=>{const t=n=>{const l=n.target;if(!(l instanceof Node))return;let a=null;f.current?.contains(l)?a="master":c.current?.contains(l)&&(a="detail"),b.current={control:l,pane:a,left:!1}},i=()=>{const n=b.current;if(n===null||n.pane===null)return;const l=n.pane==="master"?f.current:c.current;!l||getComputedStyle(l).visibility==="hidden"||queueMicrotask(()=>{b.current===n&&n.control.isConnected&&(b.current={...n,left:!0})})};return document.addEventListener("focusin",t),document.addEventListener("focusout",i),()=>{document.removeEventListener("focusin",t),document.removeEventListener("focusout",i)}},[]);const O=t=>{const i=t==="detail"?"master":"detail",n=i==="master"?f.current:c.current,l=i==="master"?c.current:f.current;if(!n||!l)return;const a=document.activeElement,_=a===null||a===document.body||!a.isConnected,C=b.current,p=C!==null&&C.pane===i&&!C.left;(_?p:n.contains(a))&&getComputedStyle(n).visibility==="hidden"&&l.focus({preventScroll:!0})};return z(()=>{O(s)},[s]),E(()=>{const t=D.current;if(!t||typeof ResizeObserver>"u")return;const i=new ResizeObserver(()=>O(s));return i.observe(t),()=>i.disconnect()},[s]),g`
    <div class="md-container" ref=${D}>
      <div class=${`md-split ${e.className??""}`.trim()} data-pane=${s}>
        <div class="md-switch" role="group" aria-label="표시할 영역">
          <button
            type="button"
            class="md-switch-btn"
            aria-pressed=${s==="master"}
            onClick=${()=>o("master")}
          >${r}</button>
          <button
            type="button"
            class="md-switch-btn"
            aria-pressed=${s==="detail"}
            disabled=${K}
            onClick=${()=>o("detail")}
          >${L}</button>
        </div>
        <section
          ref=${f}
          class="md-master"
          tabindex="-1"
          aria-label=${r}
          onClick=${x}
          onKeyDown=${A}
        >
          ${e.master}
        </section>
        <section
          ref=${c}
          class="md-detail"
          tabindex="-1"
          aria-label=${L}
          onClickCapture=${N}
          onKeyDown=${H}
        >
          ${v?e.detail:e.emptyDetail??g`<div class="dtable-absent">항목을 선택하세요.</div>`}
        </section>
      </div>
    </div>
  `}export{J as M};
