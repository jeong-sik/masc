import{A as o,m as n}from"./vendor.js";import{s as l,j as h}from"./index.js";function v(e){return e.currentEpoch!==e.lockedEpoch?{locked:!0,reason:`세션 또는 워크스페이스가 변경되었습니다 (epoch ${e.lockedEpoch} → ${e.currentEpoch}). 대상을 다시 확인하세요.`,lockedEpoch:e.lockedEpoch}:e.currentWorkspaceId!==e.target.workspaceId?{locked:!0,reason:`활성 워크스페이스(${e.currentWorkspaceId})가 대상(${e.target.workspaceId})과 일치하지 않습니다.`,lockedEpoch:e.lockedEpoch}:String(e.currentRevision)!==String(e.target.revision)?{locked:!0,reason:`대상 리비전이 변경되었습니다 (rev ${e.target.revision} → ${e.currentRevision}). 새로고침 후 다시 승인하세요.`,lockedEpoch:e.lockedEpoch}:{locked:!1,reason:null,lockedEpoch:e.lockedEpoch}}function f(e){const d=`${e.target.workspaceId}:${e.target.requestId}`,r=o(null),c=o(null);(r.current!==d||c.current===null)&&(r.current=d,c.current=e.lockedEpoch??l.peek());const a=e.lockedEpoch??c.current,s=l.value,i=h.value,k=e.currentRevision??e.target.revision,t=v({target:e.target,currentRevision:k,lockedEpoch:a,currentEpoch:s,currentWorkspaceId:i}),u=typeof e.children=="function"?e.children(t):e.children;return n`
    <div
      class=${`tla ${e.className??""}`.trim()}
      data-locked=${t.locked?"true":"false"}
      data-workspace-id=${e.target.workspaceId}
      data-request-id=${e.target.requestId}
    >
      <dl class="tla-meta" aria-label="대상 식별 정보">
        <span class="tla-kv">
          <dt class="tla-k">workspace_id:</dt>
          <dd>${e.target.workspaceId}</dd>
        </span>
        <span class="tla-kv">
          <dt class="tla-k">keeper:</dt>
          <dd>${e.target.keeper}</dd>
        </span>
        <span class="tla-kv">
          <dt class="tla-k">request_id:</dt>
          <dd>${e.target.requestId}</dd>
        </span>
        <span class="tla-kv">
          <dt class="tla-k">revision:</dt>
          <dd>${String(e.target.revision)}</dd>
        </span>
      </dl>

      ${t.locked&&n`
        <div class="tla-lock-banner" role="alert">
          <span>${t.reason}</span>
          ${e.onRefresh&&n`
            <button type="button" class="btn-ghost" onClick=${e.onRefresh}>
              대상 새로고침
            </button>
          `}
        </div>
      `}

      <fieldset class="tla-actions" disabled=${t.locked}>
        ${u}
      </fieldset>
    </div>
  `}export{f as T};
