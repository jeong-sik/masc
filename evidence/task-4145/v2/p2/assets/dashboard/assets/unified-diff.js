import{m as t}from"./vendor.js";function l(a){return a.startsWith("+")&&!a.startsWith("+++")?"add":a.startsWith("-")&&!a.startsWith("---")?"del":a.startsWith("@@")?"hunk":"ctx"}function c(a){if(!a.diffText)return a.inline?t`<span class="kp-diff-line">${a.emptyLabel??"(변경 사항 없음)"}</span>`:t`<pre class="mono" data-testid=${a.testId}>${a.emptyLabel??"(변경 사항 없음)"}</pre>`;const n=a.diffText.split(`
`),r=a.maxLines!==void 0&&n.length>a.maxLines,d=r?n.slice(0,a.maxLines):n;return a.inline?t`${d.map((i,s)=>t`<span key=${s} class="kp-diff-line" data-kind=${l(i)}>${i}</span>`)}`:t`
    <pre
      class="mono"
      data-testid=${a.testId}
      style=${{margin:0,padding:a.padding??"var(--sp-3)",background:"var(--bg-0)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",fontSize:"var(--fs-11)",overflowX:"auto",lineHeight:1.45}}
    >
      ${d.map((i,s)=>{const e=l(i);return t`<span key=${s} style=${e==="add"?{display:"block",background:"var(--ok-soft)",color:"var(--ok-fg)"}:e==="del"?{display:"block",background:"var(--err-soft)",color:"var(--err-fg)"}:e==="hunk"?{display:"block",color:"var(--info-fg)"}:{display:"block",color:"var(--fg-2)"}}>${i}</span>`})}
      ${r&&t`
        <span style=${{display:"block",color:"var(--fg-3)",marginTop:"var(--sp-1)"}}>
          … (${n.length-(a.maxLines??0)}줄 생략 · [⤢] 전체 보기 클릭)
        </span>
      `}
    </pre>
  `}export{c as U,l as c};
