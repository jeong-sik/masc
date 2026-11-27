import{A as o,q as m,m as u,d as S,_ as g}from"./vendor.js";import{V as $,o as z,e as E,a as I}from"./table.js";const b=Object.freeze({height:"100%"});function x(e,r,t){const s=t.indexFromElement(e),i=t.itemSizeCache.get(t.options.getItemKey(s));if(!r&&i!==void 0)return i;const n=r?.borderBoxSize[0]?.blockSize??e.getBoundingClientRect().height;return n>0?n:i??t.options.estimateSize(s)}function R(e,r){return I(e,t=>{t.height>0&&r(t)})}function K(e){const[,r]=S(0),t=o(null),s={count:e.count,getScrollElement:e.getScrollElement,estimateSize:e.estimateSize,overscan:e.overscan??6,initialRect:{width:0,height:e.initialHeight??480},scrollToFn:E,measureElement:x,observeElementRect:R,observeElementOffset:z,...e.getItemKey?{getItemKey:e.getItemKey}:{},onChange:()=>{r(n=>(n+1)%1e6)}};t.current?t.current.setOptions(s):t.current=new $(s);const i=t.current;return g(()=>i._didMount(),[i]),g(()=>{i._willUpdate()}),{virtualItems:i.getVirtualItems(),totalSize:i.getTotalSize(),scrollToIndex:(n,a)=>i.scrollToIndex(n,a),scrollToOffset:(n,a)=>i.scrollToOffset(n,a),measureElement:i.measureElement}}function V(e){const r=o(null),t=o(e.estimateSize);t.current=e.estimateSize;const s=o(e.items);s.current=e.items;const i=o(e.getItemKey);i.current=e.getItemKey;const n=m(()=>r.current,[]),a=m(l=>{const c=t.current;return typeof c=="function"?c(l):c},[]),h=m(l=>i.current(s.current[l],l),[]),{virtualItems:d,totalSize:f,measureElement:v}=K({count:e.items.length,getScrollElement:n,estimateSize:a,overscan:e.overscan,initialHeight:typeof e.height=="number"?e.height:480,getItemKey:e.getItemKey?h:void 0});if(e.items.length===0&&e.empty!==void 0)return u`<div class=${e.className??""}>${e.empty}</div>`;const y=e.height==="100%"?b:e.height!==void 0?{height:typeof e.height=="number"?`${e.height}px`:e.height}:void 0;return u`
    <div
      ref=${r}
      class=${`vlist ${e.className??""}`.trim()}
      role="list"
      aria-label=${e.ariaLabel}
      style=${y}
    >
      <div class="vlist-inner" style=${{height:`${f}px`}}>
        ${d.map(l=>{const c=e.items[l.index];return c===void 0?null:u`
            <div
              key=${String(l.key)}
              ref=${v}
              role="listitem"
              class="vlist-row"
              data-index=${l.index}
              style=${{transform:`translateY(${l.start}px)`}}
            >
              ${e.renderItem(c,l.index)}
            </div>
          `})}
      </div>
    </div>
  `}export{V,K as u};
