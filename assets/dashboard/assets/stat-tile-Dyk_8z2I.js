import{m as r}from"./index-BB0zaaHQ.js";const s={default:"bg-[var(--white-4)] border-[var(--card-border)] text-[var(--text-strong)]",gold:"bg-[rgba(200,168,78,0.05)] border-[var(--ff-gold-10)] text-[var(--text-strong)]",accent:"bg-[var(--accent-soft)] border-[rgba(71,184,255,0.2)] text-[var(--text-strong)]",warn:"bg-[rgba(230,167,0,0.06)] border-[rgba(230,167,0,0.2)] text-[var(--warn)]"},d={default:"text-[var(--text-muted)]",gold:"text-[var(--ff-gold)]",accent:"text-[var(--accent)]",warn:"text-[var(--warn)]"};function l({label:e,value:a,hint:t,variant:n="default"}){return r`
    <div class="flex flex-col items-center px-4 py-3 rounded-lg border ${s[n]}">
      <span class="text-base font-bold tabular-nums leading-tight">${a}</span>
      <span class="text-[length:var(--fs-2xs)] tracking-wider uppercase ${d[n]}">${e}</span>
      ${t?r`<span class="text-[length:var(--fs-2xs)] text-[var(--text-dim)] mt-0.5">${t}</span>`:null}
    </div>
  `}function g({items:e,cols:a=4}){return r`
    <div class="grid gap-3" style="grid-template-columns: repeat(${a}, 1fr)">
      ${e.map(t=>r`<${l} ...${t} />`)}
    </div>
  `}export{g as S};
