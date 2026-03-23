import{m as a}from"./index-BB0zaaHQ.js";function o({chips:b,active:t,onChange:e}){return a`
    <div class="flex gap-1.5 flex-wrap">
      ${b.map(r=>a`
        <button
          key=${r.key}
          class="px-2.5 py-1 text-[length:var(--fs-xs)] rounded-xl border cursor-pointer transition-all duration-150 ${t.value===r.key?"border-[rgba(200,168,78,0.5)] bg-[rgba(200,168,78,0.12)] text-[#e8d48b]":"border-[var(--white-10)] bg-[var(--white-4)] text-[var(--text-dim)] hover:bg-[var(--white-8)] hover:border-[rgba(200,168,78,0.4)]"}"
          onClick=${()=>{t.value=r.key,e==null||e(r.key)}}
        >
          ${r.label}
        </button>
      `)}
    </div>
  `}export{o as F};
