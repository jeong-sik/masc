import{t as d,u as m,E as i,m as e,v as u,x as v,r as g,C as l,y as $,z as n}from"./index-BB0zaaHQ.js";import{y as f,c as x}from"./vendor-Chwn_OlE.js";import{S as y}from"./stat-tile-Dyk_8z2I.js";import{Tools as b}from"./tools-BBi1aIXn.js";const p=x(!1);async function c(){try{await v()}catch(t){t instanceof Error&&/\b410\b/.test(t.message)&&(p.value=!0)}}function h(){var r,o;const t=d.value,s=m.value,a=p.value;return f(()=>{!t&&!s&&!a&&c()},[t,s,a]),a?e`<${i} message="TRPG 모듈은 아카이브되었습니다. 과거 세션 기록은 서버 로그에 남아 있습니다." />`:s&&!t?e`<${i} message="TRPG 상태를 불러오는 중..." compact />`:t?e`
    <${y} cols=${4} items=${[{label:"ROOM",value:u.value||((r=t.session)==null?void 0:r.room)||"-"},{label:"SESSION",value:((o=t.session)==null?void 0:o.status)??"active"},{label:"PARTY",value:t.party.length},{label:"EVENTS",value:t.story_log.length}]} />
  `:e`<${i}
      message="활성 TRPG 세션이 없습니다."
      action=${e`<button class="px-3 py-1.5 text-xs border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)] rounded-lg cursor-pointer hover:bg-[var(--white-8)]" onClick=${()=>void c()}>새로고침</button>`}
    />`}function S(){const s=$.value.slice(0,12);return s.length===0?e`<${i} message="에이전트 데이터를 불러오는 중..." compact />`:e`
    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); gap: 16px; padding: 16px 0;">
      ${s.map(a=>e`
        <${n}
          key=${a.name}
          name=${a.name}
          status=${a.status??"idle"}
          traits=${a.traits??[]}
          size="md"
          showName=${!0}
        />
      `)}
    </div>
    <div style="margin-top: 16px; display: flex; gap: 24px; flex-wrap: wrap;">
      <div>
        <div style="color: var(--text-muted); font-size: 11px; margin-bottom: 8px;">SIZES</div>
        <div style="display: flex; gap: 12px; align-items: end;">
          ${s.slice(0,3).map((a,r)=>e`
            <${n}
              key=${"size-"+a.name}
              name=${a.name}
              size=${["sm","md","lg"][r]}
              showName=${!0}
            />
          `)}
        </div>
      </div>
    </div>
  `}function T(){const t=g.value.params.section??"tools";return e`
    <div>
      ${t==="tools"?e`
        <${b} />
      `:null}

      ${t==="avatars"?e`
        <${l} title="아바타 갤러리" class="section mb-4">
          <${S} />
        <//>
      `:null}

      ${t==="trpg"?e`
            <${l} title="TRPG 실험" class="section mb-4">
              <${h} />
            <//>
          `:null}
    </div>
  `}function G(){return e`
    <div class="flex flex-col gap-6">
      <div class="transition-opacity duration-300">
        <${T} />
      </div>
    </div>
  `}export{G as LabSurface};
