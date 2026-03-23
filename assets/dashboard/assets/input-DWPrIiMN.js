import{m as d}from"./index-BB0zaaHQ.js";function s(r){return r==="bad"||r==="offline"||r==="critical"||r==="risk"?"bad":r==="warn"||r==="pending"||r==="degraded"||r==="interrupted"||r==="watch"||r==="paused"||r==="blocked"?"warn":"ok"}function l(r){if(!r)return"warn";const e=r.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function p(r){const e=(r??"").trim().toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function f(r){if(!r)return"warn";const e=Date.parse(r);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}const u={ok:"tone-border-ok",warn:"tone-border-warn",bad:"tone-border-bad"};function b(r){return u[s(r)]??"tone-border-ok"}function w(r){const e=(r||"").toLowerCase();return e.includes("block")||e.includes("deny")||e.includes("closed")?"negative":e.includes("support")||e.includes("approve")||e.includes("ready")||e.includes("executed")||e.includes("done")?"positive":"neutral"}const i="w-full rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] focus:border-[rgba(71,184,255,0.5)] outline-none placeholder:text-[var(--text-muted)] transition-colors";function x({value:r,placeholder:e,disabled:n,class:t,onInput:a,onKeyDown:o}){return d`
    <input
      type="text"
      class="${i} px-3 py-2 text-[13px] ${t??""}"
      value=${r}
      placeholder=${e}
      disabled=${n}
      onInput=${a}
      onKeyDown=${o}
    />
  `}function v({value:r,placeholder:e,rows:n,class:t,onInput:a}){return d`
    <textarea
      class="${i} px-3 py-2 text-[13px] min-h-[80px] resize-y ${t??""}"
      placeholder=${e}
      rows=${n}
      value=${r}
      onInput=${a}
    ></textarea>
  `}export{v as T,b as a,x as b,l as c,f as e,w as g,p as s,s as t};
