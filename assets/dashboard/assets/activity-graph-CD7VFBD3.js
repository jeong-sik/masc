import{m as u,h as W,C as S,A as H,T as K}from"./index-D0qvPfou.js";import{c as E,A as G,y as N}from"./vendor-Chwn_OlE.js";import{L as z,E as A}from"./feedback-state-k6WQ6FM9.js";function D(t,a,i,c,s=120){if(t.length===0)return{positions:new Map};const g=i*c,$=Math.sqrt(g/Math.max(t.length,1)),p=t.map((d,w)=>{const k=2*Math.PI*w/t.length,e=Math.min(i,c)*.35;return{id:d.id,x:i/2+e*Math.cos(k),y:c/2+e*Math.sin(k),vx:0,vy:0,weight:d.weight}}),m=new Map;for(const d of p)m.set(d.id,d);const M=a.filter(d=>m.has(d.source)&&m.has(d.target)&&d.source!==d.target);let n=i/4;for(let d=0;d<s;d++){for(const e of p)e.vx=0,e.vy=0;for(let e=0;e<p.length;e++)for(let r=e+1;r<p.length;r++){const o=p[e],l=p[r],x=o.x-l.x,v=o.y-l.y,f=Math.max(Math.sqrt(x*x+v*v),.01),h=$*$/f,b=x/f*h,y=v/f*h;o.vx+=b,o.vy+=y,l.vx-=b,l.vy-=y}for(const e of M){const r=m.get(e.source),o=m.get(e.target),l=o.x-r.x,x=o.y-r.y,v=Math.max(Math.sqrt(l*l+x*x),.01),f=v*v/$,h=1+Math.log1p(e.weight)*.3,b=l/v*f*h,y=x/v*f*h;r.vx+=b,r.vy+=y,o.vx-=b,o.vy-=y}const w=i/2,k=c/2;for(const e of p){const r=w-e.x,o=k-e.y;e.vx+=r*.01,e.vy+=o*.01}for(const e of p){const r=Math.sqrt(e.vx*e.vx+e.vy*e.vy);if(r>0){const l=Math.min(r,n);e.x+=e.vx/r*l,e.y+=e.vy/r*l}const o=30;e.x=Math.max(o,Math.min(i-o,e.x)),e.y=Math.max(o,Math.min(c-o,e.y))}n*=.95}const R=new Map;for(const d of p)R.set(d.id,{x:d.x,y:d.y});return{positions:R}}const _=E(null);function F(t,a){if(a==="offline"||a==="retired")return"#64748b";switch(t){case"agent":return"#22d3ee";case"task":return"#fbbf24";case"decision":return"#a78bfa";case"operation":return"#4ade80";case"debate":return"#fb923c";case"post":return"#f472b6";default:return"#94a3b8"}}function P(t,a){if(!a)return"rgba(100, 116, 139, 0.2)";switch(t){case"mention":return"rgba(34, 211, 238, 0.4)";case"assigned":return"rgba(74, 222, 128, 0.4)";case"voted":return"rgba(167, 139, 250, 0.4)";case"commented":return"rgba(244, 114, 182, 0.4)";case"collaborated":return"rgba(251, 191, 36, 0.4)";default:return"rgba(148, 163, 184, 0.3)"}}function T(t){return Math.max(6,Math.min(24,6+Math.log1p(t)*3))}function V({data:t}){const a=G(null),i=G(null);N(()=>{const s=a.current,g=i.current;if(!s||!g||!t.nodes.length)return;const $=g.getBoundingClientRect(),p=Math.max($.width,400),m=480,M=window.devicePixelRatio||1;s.width=p*M,s.height=m*M,s.style.width=`${p}px`,s.style.height=`${m}px`;const n=s.getContext("2d");if(!n)return;n.setTransform(M,0,0,M,0,0);const d=D(t.nodes.map(e=>({id:e.id,weight:e.weight})),t.edges.map(e=>({source:e.source,target:e.target,weight:e.weight})),p,m,150).positions,w=_.value;n.fillStyle="#0f1117",n.fillRect(0,0,p,m);for(const e of t.edges){const r=d.get(e.source),o=d.get(e.target);if(!r||!o)continue;const l=w===e.source||w===e.target,x=l?Math.max(1,Math.min(4,1+e.weight*.5)):Math.max(.5,Math.min(2,.5+e.weight*.3));n.beginPath(),n.moveTo(r.x,r.y),n.lineTo(o.x,o.y),n.strokeStyle=l?P(e.kind,e.active).replace(/[\d.]+\)$/,"0.7)"):P(e.kind,e.active),n.lineWidth=x,n.stroke()}for(const e of t.nodes){const r=d.get(e.id);if(!r)continue;const o=T(e.weight),l=w===e.id,x=F(e.kind,e.status);l&&(n.beginPath(),n.arc(r.x,r.y,o+6,0,Math.PI*2),n.fillStyle=x.replace(")",", 0.2)").replace("rgb","rgba"),n.fill()),n.beginPath(),n.arc(r.x,r.y,o,0,Math.PI*2),n.fillStyle=x,n.fill(),n.strokeStyle=l?"#fff":"rgba(255,255,255,0.15)",n.lineWidth=l?2:1,n.stroke(),(o>=10||l)&&(n.fillStyle="#e2e8f0",n.font=`${l?11:9}px system-ui, sans-serif`,n.textAlign="center",n.fillText(e.label,r.x,r.y+o+12))}function k(e){const r=a.current;if(!r)return;const o=r.getBoundingClientRect(),l=e.clientX-o.left,x=e.clientY-o.top;let v=null;for(const f of t.nodes){const h=d.get(f.id);if(!h)continue;const b=T(f.weight),y=l-h.x,L=x-h.y;if(y*y+L*L<=(b+4)*(b+4)){v=f.id;break}}_.value!==v&&(_.value=v)}return s.addEventListener("mousemove",k),()=>s.removeEventListener("mousemove",k)},[t,_.value]);const c=_.value?t.nodes.find(s=>s.id===_.value):null;return u`
    <div ref=${i} class="relative w-full overflow-hidden bg-[#0f1117] my-3 rounded-xl">
      <canvas ref=${a} class="block w-full cursor-crosshair" />
      ${c?u`
        <div class="absolute bottom-3 left-3 flex items-center gap-3 py-2 px-3.5 rounded-[10px] bg-[rgba(15,23,42,0.92)] border border-[var(--slate-gray-20)] text-[13px] text-[var(--text-slate-light)] pointer-events-none">
          <strong class="text-base text-[var(--text-near-white)]">${c.label}</strong>
          <span class="py-0.5 px-[7px] bg-[var(--slate-gray-15)] text-[11px] text-[var(--text-slate)] rounded-md">${c.kind}</span>
          <span>weight ${c.weight}</span>
          <span>status ${c.status}</span>
        </div>
      `:null}
    </div>
  `}const B=E(null),C=E(null),I=E(!1);async function j(){if(!I.value){I.value=!0,C.value=null;try{B.value=await W()}catch(t){C.value=t instanceof Error?t.message:String(t)}finally{I.value=!1}}}function X(t){switch(t){case"agent":return"에이전트";case"task":return"작업";case"decision":return"결정";case"operation":return"작전";case"debate":return"토론";case"post":return"게시글";case"comment":return"댓글";default:return t}}function q(t){switch(t){case"agent.joined":return"입장";case"agent.left":return"퇴장";case"message.broadcast":return"브로드캐스트";case"message.mentioned":return"멘션";case"task.created":return"작업 생성";case"task.claimed":return"작업 점유";case"task.started":return"작업 시작";case"task.done":return"작업 완료";case"task.released":return"작업 반환";case"task.cancelled":return"작업 취소";case"board.posted":return"게시";case"board.commented":return"댓글";case"board.voted":return"투표";case"operation.started":return"세션 시작";case"operation.resumed":return"세션 재개";case"operation.finalized":return"세션 종료";case"team.turn":return"팀 턴";case"team.turn_failed":return"팀 턴 실패";default:return t}}function Y(t){const a=t.actor;if(a!=null&&a.id)return a.id;const i=t.payload;return i.agent??i.author??i.from??""}function J(t){var g;const a=t.payload,i=a.message??a.content??"";if(i)return i.length>80?`${i.slice(0,77)}...`:i;const c=a.task_title;if(c)return c;const s=a.reason;return s||((g=t.subject)!=null&&g.id?`-> ${t.subject.id}`:t.kind)}function O({data:t}){const a=t.stats;return u`
    <div class="stats-grid grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3 mb-4">
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">노드</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${a.node_count}</div>
      </div>
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">엣지</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${a.edge_count}</div>
      </div>
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">에이전트</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${a.agent_count}</div>
      </div>
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">활성</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums text-[var(--ok)]">${a.active_agents}</div>
      </div>
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">작업</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${a.task_count}</div>
      </div>
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] py-[15px] px-3.5">
        <div class="text-[10px] text-[var(--text-muted)] tracking-[0.08em] uppercase font-medium">이벤트</div>
        <div class="mt-1.5 text-[var(--text-strong)] text-[30px] font-bold leading-none tabular-nums">${a.event_count}</div>
      </div>
    </div>
  `}function Q({events:t}){return t.length===0?u`<${A} message="최근 실행 이벤트가 없습니다." compact />`:u`
    <div class="flex flex-col gap-3">
      ${t.map(a=>{const i=Y(a);return u`
          <div class="monitor-row rounded-xl p-4 ok" key=${a.seq}>
            <div class="monitor-row rounded-xl-header">
              <div class="min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="monitor-title">${i||"(unknown)"}</span>
                  <span class="monitor-sub">${q(a.kind)}</span>
                </div>
                <div class="monitor-note">${J(a)}</div>
              </div>
              <span class="monitor-pill ok inline-flex items-center rounded-full px-2 py-[3px] text-[11px] uppercase tracking-[0.06em]">${q(a.kind)}</span>
            </div>
            <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]">
              <span>${a.room_id}</span>
              ${a.ts_iso?u`<span><${K} timestamp=${a.ts_iso} /></span>`:null}
              ${a.tags.length>0?u`<span>${a.tags.join(", ")}</span>`:null}
            </div>
          </div>
        `})}
    </div>
  `}function U({nodes:t}){var c;const a=t.filter(s=>s.kind==="agent").sort((s,g)=>g.weight-s.weight).slice(0,15);if(a.length===0)return u`<${A} message="활동 집계에 포함된 에이전트가 없습니다." compact />`;const i=((c=a[0])==null?void 0:c.weight)??1;return u`
    <div class="flex flex-col gap-1.5">
      ${a.map((s,g)=>{const $=i>0?s.weight/i*100:0;return u`
          <div class="flex items-center gap-[10px] py-2 px-3 rounded-[10px] bg-[rgba(15,23,42,0.5)] border border-solid border-[var(--slate-gray-8)]" key=${s.id}>
            <span class="w-[22px] text-center text-sm font-bold text-text-slate">${g+1}</span>
            <div class="flex-1 flex flex-col gap-1 min-w-0">
              <span class="text-base font-semibold text-[var(--text-near-white)] whitespace-nowrap overflow-hidden text-ellipsis">${s.label}</span>
              <div class="h-1 rounded-sm bg-[var(--slate-gray-10)] overflow-hidden">
                <div class="h-full rounded-sm bg-[var(--cyan)] transition-[width] duration-300 ease-in-out" style="width:${$}%"></div>
              </div>
            </div>
            <span class="text-sm font-semibold text-text-slate-light min-w-[32px] text-right">${s.weight}</span>
            <span class="text-[11px] py-0.5 px-[7px] rounded-md ${s.status==="offline"||s.status==="retired"?"text-[var(--text-slate)] bg-[var(--slate-gray-10)]":"text-[var(--ok)] bg-[var(--ok-10)]"}">${s.status}</span>
          </div>
        `})}
    </div>
  `}function Z({nodes:t}){const a=new Map;for(const c of t)a.set(c.kind,(a.get(c.kind)??0)+1);const i=[...a.entries()].sort((c,s)=>s[1]-c[1]);return i.length===0?u`<${A} message="분석할 노드 종류가 없습니다." compact />`:u`
    <div class="flex flex-wrap gap-2">
      ${i.map(([c,s])=>u`
        <div class="flex items-center gap-1.5 py-1.5 px-3 bg-[var(--panel-dark-60)] border border-[var(--slate-gray-12)] rounded-lg" key=${c}>
          <span class="text-sm text-text-slate-light">${X(c)}</span>
          <span class="text-base font-bold text-[var(--text-near-white)]">${s}</span>
        </div>
      `)}
    </div>
  `}function tt(){return u`
    <div class="flex flex-col gap-5">
      <${S} title="활동 그래프" class="section mb-4" testId="activity_graph.graph">
        <div class="mb-4">
          <h2 class="monitor-headline">활동 그래프가 비어 있습니다</h2>
          <p class="monitor-subheadline">이 뷰는 런타임 실행 이벤트를 읽어 그래프를 그립니다. 지금은 기록된 이벤트가 없어 화면이 비어 있습니다.</p>
        </div>
        <${A} message="아직 claim, broadcast, team-session, board 같은 실행 이벤트가 activity feed에 기록되지 않았습니다." compact />
      <//>
    </div>
  `}function rt(){N(()=>{j()},[]);const t=B.value,a=C.value;return I.value&&!t?u`<${z}>활동 그래프 불러오는 중...<//>`:a&&!t?u`
      <div class="flex flex-col gap-5">
        <${S} title="오류" class="section mb-4" testId="activity_graph.error">
          <${A} message=${"활동 그래프를 불러올 수 없습니다: "+a} compact />
          <${H} variant="ghost" onClick=${j}>다시 시도<//>
        <//>
      </div>
    `:t?(t.stats.event_count??0)===0?u`<${tt} />`:u`
    <div class="flex flex-col gap-5">

      <${S} title="활동 그래프" class="section mb-4" testId="activity_graph.graph">
        <div class="mb-4">
          <h2 class="monitor-headline">실행 이벤트 관계 그래프</h2>
          <p class="monitor-subheadline">에이전트, 작업, 결정, 운영 이벤트 간의 연결을 최근 실행 이벤트 기준으로 시각화합니다. 노드 크기는 활동 빈도를 반영합니다.</p>
        </div>
        <${O} data=${t} />
        <${V} data=${t} />
        <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]">
          <span>생성 시각: ${t.generated_at}</span>
          <span>데이터 범위: 최근 ${t.window.limit}건 이벤트</span>
          ${t.window.room_id?u`<span>room: ${t.window.room_id}</span>`:null}
        </div>
      <//>

      <div class="grid grid-cols-[minmax(0,1.08fr)_minmax(0,0.96fr)_minmax(0,0.88fr)] gap-4">
        <${S} title="활동 주체 순위" class="section mb-4" testId="activity_graph.leaderboard">
          <div class="mb-4">
            <h2 class="monitor-headline">활동 주체 순위</h2>
            <p class="monitor-subheadline">그래프 이벤트 빈도(weight)를 기준으로 정렬한 최근 활동 주체 순위입니다.</p>
          </div>
          <${U} nodes=${t.nodes} />
        <//>

        <${S} title="노드 종류 분포" class="section mb-4" testId="activity_graph.kinds">
          <div class="mb-4">
            <h2 class="monitor-headline">노드 종류</h2>
            <p class="monitor-subheadline">그래프에 포함된 노드를 종류별로 분류합니다.</p>
          </div>
          <${Z} nodes=${t.nodes} />
        <//>

        <${S} title="최근 실행 이벤트" class="section mb-4" testId="activity_graph.timeline">
          <div class="mb-4">
            <h2 class="monitor-headline">타임라인</h2>
            <p class="monitor-subheadline">가장 최근의 실행 이벤트를 시간순으로 보여줍니다.</p>
          </div>
          <${Q} events=${[...t.timeline].reverse().slice(0,30)} />
        <//>
      </div>
    </div>
  `:u`<${A} message="활동 데이터가 없습니다." compact />`}export{rt as ActivityGraphSurface,j as refreshActivityGraph};
