import{d as b,A as E,m as f}from"./vendor.js";const y="새로고침",a="읽는 중…",R="다시 누르면 처음부터 다시 읽습니다",h=400;function B(t){const[r,e]=b(!1),s=E(0),o=t.label??y,n=r||t.reading===!0,c=async()=>{s.current+=1;const u=s.current;e(!0);const l=new Promise(i=>{setTimeout(i,h)});try{await t.onRefresh()}finally{await l,s.current===u&&e(!1)}};return f`
    <button
      type="button"
      class="btn-ghost refresh-btn"
      aria-busy=${n}
      title=${n?R:void 0}
      data-label=${o}
      data-busy-label=${a}
      onClick=${()=>{c()}}
    >
      ${n?a:o}
    </button>
  `}export{B as R};
