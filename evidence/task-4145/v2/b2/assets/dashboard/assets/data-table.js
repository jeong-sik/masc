import{A as z,d as A,T as h,q as F,m as o}from"./vendor.js";import{c as L,u as P,f as x,t as K,s as B,r as q,b as G}from"./table.js";import{F as N}from"./index.js";import{u as O}from"./virtual-list.js";const U=K({rowSortingFeature:q,sortedRowModel:G(),sortFns:B});function k(t,l){if(t.cell)return t.cell(l);if(t.observed){const m=t.observed(l),$=N(m,t.formatValue);return m.kind==="absent"||m.kind==="unreported"?o`<span class="dtable-absent">${$}</span>`:$}const c=t.accessor?t.accessor(l):void 0;return c==null?o`<span class="dtable-absent">없음</span>`:t.formatValue?t.formatValue(c):String(c)}function _({col:t,row:l}){return o`${k(t,l)}`}function X(t){const l=z(null),[c,m]=A(()=>t.initialSort?[{id:t.initialSort.id,desc:t.initialSort.desc===!0}]:[]),$=t.virtualizeThreshold??80,C=t.estimateRowHeight??38,f=h(()=>{const e=new Map;for(const n of t.columns)e.set(n.id,n);return e},[t.columns]),R=h(()=>{const e=L();return t.columns.map(n=>e.accessor(i=>{if(n.sortValue)return n.sortValue(i);if(n.observed){const r=n.observed(i);return r.kind==="value"?r.data:null}return n.accessor?n.accessor(i):""},{id:n.id,header:n.header,enableSorting:n.sortable??!1,cell:i=>k(n,i.row.original)}))},[t.columns]),H=h(()=>[...t.data],[t.data]),y=P({features:U,data:H,columns:R,state:{sorting:c},onSortingChange:m,enableSortingRemoval:t.initialSort===void 0,getRowId:t.getRowId?(e,n)=>t.getRowId(e,n):void 0}),d=y.getRowModel().rows,g=d.length>$,b=t.columns.some(e=>e.width!==void 0),I=F(e=>d[e]?.id??e,[d]),{virtualItems:u,totalSize:T,measureElement:D}=O({count:g?d.length:0,getScrollElement:()=>l.current,estimateSize:()=>C,overscan:8,initialHeight:typeof t.maxHeight=="number"?t.maxHeight:480,getItemKey:I}),M=g?"window":"all",E=g?u.map(e=>({row:d[e.index],vi:e})):d.map(e=>({row:e,vi:null})),v=g&&u.length>0?u[0].start:0,w=g&&u.length>0?Math.max(0,T-u[u.length-1].end):0,V=t.maxHeight!==void 0?{maxHeight:typeof t.maxHeight=="number"?`${t.maxHeight}px`:t.maxHeight}:void 0;return o`
    <div class=${`dtable-wrap ${t.className??""}`.trim()}>
      <div ref=${l} class="dtable-scroll" style=${V}>
        <table class="dtable" data-sized=${b?"true":void 0}>
          ${t.caption&&o`<caption class="sr-only">${t.caption}</caption>`}
          ${b&&o`
            <colgroup>
              ${t.columns.map(e=>o`
                <col key=${e.id} style=${e.width!==void 0?{width:e.width}:void 0} />
              `)}
            </colgroup>
          `}
          <thead>
            ${y.getHeaderGroups().map(e=>o`
              <tr key=${e.id}>
                ${e.headers.map(n=>{const i=f.get(n.column.id),r=n.column.getCanSort(),a=n.column.getIsSorted(),s=a==="asc"?"ascending":a==="desc"?"descending":void 0,S=x(n.column.columnDef.header,n.getContext());return o`
                    <th
                      key=${n.id}
                      scope="col"
                      class=${i?.numeric?"is-num":""}
                      aria-sort=${s}
                      title=${b?i?.header:void 0}
                    >
                      ${r?o`
                            <button
                              type="button"
                              class="dtable-sort-btn"
                              onClick=${n.column.getToggleSortingHandler()}
                            >
                              <span class="dtable-sort-label">${S}</span>
                              <span aria-hidden="true">
                                ${a==="asc"?"▲":a==="desc"?"▼":"↕"}
                              </span>
                            </button>
                          `:S}
                    </th>
                  `})}
              </tr>
            `)}
          </thead>
          <tbody key=${M}>
            ${d.length===0?o`
                  <tr>
                    <td colspan=${Math.max(1,t.columns.length)} class="dtable-absent">
                      ${t.emptyLabel??"데이터 없음"}
                    </td>
                  </tr>
                `:o`
                  ${v>0&&o`
                    <tr aria-hidden="true">
                      <td colspan=${t.columns.length} style=${{height:`${v}px`,padding:0,border:"none"}} />
                    </tr>
                  `}
                  ${E.map(({row:e,vi:n})=>{const i=t.selectedRowId!=null&&e.id===t.selectedRowId,r=(a,s)=>a!==s&&a instanceof HTMLElement&&a.closest('button, a, input, select, textarea, [role="button"]')!==null;return o`
                      <tr
                        key=${e.id}
                        ref=${n?D:void 0}
                        data-index=${n?n.index:void 0}
                        data-selected=${i?"true":void 0}
                        tabIndex=${t.onRowClick?0:void 0}
                        onClick=${t.onRowClick?a=>{a.defaultPrevented||r(a.target,a.currentTarget)||t.onRowClick(e.original)}:void 0}
                        onKeyDown=${t.onRowClick?a=>{a.defaultPrevented||a.isComposing||a.keyCode===229||a.key!=="Enter"&&a.key!==" "||r(a.target,a.currentTarget)||(a.preventDefault(),t.onRowClick(e.original))}:void 0}
                      >
                        ${e.getAllCells().map(a=>{const s=f.get(a.column.id);return o`
                            <td
                              key=${a.id}
                              class=${s?.numeric?"is-num":""}
                              data-label=${s?.header??a.column.id}
                            >
                              ${s?o`<${_} col=${s} row=${e.original} />`:x(a.column.columnDef.cell,a.getContext())}
                            </td>
                          `})}
                      </tr>
                    `})}
                  ${w>0&&o`
                    <tr aria-hidden="true">
                      <td colspan=${t.columns.length} style=${{height:`${w}px`,padding:0,border:"none"}} />
                    </tr>
                  `}
                `}
          </tbody>
        </table>
      </div>
    </div>
  `}export{X as D};
