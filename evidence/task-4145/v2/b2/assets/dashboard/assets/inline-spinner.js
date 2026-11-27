import{m as c}from"./vendor.js";function d(e="sm"){switch(e){case"xs":return"h-2.5 w-2.5 border-2";case"sm":return"h-3 w-3 border-2";case"md":return"h-4 w-4 border-2"}}function h(e="accent"){return e==="accent"?"border-[var(--color-accent-fg)] border-t-transparent":"border-[var(--color-fg-disabled)] border-t-transparent"}const m="inline-block rounded-full animate-spin shrink-0";function p(e="sm",a="accent",i){const s=[m,d(e),h(a)];return i!==void 0&&i!==""&&s.push(i),s.join(" ")}function r(e){const a=e?.trim();return a===void 0||a===""?void 0:a}function u({size:e="sm",tone:a="accent",className:i,ariaLabel:s,testId:t}){const n=r(s);return{size:e,tone:a,hasSemanticLabel:n!==void 0,hasCustomClass:i!==void 0&&i!=="",hasTestId:t!==void 0&&t!=="",ariaLabelLength:n?.length??0,classNameLength:i?.length??0,testIdLength:t?.length??0}}function g({size:e="sm",tone:a="accent",class:i,ariaLabel:s,testId:t}){const n=u({size:e,tone:a,className:i,ariaLabel:s,testId:t}),l=r(s),o=p(e,a,i);return c`<span
    class=${o}
    role=${n.hasSemanticLabel?"status":void 0}
    aria-label=${l}
    aria-hidden=${n.hasSemanticLabel?void 0:"true"}
    data-inline-spinner
    data-inline-spinner-size=${n.size}
    data-inline-spinner-tone=${n.tone}
    data-inline-spinner-has-semantic-label=${n.hasSemanticLabel}
    data-inline-spinner-has-custom-class=${n.hasCustomClass}
    data-inline-spinner-has-test-id=${n.hasTestId}
    data-inline-spinner-aria-label-length=${n.ariaLabelLength}
    data-inline-spinner-class-length=${n.classNameLength}
    data-inline-spinner-test-id-length=${n.testIdLength}
    data-testid=${t}
  ></span>`}export{g as I};
