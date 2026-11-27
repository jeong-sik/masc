import{d as u,A as T,y as K,q as j,T as _,m as i}from"./vendor.js";import{$ as x,a as D,Y as z,l as N,B as Q,F as m}from"./index.js";import{f as V,a as Y,b as G,c as k,E as J}from"./index3.js";import{u as X,k as Z}from"./core.js";import{D as ee}from"./data-table.js";import{R as ae}from"./refresh-button.js";import"./lazy-component.js";import"./keeper-state.js";import"./type-guards.js";import"./format-string.js";import"./setup-inventory-read.js";import"./quota-window.js";import"./sse-reader.js";import"./wire-decode.js";import"./types.js";import"./attachment-gallery.js";import"./markdown-renderer.js";import"./markdown.js";import"./copyable-code.js";import"./toast.js";import"./turn-context.js";import"./now-signal.js";import"./shared-ticker.js";import"./virtual-list.js";import"./table.js";import"./useSelector.js";import"./target-locked-action.js";import"./icons.js";import"./inline-spinner.js";const re=["face","neck","head","hand","base"],c={face:"bare_face",neck:"bare_neck",head:"bare_head",hand:"empty_hand",base:"no_dish"};function Re(O){const{keeper:r}=O,C=x(D.value),[a,L]=u(null),[s,y]=u(null),[v,R]=u(null),[o,b]=u(null),[w,S]=u(!0),P=T(!0),A=T(r.name),$=T(null);A.current=r.name,K(()=>(P.current=!0,()=>{P.current=!1,$.current?.abort()}),[]);const q=j(async()=>{$.current?.abort();const e=new AbortController;$.current=e;const t=r.name,d=z(),f=D.peek();if(!N(f)){S(!1);return}S(!0);const n=x(f),[l,p]=await Promise.all([V(t,100,e.signal),n?Y(t,e.signal):Promise.resolve(null)]);if(!P.current||A.current!==t||!Q(d)||e.signal.aborted)return;S(!1);const g=[];l.ok?L(l.value):l.error.kind!=="aborted"&&l.error.kind!=="epoch_stale"&&g.push(`원장 조회 실패: ${l.error.message}`),p?p.ok?y(p.value):p.error.kind!=="aborted"&&p.error.kind!=="epoch_stale"&&g.push(`아이템 조회 실패: ${p.error.message}`):y(null),R(g.length>0?g.join(" · "):null)},[r.name,C]);K(()=>(L(null),y(null),R(null),b(null),q(),()=>{$.current?.abort()}),[q]);const E=_(()=>{const e=new Set;if(s?.owned_items)for(const t of s.owned_items)e.add(t);if(a?.balance?.owned_items)for(const t of a.balance.owned_items)e.add(t);return e},[s,a]),U=_(()=>{const e=a?.balance?.equipped??r.portrait_equipment;return{face:e?.face??c.face,neck:e?.neck??c.neck,head:e?.head??c.head,hand:e?.hand??c.hand,base:e?.base??c.base}},[a,r.portrait_equipment]),I=_(()=>G(r.name,256,o,o===null?r.portrait_equipment:null),[r.name,o,r.portrait_equipment]),h=X(I),[H,M]=u(null),B=_(()=>[{id:"seq",header:"Seq",accessor:e=>e.seq,numeric:!0,sortable:!0},{id:"kind",header:"Kind",accessor:e=>e.kind,sortable:!0},{id:"summary",header:"Detail",accessor:e=>e.summary||"없음"},{id:"at",header:"Time",accessor:e=>e.at_rfc3339||String(e.at_unix)}],[]),F=a?.balance?m(k(a.balance.balance_milli)):s?.balance_milli?m(k(s.balance_milli)):"없음",W=a?.balance?m(k(a.balance.decayed_milli)):"없음";return i`
    <div class="kp-scroll-pane" data-keeper-tab="portrait-candle">
      <div class="kp-card-head">
        <h3>Portrait & Candle · ${r.name}</h3>
        <${ae} reading=${w} onRefresh=${()=>q()} />
      </div>

      <div class="kp-notice" data-tone="info" role="note">
        Candle 장신구 구매·장착은 Keeper 자율 턴 지갑 정책으로 실행됩니다. 여기서는 실시간 초상화 착용 미리보기(?preview)와 원장 상태를 관측합니다.
      </div>

      <div class="kp-grid-2">
        <!-- Portrait Live Preview + 5-Slot Wardrobe -->
        <section class="kp-card" aria-label="초상화 미리보기 및 5슬롯 장신구">
          <div class="kp-portrait-stage">
            ${h!==null&&H!==h?i`
                  <img
                    class="kp-portrait-preview"
                    src=${h}
                    data-portrait-url=${I}
                    alt=${`${r.name} portrait preview`}
                    onError=${()=>M(h)}
                  />
                `:i`
                  <div
                    class="kp-portrait-preview kp-hero-portrait-sigil"
                    data-portrait-url=${I}
                    role="img"
                    aria-label=${`${r.name} portrait preview`}
                  >
                    ${Z(r.name)}
                  </div>
                `}
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone="brass">
                Balance: ${F} C
              </span>
              <span class="kp-pill">
                Decayed: ${W} C
              </span>
              ${o!==null&&i`
                <span class="kp-pill" data-tone="info">Preview: ${o}</span>
                <button type="button" class="btn-ghost" onClick=${()=>b(null)}>
                  미리보기 초기화
                </button>
              `}
            </div>
          </div>

          <div class="kp-card-head">
            <h3>5-Slot Ornament Wardrobe (Try-On Preview)</h3>
          </div>
          ${re.map(e=>{const t=J[e],d=U[e],f=o&&t.includes(o)?o:d;return i`
              <div key=${e} class="kp-field-row">
                <div>
                  <div class="kp-roster-name">${e}</div>
                  <div class="kp-roster-sub">착용 중: ${d}</div>
                </div>
                <select
                  class="kp-input"
                  aria-label=${`${e} 슬롯 미리보기`}
                  value=${f}
                  onChange=${n=>{const l=n.currentTarget.value;b(l===c[e]||l===d?null:l)}}
                >
                  ${t.map(n=>i`
                    <option key=${n} value=${n}>
                      ${n}${n===c[e]?" (기본)":E.has(n)?" (보유)":" (미보유 · 미리보기)"}
                    </option>
                  `)}
                </select>
              </div>
            `})}
        </section>

        <!-- Candle Balance, Policy & Ornament Catalog -->
        <section class="kp-card" aria-label="Candle 상점 및 원장 정책">
          <div class="kp-card-head">
            <h3>Candle Economy & Catalog</h3>
            <span class="kp-pill" data-tone=${v?"bad":a?.policy_configuration==="enabled"?"brass":"default"}>
              ${w&&!a&&!s?"불러오는 중":v?"조회 실패":a?.policy_configuration??s?.status??(C?"off":"토큰 필요")}
            </span>
          </div>
          ${v&&i`
            <div class="ap-error" role="alert">${v}</div>
          `}

          <div class="kp-grid-2">
            <div class="kp-kv-box">
              <span class="kp-kv-k">Pricing Mode</span>
              <span class="kp-kv-v">${a?.pricing_mode??"없음"}</span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Half-Life</span>
              <span class="kp-kv-v">${a?.half_life_hours!=null?`${a.half_life_hours}h`:"없음"}</span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Supply Circulating</span>
              <span class="kp-kv-v">
                ${a?`${m(k(a.supply.circulating_milli))} C`:"없음"}
              </span>
            </div>
            <div class="kp-kv-box">
              <span class="kp-kv-k">Owned Ornaments</span>
              <span class="kp-kv-v">${E.size}</span>
            </div>
          </div>

          ${s&&s.status==="ready"?i`
                <div class="kp-card-head">
                  <h3>Catalog (${s.catalog.length})</h3>
                </div>
                <div>
                  ${s.catalog.map(e=>{const t=E.has(e.id),d=e.price_status==="priced"&&e.price_milli?`${m(k(e.price_milli))} C`:"가격 미정";return i`
                      <div key=${e.id} class="kp-field-row">
                        <div>
                          <div class="kp-roster-name">${e.id}</div>
                          <div class="kp-roster-sub">${e.slot} · ${d}</div>
                        </div>
                        <div class="kp-pill-row">
                          <button
                            type="button"
                            class="btn-ghost"
                            onClick=${()=>b(e.id)}
                          >
                            미리보기
                          </button>
                          <span class="kp-pill" data-tone=${t?"ok":void 0}>
                            ${t?"보유":"Keeper 자율 구매"}
                          </span>
                        </div>
                      </div>
                    `})}
                </div>
              `:C?w?i`
                    <div class="kp-empty" role="status">
                      Candle 상점 카탈로그를 불러오는 중…
                    </div>
                  `:v&&!s?i`
                      <div class="kp-empty" role="alert">
                        Candle 상점 카탈로그를 불러오지 못했습니다.
                      </div>
                    `:i`
                      <div class="kp-empty">
                        ${s?.status==="disabled"?`Candle 상점 비활성: ${s.reason??"disabled"}`:"Candle 상점이 꺼져 있습니다 (초상화 장신구 전용 보상 화폐)."}
                      </div>
                    `:i`
                  <div class="kp-empty" data-testid="candle-catalog-token-locked" role="status">
                    Candle 상점 카탈로그 조회는 토큰 인증 싱글유저 세션 전용입니다.
                  </div>
                `}
        </section>
      </div>

      <!-- Candle Personal History -->
      <section class="kp-card" aria-label="Candle 원장 이력">
        <div class="kp-card-head">
          <h3>Candle Ledger History (${a?.recent_events.length??0})</h3>
        </div>
        <${ee}
          data=${a?.recent_events??[]}
          columns=${B}
          getRowId=${e=>String(e.seq)}
          maxHeight=${260}
          emptyLabel="Candle 원장 이벤트 없음"
          caption="Keeper Candle Ledger History"
        />
      </section>
    </div>
  `}export{Re as KeeperPortraitCandleTab};
