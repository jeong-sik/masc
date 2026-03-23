import{m as a,L as Ft,r as Z,q as O,E as x,M as vt,C as b,N as P,O as re,G as k,P as Q,Q as Lt,T as $,R as Ot,S as _,U as ae,V as qt,W as ne,X as se,Y as oe,Z as V,$ as de,a0 as q,a1 as le,a2 as ie,a3 as ce,a4 as I,a5 as f,a6 as Tt,a7 as ue,a8 as z,a9 as Nt,aa as pe,ab as Gt,ac as xe,ad as ve,ae as dt,af as lt,ag as be,ah as ge,ai as it,aj as me,ak as fe}from"./index-BB0zaaHQ.js";import{c as v,d as H,y as Vt,b as ft}from"./vendor-Chwn_OlE.js";import{L as X}from"./feedback-state-DiW1_ueY.js";import"./helpers-Bd2DyH_v.js";import{S as It}from"./status-chip-B-Vgmq3f.js";import{F as Et}from"./filter-chips-Cu5kYIK3.js";function $e({text:t}){if(!t)return null;const e=he(t);return a`<div class="markdown-content">${e}</div>`}function he(t){const e=t.split(`
`),n=[];let r=0;for(;r<e.length;){const s=e[r];if(/^(`{3,}|~{3,})/.test(s)){const o=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(o.length).trim(),l=[];for(r++;r<e.length&&!e[r].startsWith(o);)l.push(e[r]),r++;r++,n.push(a`<pre><code class=${u?`language-${u}`:""}>${l.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const o=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&o.push(u),r++;r<e.length&&!e[r].includes("</think>");)o.push(e[r]),r++;if(r<e.length){const c=e[r].replace("</think>","").trim();c&&o.push(c),r++}const l=o.join(`
`).trim();n.push(a`
        <details class="think-block rounded-lg">
          <summary>Thinking...</summary>
          <div>${ct(l)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const o=[];for(;r<e.length&&e[r].startsWith("> ");)o.push(e[r].slice(2)),r++;n.push(a`<blockquote>${ct(o.join(`
`))}</blockquote>`);continue}if(s.trim()===""){r++;continue}const d=[];for(;r<e.length;){const o=e[r];if(o.trim()===""||/^(`{3,}|~{3,})/.test(o)||o.startsWith("> ")||o.trim().startsWith("<think>"))break;d.push(o),r++}d.length>0&&n.push(a`<p>${ct(d.join(`
`))}</p>`)}return n}function ct(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let r=0,s;for(;(s=n.exec(t))!==null;){if(s.index>r&&e.push(t.slice(r,s.index)),s[1]){const d=s[1].slice(1,-1);e.push(a`<code>${d}</code>`)}else if(s[2]){const d=s[2].slice(2,-2);e.push(a`<strong>${d}</strong>`)}else if(s[3]){const d=s[3].slice(1,-1);e.push(a`<em>${d}</em>`)}else s[4]&&s[5]&&e.push(a`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);r=s.index+s[0].length}return r<t.length&&e.push(t.slice(r)),e.length>0?e:[t]}const Ht=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],J=v(null),K=v([]),R=v(!1),y=v(null),S=v(""),L=v(!1),T=v(!0),U=v(!1),E=v(""),j=v(""),Y=v(!1),$t=20,A=v($t);function we(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Jt=v(we());function ye(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function _e(t){return t.updated_at!==t.created_at}function ke(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Ce(t){return t==="team-session"}function W(t){return t.post_kind?t.post_kind:Ce(t.author)?"system":ke(t)?"automation":"human"}function Kt(t){const e=[],n=[];let r=0;return t.forEach(s=>{const d=W(s);if(!(d==="system"&&P.value)){if(d==="automation"&&T.value){r+=1;return}if(d==="human"){e.push(s);return}n.push(s)}}),{human:e,operations:n,hiddenAutomation:r}}function Ae(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?a`<span class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] tracking-wide uppercase bg-[var(--bad-15)] text-[var(--bad-light)] border border-[var(--bad-30)]">만료됨</span>`:a`<span class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] tracking-wide uppercase bg-[var(--warn-15)] text-[var(--warn)] border border-[var(--warn-30)]">만료까지 <${$} timestamp=${t.expires_at} /></span>`:null}function ht(t){const e=["🤖","🧑‍💻","🦊","🐙","🔮","🧪","⚡","🎯","🛸","🧠","🦉","🐺","🎲","🌊","🔥"];let n=0;for(let r=0;r<t.length;r++)n=(n<<5)-n+t.charCodeAt(r)|0;return e[Math.abs(n)%e.length]??"🤖"}function Ut(t){switch(t){case"automation":return"bg-[var(--cyan-16)] text-[#38bdf8] border-[rgba(34,211,238,0.3)]";case"system":return"bg-[var(--slate-gray-15)] text-[var(--text-slate)] border-[var(--border-slate-22)]";default:return"bg-[var(--white-8)] text-[var(--text-muted)] border-[var(--border-slate-16)]"}}async function wt(t){y.value=t,J.value=null,K.value=[],R.value=!0;try{const e=await re(t);if(y.value!==t)return;J.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},K.value=e.comments??[]}catch(e){console.warn("[Board] failed to load post detail:",t,e),y.value===t&&(J.value=null,K.value=[],k("글을 불러오는 데 실패했습니다","error"))}finally{y.value===t&&(R.value=!1)}}async function jt(t){const e=S.value.trim();if(e){L.value=!0;try{await se(t,Jt.value,e),S.value="",k("댓글을 등록했습니다","success"),await wt(t),_()}catch{k("댓글 등록에 실패했습니다","error")}finally{L.value=!1}}}async function Pe(){const t=E.value.trim(),e=j.value.trim();if(!(!t||!e)){Y.value=!0;try{await ne(t,e,Jt.value),E.value="",j.value="",U.value=!1,k("글을 등록했습니다","success"),_()}catch{k("글 등록에 실패했습니다","error")}finally{Y.value=!1}}}function Se(){return U.value?a`
    <div class="p-4 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] grid gap-3">
      <input
        class="w-full px-3 py-2 rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-[14px] font-medium focus:border-[rgba(71,184,255,0.5)] outline-none placeholder:text-[var(--text-muted)]"
        type="text"
        placeholder="제목"
        value=${E.value}
        onInput=${t=>{E.value=t.target.value}}
      />
      <textarea
        class="w-full px-3 py-2 rounded-lg bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-[13px] min-h-[80px] resize-y focus:border-[rgba(71,184,255,0.5)] outline-none placeholder:text-[var(--text-muted)]"
        placeholder="내용을 입력하세요..."
        value=${j.value}
        onInput=${t=>{j.value=t.target.value}}
      ></textarea>
      <div class="flex gap-2 justify-end">
        <button
          class="px-3 py-1.5 rounded-lg text-[13px] border border-[var(--card-border)] bg-transparent text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]"
          onClick=${()=>{U.value=!1,E.value="",j.value=""}}
        >취소</button>
        <button
          class="px-4 py-1.5 rounded-lg text-[13px] font-medium border border-[rgba(71,184,255,0.4)] bg-[var(--accent-soft)] text-[var(--accent)] cursor-pointer hover:bg-[rgba(71,184,255,0.2)] disabled:opacity-50"
          disabled=${Y.value||!E.value.trim()||!j.value.trim()}
          onClick=${()=>{Pe()}}
        >${Y.value?"등록 중...":"등록"}</button>
      </div>
    </div>
  `:a`
      <button
        class="w-full py-2.5 rounded-lg border border-dashed border-[var(--card-border)] text-[13px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-4)] hover:text-[var(--text-body)] transition-colors bg-transparent"
        onClick=${()=>{U.value=!0}}
      >+ 새 글 작성</button>
    `}function Le(){const t=Q.value,e=T.value?"자동화 글 숨김":"자동화 글 표시 중";return a`
    <div class="flex flex-col gap-3 mb-4 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
      <div class="flex items-center gap-1.5 flex-wrap">
        ${Ht.map(n=>a`
          <button
            class="px-3 py-1.5 rounded-lg text-[12px] font-medium transition-all duration-150 border cursor-pointer
              ${t===n.id?"bg-[var(--ok-soft)] text-[var(--ok)] border-[var(--ok-30)]":"bg-transparent text-[var(--text-muted)] border-transparent hover:bg-[var(--white-8)] hover:text-[var(--text-body)]"}"
            onClick=${()=>{Q.value=n.id,A.value=$t,_()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="flex items-center gap-2 flex-wrap">
        <button
          class="px-2.5 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer
            ${T.value?"bg-[var(--accent-12)] text-[var(--accent)] border-[var(--accent-18)]":"bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]"}"
          onClick=${()=>{T.value=!T.value}}
        >
          ${e}
        </button>
        <button
          class="px-2.5 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer
            ${P.value?"bg-[var(--accent-12)] text-[var(--accent)] border-[var(--accent-18)]":"bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)]"}"
          onClick=${()=>{P.value=!P.value,_()}}
        >
          ${P.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <div class="ml-auto">
          <button
            class="px-3 py-1 rounded-lg text-[11px] font-medium transition-all duration-150 border cursor-pointer bg-transparent text-[var(--text-muted)] border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] disabled:opacity-50 disabled:cursor-not-allowed"
            onClick=${_}
            disabled=${vt.value}
          >
            ${vt.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>
    </div>
  `}function ut(){var r;const t=((r=Ht.find(s=>s.id===Q.value))==null?void 0:r.label)??Q.value,e=Kt(Ft.value),n=e.human.length+e.operations.length;return a`
    <div class="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-3 mb-4">
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">보이는 글</span>
        <strong class="text-xl font-semibold text-[var(--text-strong)] tabular-nums">${n}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">정렬</span>
        <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${t}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">잡음 필터</span>
        <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${T.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">시스템 글 정책</span>
        <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${P.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="flex flex-col gap-1.5 p-4 rounded-xl border border-[var(--card-border)] bg-[var(--card)]">
        <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">최근 갱신</span>
        <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${Lt.value?a`<${$} timestamp=${Lt.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Rt({post:t}){const e=W(t),n=async(r,s)=>{s.stopPropagation();try{await qt(t.id,r),_()}catch{k("투표에 실패했습니다","error")}};return a`
    <div
      class="board-post group flex gap-3 rounded-xl p-4 border border-[var(--card-border)] bg-[var(--card)] hover:bg-[var(--white-6)] hover:border-[rgba(71,184,255,0.26)] transition-all duration-200 cursor-pointer"
      onClick=${()=>ae(t.id)}
    >
      <!-- Vote column -->
      <div class="flex flex-col items-center gap-0.5 pt-0.5 min-w-[36px]">
        <button
          class="vote-btn upvote w-7 h-5 flex items-center justify-center rounded text-[11px] text-[var(--text-muted)] hover:text-[#ff4500] hover:bg-[rgba(255,69,0,0.1)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${r=>n("up",r)}
        >▲</button>
        <span class="text-[13px] font-semibold tabular-nums text-[var(--text-strong)]">${t.votes??0}</span>
        <button
          class="vote-btn downvote w-7 h-5 flex items-center justify-center rounded text-[11px] text-[var(--text-muted)] hover:text-[#7193ff] hover:bg-[rgba(113,147,255,0.1)] transition-colors cursor-pointer border-0 bg-transparent"
          onClick=${r=>n("down",r)}
        >▼</button>
      </div>

      <!-- Post body -->
      <div class="flex-1 min-w-0">
        <!-- Title -->
        <div class="text-[14px] font-medium text-[var(--text-strong)] leading-snug mb-1.5 group-hover:text-[var(--accent)] transition-colors">${t.title}</div>

        <!-- Content preview: max 3 lines -->
        <div class="text-[13px] text-[var(--text-body)] leading-[1.55] mb-2.5 overflow-hidden" style="display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical">${ye(Ot(t.body))}</div>

        <!-- Footer: author + meta + badges -->
        <div class="flex items-center gap-2 flex-wrap">
          <!-- Author line -->
          <span class="text-[12px] text-[var(--text-muted)]">${ht(t.author)}</span>
          <a
            class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] transition-colors cursor-pointer"
            onClick=${r=>{r.stopPropagation(),O("status",{section:"agents",agent:t.author})}}
          >${t.author}</a>
          <span class="text-[11px] text-[var(--text-muted)] opacity-60"><${$} timestamp=${t.created_at} /></span>
          ${_e(t)?a`<span class="text-[10px] text-[var(--text-muted)] opacity-50">(수정됨)</span>`:null}

          <!-- Separator -->
          <span class="text-[var(--text-muted)] opacity-30">|</span>

          <!-- Counts -->
          <span class="text-[11px] text-[var(--text-muted)]">댓글 ${t.comment_count}</span>

          <!-- Category badges -->
          ${e!=="human"?a`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border ${Ut(e)}">${e}</span>`:null}
          ${t.hearth?a`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${t.hearth}</span>`:null}
          ${t.visibility&&t.visibility!=="public"?a`<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium border bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-16)]">${t.visibility}</span>`:null}
        </div>
      </div>
    </div>
  `}function Te(t){const e=t.currentTarget,n=e.parentElement;if(!n)return;const r=n.querySelector(".comment-text");if(!r)return;const s=r.classList.toggle("expanded");e.textContent=s?"접기":"더 보기..."}function Ee({comment:t}){var n;const e=(((n=t.content)==null?void 0:n.length)??0)>300;return a`
    <div class="board-comment rounded-lg p-3 bg-[var(--white-3)] border border-[var(--border-slate-12)]">
      <div class="flex items-center gap-2 mb-1.5">
        <span class="text-[12px]">${ht(t.author)}</span>
        <a class="text-[12px] font-medium text-[var(--text-body)] hover:text-[var(--accent)] transition-colors cursor-pointer" onClick=${()=>O("status",{section:"agents",agent:t.author})}>${t.author}</a>
        <span class="text-[11px] text-[var(--text-muted)] opacity-60"><${$} timestamp=${t.created_at} /></span>
      </div>
      <div class="comment-text text-[13px] text-[var(--text-body)] leading-[1.55]">${t.content}</div>
      ${e?a`
        <button
          class="comment-expand-btn mt-1 text-[11px] text-[var(--accent)] hover:underline cursor-pointer bg-transparent border-0"
          style="display: inline"
          onClick=${Te}
        >더 보기...</button>
      `:null}
    </div>
  `}function je({comments:t}){if(t.length===0)return a`<${x} message="아직 댓글이 없습니다" compact />`;const e=3,[n,r]=H(!1),s=t.length-e,d=n||t.length<=e?t:t.slice(-e);return a`
    <div class="flex flex-col gap-2">
      ${!n&&s>0?a`
        <button
          class="text-[12px] text-[var(--accent)] hover:underline cursor-pointer bg-transparent border-0 text-left py-1"
          onClick=${()=>r(!0)}
        >이전 댓글 ${s}개 더 보기</button>
      `:null}
      ${d.map(o=>a`<${Ee} key=${o.id} comment=${o} />`)}
      ${n&&s>0?a`
        <button
          class="text-[12px] text-[var(--text-muted)] hover:text-[var(--accent)] cursor-pointer bg-transparent border-0 text-left py-1"
          onClick=${()=>r(!1)}
        >접기</button>
      `:null}
    </div>
  `}function Re({postId:t}){return a`
    <div class="mt-4 flex gap-2">
      <input
        type="text"
        class="flex-1 py-2 px-3 bg-[var(--white-5)] border border-[var(--border-slate-18)] rounded-lg text-[var(--text-body)] text-[13px] font-[inherit] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[rgba(71,184,255,0.55)] transition-colors"
        placeholder="댓글 추가..."
        value=${S.value}
        onInput=${e=>{S.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&jt(t)}}
        disabled=${L.value}
      />
      <button
        class="py-2 px-4 rounded-lg text-[13px] font-medium font-[inherit] cursor-pointer transition-all duration-150 border
          ${L.value||S.value.trim()===""?"bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-12)] opacity-50 cursor-not-allowed":"bg-[var(--ok-soft)] text-[var(--ok)] border-[var(--ok-30)] hover:bg-[var(--ok-22)]"}"
        onClick=${()=>jt(t)}
        disabled=${L.value||S.value.trim()===""}
      >
        ${L.value?"...":"등록"}
      </button>
    </div>
  `}function Be({post:t}){y.value!==t.id&&!R.value&&wt(t.id);const e=async n=>{try{await qt(t.id,n),_()}catch{k("투표에 실패했습니다","error")}};return a`
    <div>
      <button
        class="mb-4 px-3 py-1.5 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
        onClick=${()=>O("work",{section:"board"})}
      >← 게시판으로 돌아가기</button>

      <${b} title=${t.title}>
        <div class="flex flex-col gap-4">
          <div class="text-[13px] text-[var(--text-body)] leading-[1.65]">
            <${$e} text=${Ot(t.body)} />
          </div>

          <!-- Author and meta -->
          <div class="flex gap-2.5 items-center flex-wrap pt-3 border-t border-[var(--border-slate-12)]">
            <span class="text-[13px]">${ht(t.author)}</span>
            <a class="text-[12px] text-[var(--text-body)] hover:text-[var(--accent)] transition-colors cursor-pointer" onClick=${()=>O("status",{section:"agents",agent:t.author})}>${t.author}</a>
            <span class="text-[11px] text-[var(--text-muted)]"><${$} timestamp=${t.created_at} /></span>
            <span class="text-[11px] text-[var(--text-muted)]">${t.votes??0} votes</span>
          </div>

          <!-- Badges -->
          ${t.hearth||t.visibility||t.expires_at?a`
                <div class="flex gap-1.5 flex-wrap">
                  ${t.hearth?a`<span class="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium border bg-[var(--ff-gold-10)] text-[var(--ff-gold-bright)] border-[var(--ff-gold-20)]">${t.hearth}</span>`:null}
                  ${t.visibility?a`<span class="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium border bg-[var(--white-5)] text-[var(--text-muted)] border-[var(--border-slate-16)]">${t.visibility}</span>`:null}
                  ${W(t)!=="human"?a`<span class="inline-flex items-center px-2 py-0.5 rounded text-[10px] font-medium border ${Ut(W(t))}">${W(t)}</span>`:null}
                  ${Ae(t)}
                </div>
              `:null}

          <!-- Meta details -->
          ${t.meta?a`
                <details class="mt-1">
                  <summary class="cursor-pointer text-[12px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">운영 메타</summary>
                  <div class="mt-2 p-3 rounded-lg bg-[var(--white-3)] border border-[var(--border-slate-12)]">
                    ${t.meta.source?a`<div class="text-[12px] text-[var(--text-body)]"><span class="text-[var(--text-muted)]">출처:</span> ${t.meta.source}</div>`:null}
                    ${t.meta.state_block?a`<pre class="whitespace-pre-wrap mt-2 text-[11px] text-[var(--text-muted)] leading-relaxed">${t.meta.state_block}</pre>`:null}
                  </div>
                </details>
              `:null}

          <!-- Vote buttons -->
          <div class="flex gap-2">
            <button
              class="vote-btn upvote px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[#ff4500] hover:border-[rgba(255,69,0,0.3)] hover:bg-[rgba(255,69,0,0.08)] transition-all cursor-pointer"
              onClick=${()=>e("up")}
            >▲ 추천</button>
            <button
              class="vote-btn downvote px-3 py-1.5 rounded-lg text-[12px] font-medium border border-[var(--border-slate-16)] bg-transparent text-[var(--text-muted)] hover:text-[#7193ff] hover:border-[rgba(113,147,255,0.3)] hover:bg-[rgba(113,147,255,0.08)] transition-all cursor-pointer"
              onClick=${()=>e("down")}
            >▼ 비추천</button>
          </div>
        </div>
      <//>

      <div class="mt-4">
        <${b} title="댓글">
          ${R.value?a`<div class="loading-state loading-pulse">댓글 불러오는 중...</div>`:a`<${je} comments=${K.value} />`}
          <${Re} postId=${t.id} />
        <//>
      </div>
    </div>
  `}function Me(){const t=Kt(Ft.value),e=[...t.human,...t.operations],n=Z.value.params.post??null,r=n?e.find(s=>s.id===n)??(y.value===n?J.value:null):null;return n&&!r&&y.value!==n&&!R.value&&wt(n),n?r?a`
          <${ut} />
          <${Be} post=${r} />
        `:a`
          <div>
            <${ut} />
            <button
              class="mb-4 px-3 py-1.5 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
              onClick=${()=>O("work",{section:"board"})}
            >← 게시판으로 돌아가기</button>
            ${R.value?a`<div class="loading-state loading-pulse">글 불러오는 중...</div>`:a`<${x} message="글을 찾지 못했습니다" compact />`}
          </div>
        `:a`
    <div>
      <${ut} />
      <${Le} />
      <div class="mb-4">
        <${Se} />
      </div>
      ${vt.value?a`<div class="loading-state loading-pulse">메모리 피드 불러오는 중...</div>`:e.length===0?a`<${x} message="아직 게시글이 없습니다. 에이전트가 활동하면 소통과 지식 공유 글이 여기에 나타납니다." compact />`:a`
              <${b} title="사람이 쓴 글" class="mb-4">
                <div class="flex flex-col gap-2">
                  ${t.human.slice(0,A.value).map(s=>a`<${Rt} key=${s.id} post=${s} />`)}
                </div>
                ${t.human.length>A.value?a`
                  <div class="text-center py-4">
                    <button
                      class="px-4 py-2 rounded-lg text-[12px] font-medium text-[var(--text-muted)] bg-transparent border border-[var(--border-slate-16)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-all cursor-pointer"
                      onClick=${()=>{A.value=A.value+$t}}
                    >
                      더 보기 (${t.human.length-A.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?a`
                    <${b} title="자동화 · 시스템" class="mb-4">
                      <div class="flex flex-col gap-2">
                        ${t.operations.map(s=>a`<${Rt} key=${s.id} post=${s} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function M(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function D(t){return Array.isArray(t)?t:[]}function g(t){return oe(t)?t:{}}function De(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function ze(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function We(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function Fe(t,e,n,r,s,d,o,u,l){const c=[`${r}명이 실제 흔적을 남겼고, 계획된 참여자는 ${s}명입니다.`,o>0?`서로를 참조한 상호작용 증거가 ${o}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",u>0?`도구·산출물·체크포인트 증거가 ${u}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",l>0?`CPv2 backing trace가 ${l}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return n==="proven"&&e==="insufficient"?[c[0]??"","왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.","다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다."]:n==="proven"&&e==="partial"?[c[0]??"","왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.","다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다."]:t==="partial"?[c[0]??"",d>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${d}명 있습니다.`:o===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",l>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[c[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[c[0]??"",d>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${d}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",u>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function Oe(t){return t==="historical_only"?"과거 기록만":t==="live_and_historical"?"실시간 + 과거":"실시간"}function Bt(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function qe(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function Ne(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"muted"}function Ge(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function Ve(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Ie(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function He(t){return t.trace_validated===!0?"ok":t.success===!1||t.failure_reason||t.error?"bad":t.trace_capability==="raw"?"ok":(t.trace_capability==="summary_only","warn")}function Je(t){return t.trace_validated===!0?"검증됨":t.success===!1||t.failure_reason||t.error?"실패":t.trace_capability==="raw"?"raw trace":t.trace_capability==="summary_only"?"summary only":t.status??"근거 수집"}function Ke(t){return[t.resolved_runtime??null,t.resolved_model??null,t.mode??null,typeof t.tool_call_count=="number"?`도구 ${t.tool_call_count}`:null,typeof t.record_count=="number"?`레코드 ${t.record_count}`:null].filter(n=>!!n).join(" · ")}function Ue(t){return t.final_text??t.output_preview??t.error??t.failure_reason??t.stop_reason??null}function Ze(t){const e=new Map;for(const n of t){const r=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),s=n.source??"unknown",d=e.get(r);if(d){d.sources.includes(s)||d.sources.push(s),!d.operation_id&&n.operation_id&&(d.operation_id=n.operation_id);continue}e.set(r,{...n,sources:[s]})}return[...e.values()]}function Qe(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function Xe(t){const e=[];for(const[n,r]of Object.entries(t))if(r!=null){if(typeof r=="string"){if(r.trim()==="")continue;e.push({label:n,value:r});continue}if(typeof r=="number"||typeof r=="boolean"){e.push({label:n,value:String(r)});continue}}return e}function Ye(t){const e=g(t),n=g(e.traces),r=Array.isArray(n.events)?n.events:[],s=g(e.detachments),d=Array.isArray(s.detachments)?s.detachments:[],o=g(d[0]),u=g(o.detachment),l=g(o.operation),c=g(e.summary),p=g(c.operations),h=g(p.summary);return[{label:"작전",value:V(e.operation_id)??"없음"},{label:"분견대",value:V(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${r.length}`},{label:"분견대 상태",value:V(u.status)??"없음"},{label:"작전 단계",value:V(l.stage)??"없음"},{label:"활성 작전",value:`${de(h.active)??0}`}]}function tr({selection:t,summary:e}){if(!t||t.mode==="explicit")return null;const n=t.mode==="latest_auto_selected"&&(e==null?void 0:e.historical_verdict)==="proven"&&(e==null?void 0:e.live_verdict)!=="proven";return a`
    <div class="bg-card/30 backdrop-blur-sm border border-card-border/50 p-5 rounded-2xl shadow-sm cmd-guide-card ${Bt(t)}">
      <div class="flex items-center justify-between mb-3 pb-3 border-b border-card-border/50">
        <strong class="text-[13px] text-text-strong tracking-wide">${qe(t)}</strong>
        <span class="px-2.5 py-1 rounded-md text-[10px] font-bold uppercase tracking-widest bg-white/5 border border-white/10 ${Bt(t)}">${t.mode??"none"}</span>
      </div>
      <p class="text-[13px] text-text-body leading-relaxed mb-4">${t.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      ${n?a`<p class="text-[12px] text-warn/90 bg-warn/10 p-3 rounded-xl border border-warn/20 mb-4 shadow-inner">선택된 최신 세션은 과거 proof가 더 강하고 현재 live evidence는 더 약합니다.</p>`:null}
      <div class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2.5 text-[12px] bg-bg-1/40 p-4 rounded-xl shadow-inner border border-white/5">
        <span class="text-text-muted font-medium">선택된 세션</span><span class="text-text-strong font-mono">${t.selected_session_id??"없음"}</span>
        <span class="text-text-muted font-medium">작성자</span><span class="text-text-strong">${t.selected_created_by??"없음"}</span>
        <span class="text-text-muted font-medium">선택된 목표</span><span class="text-text-strong">${t.selected_goal??"없음"}</span>
        <span class="text-text-muted font-medium">선택 가능한 세션</span><span class="text-text-strong">${t.available_session_count??0}</span>
      </div>
    </div>
  `}function er({item:t}){return a`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:-translate-y-0.5 hover:shadow-md hover:bg-card/60 transition-all duration-200">
      <div class="flex items-start justify-between gap-4 mb-3">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong truncate">${t.summary??t.event_type??"도구 근거"}</strong>
          <div class="flex items-center gap-2 text-[11px] font-medium text-text-muted">
            <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${t.actor??"시스템"}</span>
            <span class="text-text-dim/60">•</span>
            <span class="font-mono">${t.event_type??"event"}</span>
          </div>
        </div>
        <span class="text-[11px] font-mono text-text-dim bg-white/5 px-2 py-0.5 rounded-md border border-white/5 shrink-0">${q(t.timestamp??null)}</span>
      </div>
      ${(()=>{const e=Ie(t);return e.length>0?a`<div class="flex flex-wrap gap-2 mt-3 pt-3 border-t border-card-border/50">
              ${e.map(n=>a`<span class="px-2 py-1 rounded-md text-[10px] font-medium bg-accent/10 text-accent border border-accent/20 shadow-sm">${n}</span>`)}
            </div>`:null})()}
    </article>
  `}function rr({item:t}){const e=Ue(t),n=Array.isArray(t.validation_failures)?t.validation_failures:[],r=Array.isArray(t.tool_names)?t.tool_names:[];return a`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:border-accent/30 transition-all duration-200 flex flex-col gap-3">
      <div class="flex justify-between gap-4 items-start">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong font-bold tracking-wide">${t.worker_name??t.worker_run_id}</strong>
          <div class="flex flex-wrap gap-2 text-[11px] text-text-muted font-medium items-center">
            <span class="font-mono bg-white/5 px-1.5 py-0.5 rounded border border-white/5">${t.worker_run_id}</span>
            <span class="text-text-dim/60">•</span>
            <span>${t.ts_iso?q(t.ts_iso):"기록 없음"}</span>
          </div>
        </div>
        <span class="px-2.5 py-1 rounded-md text-[10px] font-bold uppercase tracking-widest shadow-sm ${He(t)}">
          ${Je(t)}
        </span>
      </div>
      <div class="text-[11px] text-text-body/80 bg-white/5 p-2 rounded-lg border border-white/10 mt-1 shadow-inner">
        ${Ke(t)||"runtime/model 메타데이터 없음"}
      </div>
      ${e?a`<div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-card-border bg-bg-1/40 shadow-inner mt-1">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-text-muted">${t.success===!1||t.error||t.failure_reason?"실패 요약":"출력 요약"}</strong>
            <span class="text-[12px] text-text-body leading-relaxed whitespace-pre-wrap font-mono opacity-90">${e}</span>
          </div>`:null}
      ${n.length>0?a`<div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-warn/30 bg-warn/10 shadow-inner mt-1">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-warn">검증 실패</strong>
            <span class="text-[12px] text-text-body leading-relaxed whitespace-pre-wrap">${n.join(" · ")}</span>
          </div>`:null}
      ${r.length>0?a`<div class="flex flex-wrap gap-2 mt-2 pt-3 border-t border-card-border/50">
            ${r.map(s=>a`<span class="px-2 py-1 rounded-md text-[10px] font-medium bg-accent/10 text-accent border border-accent/20 shadow-sm">${s}</span>`)}
          </div>`:null}
    </article>
  `}function ar({item:t}){return a`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:-translate-y-0.5 hover:shadow-md hover:bg-card/60 transition-all duration-200">
      <div class="flex items-start justify-between gap-4">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong font-medium truncate">${t.summary??t.event_type??"이벤트"}</strong>
          <div class="flex items-center gap-2 text-[11px] font-medium text-text-muted flex-wrap">
            <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${Qe(t)}</span>
            <span class="px-2 py-0.5 rounded-md bg-accent/10 text-accent border border-accent/20 shadow-sm">${t.event_type??"이벤트"}</span>
            <span class="text-text-dim/60">•</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="text-[11px] font-mono text-text-dim bg-white/5 px-2 py-0.5 rounded-md border border-white/5 shrink-0">${q(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?a`<div class="flex flex-wrap gap-2 mt-3 pt-3 border-t border-card-border/50">
            ${t.sources.map(e=>a`<span class="px-2 py-1 rounded-md text-[10px] font-medium bg-white/10 text-text-muted border border-white/5 shadow-sm">${e}</span>`)}
          </div>`:null}
    </article>
  `}function nr({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,r=t.recent_event_summary??null,s=t.recent_request_preview??null,d=t.last_active_at??t.recent_request_at??null,o=t.activity_state==="planned_only";return a`
    <article class="proof-actor-row" style="${o?"opacity: 0.45;":""}">
      <div class="flex justify-between gap-3 items-start">
        <div>
          <strong>${t.actor}</strong>
          <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-[1.45]">
            <span>${t.role??"참여자"}</span>
            <span>${d?q(d):"기록 없음"}</span>
          </div>
        </div>
        <${It} label=${Ge(t)} tone=${Ne(t)} />
      </div>
      <div class="grid gap-1">
        <span>${Ve(t)}</span>
      </div>
      ${t.activity_detail?a`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong>현재 해석</strong>
            <span>${t.activity_detail}</span>
          </div>`:null}
      ${r?a`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong>최근 흔적</strong>
            <span>${r}</span>
          </div>`:null}
      ${s&&t.activity_state!=="acted"?a`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong>최근 요청</strong>
            <span>${s}</span>
          </div>`:null}
      ${n||e?a`<div class="grid grid-cols-2 gap-3">
            <div class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-6)] grid gap-1">
              <strong>최근 입력</strong>
              <span>${n??"표시 가능한 입력 없음"}</span>
            </div>
            <div class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-6)] grid gap-1">
              <strong>최근 응답</strong>
              <span>${e??"표시 가능한 응답 없음"}</span>
            </div>
          </div>`:null}
      ${Array.isArray(t.recent_tool_names)&&t.recent_tool_names.length>0?a`<div class="flex flex-wrap gap-1.5 mb-3">
            ${t.recent_tool_names.map(u=>a`<span class="semantic-tag">${u}</span>`)}
          </div>`:null}
    </article>
  `}function sr({item:t}){return a`
    <article class="cmd-card rounded-xl proof-artifact-row">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${De(t.path)}</span>
          </div>
        </div>
        <${It} label=${t.exists?"존재함":"없음"} tone=${t.exists?"ok":"warn"} />
      </div>
    </article>
  `}function Mt({title:t,rows:e}){return e.length===0?null:a`
    <div class="grid gap-3">
      ${t?a`<strong>${t}</strong>`:null}
      <div class="grid grid-cols-[132px_minmax(0,1fr)] gap-x-3 gap-y-2">
        ${e.map(n=>a`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function or(){var At,Pt,St;const t=Z.value.params,e=t.session_id??null,n=t.operation_id??null;Vt(()=>(le(e,n).catch(()=>{}),()=>{}),[e,n]);const r=ie.value;if(ce.value&&!r)return a`<section class="flex flex-col gap-[18px]"><${X}>근거 화면 불러오는 중…<//></section>`;if(I.value&&!r)return a`<section class="flex flex-col gap-[18px]"><div class="error-card rounded-xl">${I.value}</div></section>`;const s=r==null?void 0:r.summary,d=(r==null?void 0:r.selection)??null,o=D(r==null?void 0:r.actor_contributions),u={acted:0,mentioned_only:1,planned_only:2},l=[...o].sort((i,w)=>(u[i.activity_state??""]??2)-(u[w.activity_state??""]??2)),c=D(r==null?void 0:r.artifacts),p=D(r==null?void 0:r.tool_evidence),h=D(r==null?void 0:r.worker_run_evidence),m=(r==null?void 0:r.proof_verdict)??"insufficient",tt=(s==null?void 0:s.live_verdict)??m,et=(s==null?void 0:s.historical_verdict)??null,Qt=(s==null?void 0:s.verdict_basis)??"live",Xt=(s==null?void 0:s.raw_trace_run_count)??h.filter(i=>i.trace_capability==="raw").length,_t=(s==null?void 0:s.validated_worker_run_count)??h.filter(i=>i.trace_validated===!0).length,C=(r==null?void 0:r.cp_backing_evidence)??null,N=Array.isArray((At=C==null?void 0:C.traces)==null?void 0:At.events)?((St=(Pt=C.traces)==null?void 0:Pt.events)==null?void 0:St.length)??0:0,rt=(s==null?void 0:s.actors_count)??l.length,B=(s==null?void 0:s.planned_actor_count)??l.length,G=(s==null?void 0:s.unanswered_actor_count)??l.filter(i=>i.activity_state!=="acted"&&(i.mention_count??0)>0).length,kt=(s==null?void 0:s.mentioned_actor_count)??l.filter(i=>(i.mention_count??0)>0).length,at=(s==null?void 0:s.interaction_count)??0,nt=(s==null?void 0:s.evidence_count)??0,Ct=Ze(D(r==null?void 0:r.timeline)),Yt=Xe(g(r==null?void 0:r.goal_binding)),te=Ye(C),st=c.filter(i=>i.exists).length,ot=c.length-st,ee=Fe(m,tt,et,rt,B,G,at,nt,N);return a`
    <section class="flex flex-col gap-6">
      <!-- Header -->
      <div class="flex items-start justify-between gap-5 flex-wrap px-1">
        <div class="max-w-2xl">
          <h2 class="text-xl font-bold text-text-strong tracking-wide mb-2">근거 <span class="text-text-muted font-normal text-sm ml-2">Evidence & Context</span></h2>
          <p class="text-[13px] text-text-muted leading-relaxed">이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="flex gap-2 flex-wrap items-center pt-1">
          <span class="px-3 py-1.5 rounded-full text-[11px] font-bold border shadow-sm ${M(m)}">${ze(m)}</span>
          ${r!=null&&r.session_id?a`<span class="px-2.5 py-1 rounded-md bg-white/5 border border-white/10 text-text-muted text-[11px] font-mono shadow-sm">${r.session_id}</span>`:null}
          ${r!=null&&r.generated_at?a`<span class="px-2.5 py-1 rounded-md bg-white/5 border border-white/10 text-text-muted text-[11px] font-mono shadow-sm">${q(r.generated_at)}</span>`:null}
        </div>
      </div>

      ${I.value?a`<div class="p-4 rounded-xl border border-bad/30 bg-bad/10 text-[13px] text-bad font-medium shadow-sm">${I.value}</div>`:null}

      <${tr} selection=${d} summary=${s??null} />

      <!-- Primary stat cards -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-4">
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm ${M(m).replace("border","ring-1 ring")}">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">판정</span>
          <strong class="text-2xl font-bold text-text-strong tabular-nums">${We(m)}</strong>
          <small class="text-[11px] text-text-muted/80 leading-relaxed mt-1">${(s==null?void 0:s.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">실제 흔적</span>
          <strong class="text-2xl font-bold text-text-strong tabular-nums">${rt}</strong>
          <small class="text-[11px] text-text-muted/80 leading-relaxed mt-1">이벤트를 남긴 actor 수${B>0?` (계획 ${B})`:""}</small>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] ${nt>0?"text-ok":"text-warn"} tracking-widest uppercase font-semibold">근거</span>
          <strong class="text-2xl font-bold text-text-strong tabular-nums">${nt}</strong>
          <small class="text-[11px] text-text-muted/80 leading-relaxed mt-1">도구 ${(p==null?void 0:p.length)??0} / 산출물 ${st}/${c.length} / CP ${N}</small>
        </div>
      </div>

      <!-- Expanded detail metrics -->
      <details class="mb-1">
        <summary class="cursor-pointer text-[13px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">상세 지표 (${8}개)</summary>
        <div class="grid grid-cols-[repeat(auto-fit,minmax(155px,1fr))] gap-3 mt-3">
          <div class="flex flex-col gap-1.5 ${f} ${M(tt)}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">Live 판정</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${tt}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${Oe(Qt)} 기준</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${M(et??"insufficient")}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">Historical</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${et??"none"}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">persisted proof 문서 기준</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${G>0?"warn":"ok"}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">무응답</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${G}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${G>0?"호출됐지만 응답 없음":"없음"}</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${at>0?"ok":"warn"}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">직접 상호작용</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${at}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">참여자 간 직접 연결</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${N>0?"ok":"warn"}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">CP 트레이스</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${N}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">관리형 backing</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${_t>0?"ok":"warn"}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">OAS 워커 근거</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${_t}/${Math.max(Xt,h.length)}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">검증됨 / 수집됨</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${ot===0&&c.length>0?"ok":"warn"}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">산출물</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${st}/${c.length}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${ot>0?`${ot}개 누락`:"전부 존재함"}</small>
          </div>
          <div class="flex flex-col gap-1.5 ${f} ${B>rt?"warn":"ok"}">
            <span class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">계획된 참여자</span>
            <strong class="text-[15px] font-bold text-[var(--text-strong)] tabular-nums">${B}</strong>
            <small class="text-[11px] text-[var(--text-muted)]">${kt>0?`${kt}명 호출됨`:"호출 기록 없음"}</small>
          </div>
        </div>
      </details>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${b} title="3줄 근거 요약">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">핵심 증명</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="grid gap-3">
            ${ee.map((i,w)=>a`
              <article class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] ${w===1&&m!=="proven"?M(m):""}">
                <strong class="text-[13px] font-semibold text-[var(--text-strong)]">${w===0?"지금 결론":w===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span class="text-[12px] text-[var(--text-body)] leading-relaxed">${i}</span>
              </article>
            `)}
          </div>
        <//>

        <${b} title="증명 대상">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">무엇을 증명하려는가</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Mt} rows=${Yt} />
          <details class="pt-1 border-t border-[var(--white-6)] mt-2">
            <summary class="cursor-pointer text-[12px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${Tt((r==null?void 0:r.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${b} title="협업 타임라인">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">협업 타임라인</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${Ct.length>0?Ct.slice(0,18).map(i=>a`<${ar} key=${i.id} item=${i} />`):a`<${x} message="타임라인 근거가 없습니다. 에이전트 협업이 진행되면 세션과 지휘 이벤트가 여기에 나타납니다." compact />`}
          </div>
        <//>

        <${b} title="참여 흔적">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">누가 무엇을 남겼는가</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${l.length>0?l.map(i=>a`<${nr} key=${i.actor} item=${i} />`):a`<${x} message="참여 흔적이 없습니다. 에이전트가 작업에 참여하면 턴, 도구 호출, 산출물이 기록됩니다." compact />`}
          </div>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${b} title="도구 근거">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">어떤 도구를 언제 썼는가</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${p.length>0?p.map((i,w)=>a`<${er} key=${`${i.actor??"system"}-${w}`} item=${i} />`):a`<${x} message="도구 근거가 없습니다. 에이전트가 MCP 도구를 사용하면 호출 내역이 여기에 기록됩니다." compact />`}
          </div>
        <//>

        <${b} title="OAS 워커 근거">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">worker run trace는 얼마나 남아 있나</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">OAS worker가 남긴 raw trace, 검증 결과, 최종 출력 요약을 바로 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${h.length>0?h.map(i=>a`<${rr} key=${i.worker_run_id} item=${i} />`):a`<${x} message="표시할 OAS worker evidence가 없습니다. raw trace 또는 summary-only evidence가 생기면 여기에 나타납니다." compact />`}
          </div>
        <//>
      </div>

      <div class="grid gap-4">
        <${b} title="실행 근거">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">실행 backing은 얼마나 남아 있나</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Mt} rows=${te} />
          <details class="pt-1 border-t border-[var(--white-6)] mt-2">
            <summary class="cursor-pointer text-[12px] text-[var(--text-muted)] py-1.5 hover:text-[var(--text-body)] transition-colors">원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${Tt(C??{})}</pre>
          </details>
        <//>
      </div>

      <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
        <${b} title="산출물">
          <div class="grid gap-1 mb-3">
            <h3 class="text-[14px] font-semibold text-[var(--text-strong)]">어떤 파일 산출물이 남았나</h3>
            <p class="text-[12px] text-[var(--text-muted)] leading-relaxed">proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="flex flex-col gap-3">
            ${c.length>0?c.map(i=>a`<${sr} key=${i.path} item=${i} />`):a`<${x} message="산출물이 없습니다. proof/report/session 파일이 생성되면 존재 여부가 표시됩니다." compact />`}
          </div>
        <//>
      </div>
    </section>
  `}const bt=v("all"),gt=v("all"),mt=v(new Set);function dr(t){const e=new Set(mt.value);e.has(t)?e.delete(t):e.add(t),mt.value=e}const Zt=ft(()=>{let t=z.value;return bt.value!=="all"&&(t=t.filter(e=>e.horizon===bt.value)),gt.value!=="all"&&(t=t.filter(e=>e.status===gt.value)),t}),lr=ft(()=>{const t={short:[],mid:[],long:[]};for(const e of Zt.value){const n=t[e.horizon];n&&n.push(e)}return t}),ir=ft(()=>{const t=Array.from(ue.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function cr(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function yt(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function F(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Dt(t){return t.toFixed(4)}function zt(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function ur(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function pr(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function Wt(t,e){return(t.priority??4)-(e.priority??4)}function xr(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function vr({goal:t}){return a`
    <div class="goal-row flex justify-between items-start gap-4 p-4 rounded-xl border border-card-border/50 bg-card/40 backdrop-blur-md transition-all duration-200 hover:bg-card/60 hover:border-accent/30 shadow-sm hover:shadow-md hover:-translate-y-0.5 group">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1.5">
          <span class="text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-md bg-white/5 border border-white/10" style="color:${F(t.horizon)}">
            ${yt(t.horizon)}
          </span>
          <span class="text-[15px] font-bold text-text-strong group-hover:text-accent transition-colors tracking-wide">${t.title}</span>
        </div>
        <div class="flex gap-3 flex-wrap items-center mt-2.5 text-[11px] font-medium text-text-muted/90">
          <span class="text-amber-500 tracking-[1px] text-[13px] drop-shadow-sm" title="Priority ${t.priority}">${cr(t.priority)}</span>
          ${t.metric?a`<span class="flex items-center gap-1.5 px-2 py-0.5 bg-accent/10 text-accent rounded-md border border-accent/20"><span class="w-1.5 h-1.5 rounded-full bg-accent/60"></span>${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?a`<span class="flex items-center gap-1.5 px-2 py-0.5 bg-bad/10 text-bad rounded-md border border-bad/20"><span>마감:</span><${$} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?a`
          <div class="text-[12px] text-text-body/80 italic mt-3 p-2.5 rounded-lg border border-white/5 bg-white/5 leading-relaxed shadow-inner">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="flex flex-col items-end gap-1.5 shrink-0 pt-0.5">
        <${Nt} status=${t.status} />
        <div class="text-[11px] font-mono text-text-dim mt-auto">
          <${$} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function pt({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((r,s)=>s.priority-r.priority);return a`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2 mb-1 px-1">
        <span class="text-[12px] font-bold uppercase tracking-widest" style="color:${F(t)}">${yt(t)} 목표</span>
        <span class="text-[10px] font-semibold px-2 py-0.5 rounded-md bg-white/5 text-text-muted border border-white/10 shadow-sm">${e.length}</span>
      </div>
      <div class="flex flex-col gap-2.5">
        ${n.map(r=>a`<${vr} key=${r.id} goal=${r} />`)}
      </div>
    </div>
  `}function br(){const t=["all","short","mid","long"].map(n=>({key:n,label:n==="all"?"전체":yt(n)})),e=["all","active","completed","paused"].map(n=>({key:n,label:pr(n)}));return a`
    <div class="flex gap-4 flex-wrap mt-3">
      <div class="flex items-center gap-1.5">
        <label class="text-[11px] text-[var(--text-dim)]">범위</label>
        <${Et} chips=${t} active=${bt} />
      </div>
      <div class="flex items-center gap-1.5">
        <label class="text-[11px] text-[var(--text-dim)]">상태</label>
        <${Et} chips=${e} active=${gt} />
      </div>
    </div>
  `}function gr(){const t=z.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,r={short:0,mid:0,long:0};for(const s of t)s.horizon in r&&r[s.horizon]++;return a`
    <div class="flex gap-4 flex-wrap pb-2 border-b border-card-border/50">
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold text-text-strong tabular-nums">${t.length}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">전체</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold text-ok tabular-nums">${e}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">진행 중</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold text-text-dim tabular-nums">${n}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">완료</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold tabular-nums" style="color:${F("short")}">${r.short}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">단기</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold tabular-nums" style="color:${F("mid")}">${r.mid}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">중기</div>
      </div>
      <div class="flex-1 min-w-[70px] text-center py-3 px-2 bg-card/60 backdrop-blur-md rounded-xl border border-card-border/50 shadow-inner">
        <div class="text-2xl font-bold tabular-nums" style="color:${F("long")}">${r.long}</div>
        <div class="text-[10px] font-semibold tracking-widest uppercase text-text-muted mt-1">장기</div>
      </div>
    </div>
  `}function mr({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return a`
    <div class="planning-loop-row rounded-xl">
      <div class="grid gap-3">
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <div class="text-[var(--text-strong)] text-lg font-semibold capitalize">${t.profile}</div>
            <div class="text-[var(--text-muted)] text-[11px] mt-0.5 font-mono">${t.loop_id}</div>
          </div>
          <div class="flex gap-1.5 flex-wrap">
            <${Nt} status=${t.status} />
            <span class="text-[10px] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="flex gap-3 flex-wrap text-[#b9c9ea] text-[13px]">
          <span>Baseline ${Dt(t.baseline_metric)}</span>
          <span>현재 ${Dt(t.current_metric)}</span>
          <span class=${zt(t).startsWith("+")?"text-[#9af3ba]":"text-[#fda4af]"}>
            Delta ${zt(t)}
          </span>
          <span>Elapsed ${pe(t.elapsed_seconds)}</span>
        </div>

        <div class="text-[var(--text-body)] text-base leading-[1.5]">${t.target||"명시된 목표가 없습니다"}</div>
        ${t.stop_reason||t.error_message?a`
              <div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">
          ${t.strict_mode?"엄격 근거 모드":"레거시"} · ${t.worker_engine??"엔진 정보 없음"} · ${n}
        </div>
        ${e?a`
              <div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">
                최근 반복 #${e.iteration}: ${e.changes||e.next_suggestion||"서술 정보 없음"}
              </div>
            `:a`<div class="text-[var(--text-muted)] text-[13px] leading-[1.5]">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `}function xt({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",r=mt.value.has(t.id),s=!!t.description;return a`
    <div class="kanban-card rounded-xl ${n}">
      <div class="kanban-card rounded-xl-header">
        <span class="priority-badge rounded priority-badge--${n}">${ur(e)}</span>
        <div class="kanban-card rounded-xl-title">${t.title}</div>
      </div>
      ${s?a`
        <div
          class="text-[13px] text-[var(--text-dim)] cursor-pointer transition-colors duration-150 hover:text-[var(--text-body)]"
          onClick=${()=>dr(t.id)}
        >
          ${r?t.description:xe(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card rounded-xl-meta">
        ${t.created_at?a`<${$} timestamp=${t.created_at} />`:a`<span>-</span>`}
        ${t.assignee?a`<span class="inline-flex items-center bg-[rgba(0,240,255,0.1)] text-[var(--accent)] px-2 py-1 gap-1 font-semibold before:content-['@'] rounded-lg">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function fr(){const{todo:t,inProgress:e,done:n}=Gt.value,r=[...t].sort(Wt),s=[...e].sort(Wt),d=[...n].sort(xr);return a`
    <${b} title="태스크 백로그" class="section mb-4">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(320px,1fr))] gap-6 items-start">
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[13px] font-bold">${t.length}</span>
          </div>
          ${r.length===0?a`<${x} message="대기 중인 태스크가 없습니다" compact />`:r.map(o=>a`<${xt} key=${o.id} task=${o} />`)}
        </div>
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[13px] font-bold">${e.length}</span>
          </div>
          ${s.length===0?a`<${x} message="진행 중인 태스크가 없습니다" compact />`:s.map(o=>a`<${xt} key=${o.id} task=${o} />`)}
        </div>
        <div class="flex flex-col gap-4 bg-[rgba(10,15,29,0.5)] rounded-[var(--radius-lg)] p-5 border border-solid border-[var(--accent-10)]">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge px-2.5 py-1 rounded-xl text-[13px] font-bold">${n.length}</span>
          </div>
          ${d.length===0?a`<${x} message="완료된 태스크가 없습니다" compact />`:d.slice(0,20).map(o=>a`<${xt} key=${o.id} task=${o} />`)}
          ${d.length>20?a`<${x} message=${`...외 ${d.length-20}개 더 있음`} compact />`:null}
        </div>
      </div>
    <//>
  `}function $r(){const{todo:t,inProgress:e,done:n}=Gt.value,r=t.length+e.length+n.length,s=[...t,...e].filter(p=>(p.priority??4)<=2).length,d=lr.value,o=ir.value,u=z.value.length>0,l=o.length>0,c=ve.value;return a`
    <div class="flex flex-col gap-6">

      <!-- Task-based stats grid -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-4">
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">전체 태스크</span>
          <span class="text-[32px] font-bold text-text-strong leading-none tabular-nums">${r}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">할 일</span>
          <span class="text-[32px] font-bold leading-none tabular-nums text-[#e0e0e0]">${t.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">진행 중</span>
          <span class="text-[32px] font-bold leading-none tabular-nums text-warn">${e.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">완료</span>
          <span class="text-[32px] font-bold leading-none tabular-nums text-ok">${n.length}</span>
        </div>
        <div class="flex flex-col gap-2 p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm">
          <span class="text-[11px] text-text-muted tracking-widest uppercase font-semibold">높은 우선순위</span>
          <span class="text-[32px] font-bold leading-none tabular-nums ${s>0?"text-bad":"text-text-muted/50"}">${s}</span>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="flex justify-end">
        <button
          class="px-4 py-2 rounded-xl text-[12px] font-semibold border border-transparent bg-white/5 text-text-muted hover:bg-white/10 hover:text-text-strong transition-all duration-200 cursor-pointer shadow-sm disabled:opacity-50 disabled:cursor-not-allowed"
          onClick=${()=>{be(),ge()}}
          disabled=${dt.value||lt.value}
        >
          ${dt.value||lt.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Task Backlog at top -->
      <${fr} />

      <!-- Goals in collapsible details -->
      <details class="overview-section-collapsible group bg-card/20 backdrop-blur-sm rounded-2xl border border-card-border/50 overflow-hidden" open=${u}>
        <summary class="px-5 py-4 cursor-pointer flex items-center bg-card/40 hover:bg-card/60 transition-colors border-b border-transparent group-open:border-card-border/50 text-[14px] font-bold text-text-strong">
          목표 파이프라인
          <span class="inline-flex items-center rounded-lg px-2.5 py-1 text-[10px] uppercase tracking-wider ml-auto bg-accent/10 text-accent border border-accent/20 shadow-sm font-semibold">${z.value.length}</span>
        </summary>
        <div class="p-5">
          ${u?a`
            <${gr} />
            <${br} />
            ${dt.value&&z.value.length===0?a`<${X}>목표 불러오는 중...<//>`:Zt.value.length===0?a`<${x} message="현재 필터에 맞는 목표가 없습니다" compact />`:a`
                    <div class="mt-4 flex flex-col gap-6">
                      <${pt} horizon="short" items=${d.short??[]} />
                      <${pt} horizon="mid" items=${d.mid??[]} />
                      <${pt} horizon="long" items=${d.long??[]} />
                    </div>
                  `}
          `:a`
            <${x} message="장기 목표가 아직 없습니다. masc_goal_upsert로 등록하면 메트릭 기반 추적이 시작됩니다." />
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible group bg-card/20 backdrop-blur-sm rounded-2xl border border-card-border/50 overflow-hidden" open=${l}>
        <summary class="px-5 py-4 cursor-pointer flex items-center bg-card/40 hover:bg-card/60 transition-colors border-b border-transparent group-open:border-card-border/50 text-[14px] font-bold text-text-strong">
          MDAL 루프
          <span class="inline-flex items-center rounded-lg px-2.5 py-1 text-[10px] uppercase tracking-wider ml-auto bg-accent/10 text-accent border border-accent/20 shadow-sm font-semibold">${o.length}</span>
        </summary>
        <div class="p-5">
          ${lt.value&&o.length===0?a`<${X}>MDAL 루프 불러오는 중...<//>`:o.length===0&&(c==="error"||it.value)?a`<div class="p-4 border border-bad/30 bg-bad/10 rounded-xl shadow-sm text-[13px] text-bad font-medium text-center">MDAL 스냅샷을 불러오지 못했습니다${it.value?`: ${it.value}`:""}. 백엔드 상태를 확인하세요.</div>`:o.length===0?a`<${x} message="가동 중인 루프가 없습니다. masc_mdal_start로 시작할 수 있습니다." />`:a`
                  <div class="grid gap-3">
                    ${o.map(p=>a`<${mr} key=${p.loop_id} loop=${p} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}function hr(){var o,u;const[t,e]=H([]),[n,r]=H(!0),[s,d]=H(null);return Vt(()=>{async function l(){try{r(!0);const c=await me("masc_worktree_list",{});try{const p=JSON.parse(c);e(Array.isArray(p)?p:p.worktrees||[])}catch{e([{id:"raw",branch:"Unknown",path:c}])}}catch(c){d(c instanceof Error?c.message:"Failed to load worktrees")}finally{r(!1)}}l()},[]),n?a`<${X}>워크트리 목록을 불러오는 중...<//>`:s?a`<div class="text-bad p-4 border border-bad/30 rounded-xl bg-bad/10 shadow-sm shadow-bad/5">${s}</div>`:!t||t.length===0?a`
      <${x} message="활성화된 워크트리가 없습니다." />
    `:t.length===1&&((o=t[0])==null?void 0:o.id)==="raw"?a`
      <div class="bg-card/40 backdrop-blur-md border border-card-border rounded-2xl p-5 shadow-sm shadow-black/10">
        <pre class="font-mono text-sm text-text-body whitespace-pre-wrap">${(u=t[0])==null?void 0:u.path}</pre>
      </div>
    `:a`
    <div class="grid gap-5">
      <div class="flex items-center justify-between">
        <h2 class="text-lg font-semibold tracking-wide text-text-strong">활성 워크트리</h2>
        <span class="text-xs font-medium px-2.5 py-1 bg-white/10 rounded-full text-text-muted border border-white/5">${t.length}개</span>
      </div>
      
      <div class="grid gap-4 grid-cols-1 lg:grid-cols-2">
        ${t.map(l=>a`
          <div key=${l.id||l.branch} class="flex flex-col gap-3 p-5 rounded-2xl border border-card-border bg-card/60 backdrop-blur-md hover:border-accent/40 hover:-translate-y-0.5 hover:shadow-md transition-all duration-200 shadow-sm shadow-black/10 group">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <div class="size-7 rounded-lg bg-accent/10 flex items-center justify-center border border-accent/20">
                  <span class="text-[14px]">🌿</span>
                </div>
                <span class="font-semibold text-[14px] text-text-strong truncate group-hover:text-accent transition-colors" title=${l.branch}>${l.branch}</span>
              </div>
              ${l.agent?a`<span class="text-[10px] font-medium px-2.5 py-1 rounded-md bg-accent/10 text-accent border border-accent/20 shadow-sm">${l.agent}</span>`:null}
            </div>
            
            <div class="text-[11px] text-text-muted/90 flex items-center gap-2 font-mono mt-1 bg-bg-0/50 p-2 rounded-lg border border-white/5">
              <span>📁</span> <span class="truncate" title=${l.path}>${l.path}</span>
            </div>
            
            ${l.task_id?a`
              <div class="text-[11px] font-medium text-text-muted flex items-center gap-2 mt-1 px-1">
                <span>📋</span> <span>${l.task_id}</span>
              </div>
            `:null}
            
            ${l.created_at?a`
              <div class="text-[10px] text-text-dim mt-2 pt-3 border-t border-card-border/50 flex justify-between">
                <span>생성됨</span>
                <span>${new Date(l.created_at).toLocaleString()}</span>
              </div>
            `:null}
          </div>
        `)}
      </div>
    </div>
  `}function wr(t){return t==="board"||t==="evidence"||t==="planning"||t==="worktrees"}function Sr(){const t=wr(Z.value.params.section)?Z.value.params.section:"board";return a`
    <div class="flex flex-col gap-6">
      <div class="transition-opacity duration-300">
        <${fe} label=${t}>
          ${t==="board"?a`<${Me} />`:t==="evidence"?a`<${or} />`:t==="planning"?a`<${$r} />`:a`<${hr} />`}
        </>
      </div>
    </div>
  `}export{Sr as Work};
