import{A as W,m as s,ci as X,cj as Z,r as v,E as ee,C as V}from"./index-BB0zaaHQ.js";import{c as i,y as $,A as Y,d as te,q as z}from"./vendor-Chwn_OlE.js";const O=i(null),j=i(null),m=i(!1);async function U(){if(!m.value){m.value=!0,j.value=null;try{O.value=await X()}catch(e){j.value=e instanceof Error?e.message:String(e)}finally{m.value=!1}}}function ae(e){switch(e){case"essential":return"필수";case"standard":return"표준";default:return"전체"}}function se(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function re({items:e,maxCount:a}){return e.length===0?s`<p class="muted">아직 도구 호출 기록이 없습니다.</p>`:s`
    <div class="flex flex-col gap-1.5">
      ${e.map(r=>{const l=a>0?r.call_count/a*100:0;return s`
          <div class="tool-bar-row" key=${r.name}>
            <span class="text-[var(--text-body)] overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[11px]">${r.name}</span>
            <span class="px-1.5 py-px rounded-[3px] text-[10px] font-semibold text-center ${se(r.tier)}">${ae(r.tier)}</span>
            <div class="h-3.5 rounded-[3px] bg-[var(--white-6)] overflow-hidden">
              <div class="h-full rounded-[3px] bg-[var(--accent)] min-w-0.5 transition-[width] duration-300 ease-in-out" style=${{width:`${l}%`}} />
            </div>
            <span class="text-[var(--text-muted)] text-[11px] text-right font-mono">${r.call_count}</span>
          </div>
        `})}
    </div>
  `}function ne({dist:e}){const a=e.total??e.full??0,r=e.essential??0,l=e.standard_only??e.standard??0,o=e.full_only??a-l,p=a>0?(r/a*100).toFixed(1):"0",n=a>0?(l/a*100).toFixed(1):"0",c=a>0?(o/a*100).toFixed(1):"0";return s`
    <div class="flex flex-col gap-2">
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-essential">필수</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${r}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${p}%</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-standard">표준</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${l}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${n}%</span>
      </div>
      <div class="flex items-center gap-3">
        <span class="inline-block min-w-[72px] px-2 py-0.5 text-[11px] font-semibold text-center rounded badge-full">전체 전용</span>
        <span class="text-[var(--text-strong)] text-sm font-semibold min-w-9 text-right">${o}</span>
        <span class="text-[var(--text-muted)] text-[13px] min-w-12 text-right">${c}%</span>
      </div>
    </div>
  `}function le(){const e=O.value,a=m.value,r=j.value;return $(()=>{!O.value&&!m.value&&U()},[]),s`
    <div class="flex flex-col gap-4">
      <div class="flex justify-between items-center">
        <h3 class="text-[var(--text-strong)] text-lg font-semibold m-0">도구 사용 현황</h3>
        <${W}
          variant="ghost"
          onClick=${()=>void U()}
          disabled=${a}
        >
          ${a?"불러오는 중...":e?"새로고침":"불러오기"}
        <//>
      </div>

      ${r?s`<div class="px-2.5 py-3 bg-[var(--bad-12)] border border-[rgba(239,68,68,0.34)] text-[#fecaca] text-base rounded-lg">${r}</div>`:null}

      ${e?s`
        <div class="grid grid-cols-[repeat(5,minmax(0,1fr))] gap-3 max-[880px]:grid-cols-[repeat(2,minmax(0,1fr))]">
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${e.total_calls}</span>
            <span class="stat-label">총 호출 수</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${e.distinct_tools_called}</span>
            <span class="stat-label">사용된 도구</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${e.never_called_count}</span>
            <span class="stat-label">미사용 도구</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${e.registered_count}</span>
            <span class="stat-label">등록됨 (v2)</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${e.dispatch_v2_enabled?"ON":"OFF"}</span>
            <span class="stat-label">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div>
            <h4 class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.05em] mb-2.5 mt-0">계층 분포</h4>
            <${ne} dist=${e.tier_distribution} />
          </div>
          <div>
            <h4 class="text-[var(--text-muted)] text-[11px] uppercase tracking-[0.05em] mb-2.5 mt-0">상위 20 도구</h4>
            <${re}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:a?null:s`
        <p class="muted">불러오기를 눌러 도구 사용 통계를 확인하세요.</p>
      `}
    </div>
  `}const q=i(null),R=i(null),h=i(!1),w=i(""),y=i("all"),F=i(!1),S=i(!1),M=i(!0),A=i(!0),_=i("all"),K={public_mcp:["public_mcp"],agent:["spawned_agent_mcp"],keeper:["keeper_standard","keeper_privileged"],internal:["local_worker","mdal_auditable","privileged_executor"]},H={all:"전체",public_mcp:"MCP 공개",agent:"에이전트",keeper:"키퍼",internal:"내부"};async function G(){if(!h.value){h.value=!0,R.value=null;try{q.value=await Z()}catch(e){R.value=e instanceof Error?e.message:String(e)}finally{h.value=!1}}}function oe(e,a){const r=a.trim().toLowerCase();return r?[e.name,e.description,e.category,e.required_permission??"",e.visibility,e.lifecycle,e.implementationStatus,e.tier,e.canonicalName??"",e.replacement??"",e.reason??"",...e.doc_refs,...e.prompt_hints,...e.surfaces??[]].join(" ").toLowerCase().includes(r):!0}function u(e,a="default"){return s`
    <span class="text-[11px] rounded-full px-2 py-0.5 ${a==="ok"?"text-[#7dd3fc] bg-[rgba(14,165,233,0.18)]":a==="warn"?"text-[var(--warn)] bg-[var(--warn-12)]":a==="surface"?"text-[#c4b5fd] bg-[rgba(139,92,246,0.18)]":"text-[var(--text-muted)] bg-[var(--white-8)]"}">
      ${e}
    </span>
  `}function ce(e,a){if(a==="all")return e.length;const r=K[a];return e.filter(l=>(l.surfaces??[]).some(o=>r.includes(o))).length}const Q=i(!1),g=i(!1);function de({inventory:e}){const a=e.filter(n=>n.tier==="essential"&&n.enabled_in_current_mode).slice(0,10),r=e.filter(n=>n.lifecycle!=="deprecated"&&n.visibility!=="hidden").slice(-5).reverse(),l=e.length,o=e.filter(n=>n.enabled_in_current_mode).length,p=e.filter(n=>n.lifecycle==="deprecated").length;return s`
    <div class="py-2">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3 my-4">
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${l}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">전체 도구</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${o}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">활성화됨</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${p}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">폐기 예정</span>
        </div>
      </div>

      ${a.length>0?s`
        <div class="mt-5">
          <h4 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">필수 도구 (상위 ${a.length}개)</h4>
          <div class="flex flex-col">
            ${a.map(n=>{var c;return s`
              <div class="flex items-center gap-3 py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded" key=${n.name}>
                <span class="text-[13px] font-medium text-[var(--text-strong)] min-w-[180px] shrink-0">${n.name}</span>
                <span class="text-[12px] text-[var(--text-muted)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${((c=n.description)==null?void 0:c.slice(0,60))??""}</span>
                ${(n.surfaces??[]).map(f=>u(f,"surface"))}
              </div>
            `})}
          </div>
        </div>
      `:null}

      ${r.length>0?s`
        <div class="mt-5">
          <h4 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-3">미사용 도구 (${r.length}개)</h4>
          <div class="flex flex-col">
            ${r.map(n=>{var c;return s`
              <div class="flex items-center gap-3 py-2.5 border-b border-[var(--white-4)] hover:bg-[var(--white-3)] transition-colors px-2 rounded" key=${n.name}>
                <span class="text-[13px] font-medium text-[var(--text-strong)] min-w-[180px] shrink-0">${n.name}</span>
                <span class="text-[12px] text-[var(--text-muted)] flex-1 overflow-hidden text-ellipsis whitespace-nowrap">${((c=n.description)==null?void 0:c.slice(0,60))??""}</span>
                ${u(n.category)}
              </div>
            `})}
          </div>
        </div>
      `:null}
    </div>
  `}const ie=40;function pe({items:e,itemHeight:a,overscan:r=5,renderItem:l,getKey:o,className:p=""}){const n=Y(null),[c,f]=te({start:0,end:30}),b=e.length>ie;if($(()=>{if(!b)return;const t=n.current;if(!t)return;let d=!1;const x=()=>{const{scrollTop:I,clientHeight:J}=t,N=Math.max(0,Math.floor(I/a)-r),P=Math.min(e.length,Math.ceil((I+J)/a)+r);f(L=>L.start===N&&L.end===P?L:{start:N,end:P})};let E=!1;const B=()=>{E||d||(E=!0,requestAnimationFrame(()=>{d||x(),E=!1}))},D=new ResizeObserver(()=>{d||x()});return x(),t.addEventListener("scroll",B,{passive:!0}),D.observe(t),()=>{d=!0,t.removeEventListener("scroll",B),D.disconnect()}},[b,e.length,a,r]),!b)return s`
      <div class=${p}>
        ${e.map((t,d)=>l(t,d))}
      </div>
    `;const k=e.length*a,C=c.start*a,T=e.slice(c.start,c.end);return s`
    <div ref=${n} class=${p}>
      <div class="virtual-list-spacer" style=${{height:`${k}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${C}px)`}}
        >
          ${T.map((t,d)=>{const x=c.start+d;return s`<div key=${o(t)}>${l(t,x)}</div>`})}
        </div>
      </div>
    </div>
  `}function xe({item:e}){return s`
    <article class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <div class="flex justify-between gap-3 items-start">
        <div>
          <div class="text-[15px] font-bold text-[var(--text-strong)]">${e.name}</div>
          <div class="tool-inventory-desc text-[12px] text-[var(--text-muted)] mt-0.5">${e.description}</div>
        </div>
        <div class="flex flex-wrap gap-1.5 justify-end">
          ${(e.surfaces??[]).map(a=>u(a,"surface"))}
          ${u(e.tier,e.tier==="essential"?"ok":e.tier==="standard"?"warn":"default")}
          ${u(e.visibility)}
          ${u(e.lifecycle,e.lifecycle==="deprecated"?"warn":"default")}
          ${u(e.implementationStatus)}
        </div>
      </div>
      <div class="flex flex-wrap gap-3 text-[12px] text-[var(--text-muted)] mt-2">
        <span>카테고리: <strong class="text-[var(--text-body)]">${e.category}</strong></span>
        <span>모드: <strong class="text-[var(--text-body)]">${e.enabled_in_current_mode?"활성":"비활성"}</strong></span>
        <span>직접 호출: <strong class="text-[var(--text-body)]">${e.direct_call_allowed?"허용":"차단"}</strong></span>
        <span>권한: <strong class="text-[var(--text-body)]">${e.required_permission??"없음"}</strong></span>
      </div>
      ${e.reason?s`<div class="tool-inventory-reason text-[12px] text-[var(--text-muted)] mt-1.5">${e.reason}</div>`:null}
      <div class="flex flex-wrap gap-3 text-[12px] text-[var(--text-muted)] mt-1.5">
        ${e.canonicalName?s`<span>정식 이름: <strong class="text-[var(--text-body)]">${e.canonicalName}</strong></span>`:null}
        ${e.replacement?s`<span>대체 도구: <strong class="text-[var(--text-body)]">${e.replacement}</strong></span>`:null}
        ${e.doc_refs.length>0?s`<span>문서: <strong class="text-[var(--text-body)]">${e.doc_refs.join(", ")}</strong></span>`:null}
      </div>
    </article>
  `}function ue({inventory:e,loading:a,error:r}){const l=Y(null);$(()=>{var d;if(v.value.tab!=="lab"||v.value.params.section!=="tools")return;const t=(d=v.value.params.q)==null?void 0:d.trim();w.value=t??""},[v.value.tab,v.value.params.section,v.value.params.q]);const o=z(()=>{const t=l.current;t&&(Q.value=t.scrollTop>500)},[]);$(()=>{const t=l.current;if(t)return t.addEventListener("scroll",o,{passive:!0}),()=>t.removeEventListener("scroll",o)},[o]);const p=z(()=>{const t=l.current;t&&t.scrollTo({top:0,behavior:"smooth"})},[]),n=Array.from(new Set(e.map(t=>t.category))).sort((t,d)=>t.localeCompare(d)),c=e.filter(t=>{if(!oe(t,w.value)||y.value!=="all"&&t.category!==y.value||F.value&&!t.enabled_in_current_mode||S.value&&!t.direct_call_allowed||!M.value&&t.visibility==="hidden"||!A.value&&t.lifecycle==="deprecated")return!1;if(_.value!=="all"){const d=K[_.value];if(!(t.surfaces??[]).some(x=>d.includes(x)))return!1}return!0}),f=e.length,b=e.filter(t=>t.enabled_in_current_mode).length,k=e.filter(t=>t.visibility==="hidden").length,C=e.filter(t=>t.lifecycle==="deprecated").length,T=e.filter(t=>t.direct_call_allowed).length;return s`
    <div class="sticky top-[var(--header-h)] z-[var(--z-tab-sticky)] bg-[rgba(11,18,32,0.95)] backdrop-blur-[8px] py-3 border-b border-[var(--card-border)]">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3 my-4">
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${f}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">전체 도구</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${b}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">활성화됨</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${k}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">숨김</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${C}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">지원 중단</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${T}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">직접 호출</span>
        </div>
        <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col gap-1.5">
          <span class="text-[var(--text-strong)] text-[28px] font-bold leading-none tabular-nums">${c.length}</span>
          <span class="text-[11px] text-[var(--text-muted)] uppercase tracking-wider font-medium">필터 결과</span>
        </div>
      </div>

      <div class="flex flex-wrap gap-2 mb-4">
        ${Object.keys(H).map(t=>s`
          <button
            class=${`px-3 py-1.5 rounded-lg text-[13px] font-medium border transition-colors cursor-pointer ${_.value===t?"border-[var(--accent)]/40 text-[var(--accent)] bg-[var(--accent-8)]":"border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] text-[var(--text-body)]"}`}
            onClick=${()=>{_.value=t}}
          >
            ${H[t]}
            <span class="inline-flex items-center justify-center min-w-5 h-[18px] px-[5px] text-[10px] font-semibold bg-[var(--white-8)] text-[var(--text-muted)] rounded-full ml-1">${ce(e,t)}</span>
          </button>
        `)}
      </div>

      <div class="flex flex-wrap gap-3 items-center">
        <input
          class="w-full px-3 py-2 rounded-lg bg-[var(--white-3)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] focus:border-[var(--accent)]/50 outline-none max-w-[320px]"
          type="text"
          placeholder="도구, 문서, 권한, 대체 도구 검색..."
          value=${w.value}
          onInput=${t=>{w.value=t.target.value}}
        />
        <select
          class="px-3 py-2 rounded-lg bg-[var(--white-3)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] focus:border-[var(--accent)]/50 outline-none"
          value=${y.value}
          onChange=${t=>{y.value=t.target.value}}
        >
          <option value="all">전체 카테고리</option>
          ${n.map(t=>s`<option value=${t}>${t}</option>`)}
        </select>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${F.value}
            onChange=${t=>{F.value=t.target.checked}}
          />
          <span>활성화만</span>
        </label>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${S.value}
            onChange=${t=>{S.value=t.target.checked}}
          />
          <span>직접 호출만</span>
        </label>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${M.value}
            onChange=${t=>{M.value=t.target.checked}}
          />
          <span>숨김 표시</span>
        </label>
        <label class="inline-flex items-center gap-2 text-[12px] text-[var(--text-body)]">
          <input
            type="checkbox"
            checked=${A.value}
            onChange=${t=>{A.value=t.target.checked}}
          />
          <span>지원 중단 표시</span>
        </label>
        <button
          class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)]"
          onClick=${()=>{G()}}
          disabled=${a}
        >
          ${a?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>

    ${r?s`<div class="px-3 py-2.5 bg-[var(--bad-12)] border border-[var(--bad-30)] text-[#fecaca] text-[13px] rounded-lg mt-2">${r}</div>`:null}

    <div ref=${l} class="overflow-y-auto max-h-[calc(100vh-420px)] min-h-[300px]">
      ${c.length>0?s`<${pe}
            items=${c}
            itemHeight=${130}
            renderItem=${t=>s`<${xe} item=${t} />`}
            getKey=${t=>t.name}
            className="flex flex-col gap-3"
          />`:s`<${ee} message="조건에 맞는 도구가 없습니다." compact />`}
    </div>

    <button
      class=${`tool-back-to-top${Q.value?" visible":""}`}
      onClick=${p}
      title="맨 위로"
    >
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <path d="M10 15V5M10 5L5 10M10 5L15 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </button>
  `}function be(){const e=q.value,a=h.value,r=R.value,l=(e==null?void 0:e.tool_inventory.tools)??[],o=(e==null?void 0:e.tool_usage)??null;return $(()=>{!q.value&&!h.value&&G()},[]),s`
    <div>
      <${V} title="시스템 도구 목록" class="section mb-4">
        <div class="mb-4">
          <h2 class="text-sm font-semibold text-[var(--text-strong)] uppercase tracking-wider mb-1">시스템 도구 목록</h2>
          <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">
            ${g.value?"hidden/deprecated 포함 전체 도구 surface를 봅니다.":"필수 도구와 사용 현황 요약입니다."}
          </p>
          <button
            class="px-3 py-1.5 rounded-lg text-[13px] font-medium border border-[var(--card-border)] bg-[var(--white-4)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-[var(--text-body)] mt-2"
            onClick=${()=>{g.value=!g.value}}
          >
            ${g.value?"요약 보기":"전체 인벤토리 보기"}
          </button>
        </div>

        ${g.value?s`<${ue}
              inventory=${l}
              loading=${a}
              error=${r}
            />`:s`<${de} inventory=${l} />`}
      <//>

      <${V} title="도구 사용 현황" class="section mb-4">
        ${o?s`
              <div class="text-[12px] text-[var(--text-muted)] mb-2">
                등록됨 ${o.registered_count} · 사용된 ${o.distinct_tools_called} · 미사용 ${o.never_called_count}
              </div>
            `:null}
        <${le} />
      <//>
      ${e!=null&&e.generated_at?s`<div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[12px]">
            <span>생성 시각: ${e.generated_at}</span>
            <span>metrics 기준: 최근 1시간</span>
          </div>`:null}
    </div>
  `}export{be as Tools,G as refreshTools};
