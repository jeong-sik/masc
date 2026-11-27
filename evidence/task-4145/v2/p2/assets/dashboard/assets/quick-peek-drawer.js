import{d as v,A as r,y as $,_ as k,m as s}from"./vendor.js";import{v as g,h as C}from"./index.js";function p(){return typeof window>"u"||typeof window.matchMedia!="function"?!1:window.matchMedia("(min-width: 1440px)").matches}function M(e){const[a,f]=v(e.defaultWide??!1),[b,m]=v(p),h=r(null),o=r(null),d=r(null),u=r(null),y=r(e.onClose);y.current=e.onClose;const w=e.mode==="push"?"push":e.mode==="overlay"?"overlay":b?"push":"overlay",l=w==="overlay";return g({containerRef:o,active:e.open&&l,initialFocus:()=>{const n=typeof document<"u"?document.activeElement:null;return n&&o.current?.contains(n)?null:d.current},restoreFocus:!1}),$(()=>{u.current&&(u.current.scrollTop=0)},[e.title,e.subtitle,e.open]),$(()=>{if(typeof window>"u"||typeof window.matchMedia!="function")return;const n=window.matchMedia("(min-width: 1440px)"),t=i=>m(i.matches);return m(n.matches),n.addEventListener?.("change",t),()=>n.removeEventListener?.("change",t)},[]),k(()=>{if(!e.open)return;h.current=typeof document<"u"&&document.activeElement instanceof HTMLElement?document.activeElement:null,d.current?.focus?.();const n=t=>{if(!(t.defaultPrevented||t.isComposing||t.keyCode===229)){if(t.key==="Escape"){if(typeof document<"u"&&Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).some(c=>c!==o.current))return;t.preventDefault(),t.stopPropagation(),y.current();return}if(!t.metaKey&&!t.ctrlKey&&!t.altKey&&!t.shiftKey&&t.key.toLowerCase()==="z"){if(C(t.target)||typeof document<"u"&&Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).some(c=>c!==o.current))return;t.preventDefault(),f(i=>!i)}}};return window.addEventListener("keydown",n),()=>{window.removeEventListener("keydown",n),h.current?.focus?.()}},[e.open]),e.open?s`
    ${l&&s`
      <div
        class="qpeek-backdrop"
        aria-hidden="true"
        onClick=${e.onClose}
      />
    `}
    <aside
      ref=${o}
      class="qpeek"
      role=${l?"dialog":"complementary"}
      aria-modal=${l?"true":void 0}
      aria-label=${e.title}
      data-mode=${w}
      data-wide=${a?"true":"false"}
    >
      <header class="qpeek-head">
        <div>
          <h2 class="qpeek-title">${e.title}</h2>
          ${e.subtitle&&s`<div class="qpeek-sub">${e.subtitle}</div>`}
        </div>
        <div class="qpeek-actions">
          ${e.headerActions}
          <button
            type="button"
            class="btn-ghost"
            aria-pressed=${a?"true":"false"}
            aria-label=${a?"기본 너비로 축소":"넓게 보기"}
            title=${a?"기본 너비로 축소":"넓게 보기"}
            onClick=${()=>f(n=>!n)}
          >
            ⤢
          </button>
          <button
            ref=${d}
            type="button"
            class="btn-ghost"
            aria-label="닫기"
            onClick=${e.onClose}
          >
            ✕
          </button>
        </div>
      </header>
      <div ref=${u} class="qpeek-body">
        ${e.children}
      </div>
    </aside>
  `:null}export{M as QuickPeekDrawer};
