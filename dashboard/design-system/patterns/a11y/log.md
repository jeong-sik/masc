# `role="log"` / `aria-live` — Time-sequenced append

> SPEC v0.1 §5.5 — pattern catalog

## 사용 시점

- 시간순 누적 콘텐츠 (operator nudge log, activity feed, terminal output)
- 새 항목이 도착하면 자동으로 SR에게 announce해야 할 때
- 사용자가 항목 하나하나에 focus를 두지 않고 흐름으로 인지하는 영역

## 사용하지 말 것

- 정적 항목 컬렉션 (그건 `role="list"`)
- 사용자가 explicit하게 다음 항목으로 이동하는 UI (그건 list + 키보드 nav)
- 한 번 뜨고 사라지는 toast (그건 `role="status"` 또는 `role="alert"`)

## 필수 attribute

| Attribute | 값 | 위치 | 이유 |
|-----------|-----|------|------|
| `role` | `"log"` | 부모 | log landmark |
| `aria-live` | `"polite"` | 부모 | 새 항목 시 announce, 다른 announcement 가로채지 않음 |
| `aria-label` | "Operator nudges" 등 | 부모 | log 의미 |
| `role` | `"listitem"` | 각 항목 | 항목 식별 |
| `aria-atomic` | `"false"` (default) | 부모 | 변경된 부분만 announce (전체 재 announce 회피) |

`role="log"`는 implicit `aria-live="polite"`를 가지지만, 명시적으로 부착하는 게 SR 호환성에 안전.

## JSX 예시 — `dashboard/design-system/preview/cb-group-i.jsx`

```jsx
<div role="log"
     aria-live="polite"
     aria-label={`${P2i.nudges.length} nudges`}
     style={{background:'var(--bg-0)'}}>
  {P2i.nudges.map(n => (
    <div key={n.id}
         className="nd-row"
         role="listitem"
         aria-label={`${n.at.replace('Z','')} · ${n.channel} · to ${n.to.map(k => '@' + k).join(', ')} · ${n.body} · ${n.ack ? 'acknowledged' : 'pending acknowledgment'}`}>
      {/* visual content with aria-hidden */}
    </div>
  ))}
</div>
```

## Bonsai 예시 — `dashboard_bonsai/src/logs_view.ml` (적용 시점)

```ocaml
let nudge_log ~nudges =
  Vdom.Node.div
    ~attrs:[ Style.nudge_log
           ; Attr.role "log"
           ; Attr.create "aria-live" "polite"
           ; Attr.create "aria-label" (sprintf "%d nudges" (List.length nudges)) ]
    (List.map nudges ~f:(fun n ->
      Vdom.Node.div
        ~attrs:[ Attr.role "listitem"
               ; Attr.create "aria-label" (nudge_summary n) ]
        [ ... ]))
```

## 키보드 동작

별도 동작 없음 (탐색용). 사용자가 log 항목에 focus 두고 싶으면 listitem에 `tabIndex={0}` 부착, 단 그러면 `aria-live`의 announcement가 focus와 경쟁할 수 있음 — 보통 log는 read-only.

## Screen reader 기대값

| SR | Announcement |
|----|--------------|
| VoiceOver (새 항목 도착) | "10:23 · hint · to @sangsu · 'check the deploy' · pending acknowledgment" |
| NVDA (idle) | log 영역 진입 시 "log · 5 items" |

## `aria-live="polite"` vs `"assertive"`

| 값 | 사용처 | 효과 |
|----|--------|------|
| `polite` | 일반 log, 상태 갱신, status pill | 다른 announcement 끝난 후 발화 |
| `assertive` | 즉시 사용자 주의 필요 (error, security alert) | 진행 중 announcement 끊고 즉시 발화 |

assertive 남용은 SR 사용자에게 압박감을 주므로 신중히. log는 거의 항상 polite.

## Antipatterns

- ❌ `aria-atomic="true"` — 새 항목 추가 시 전체 log를 재 announce해서 시끄러움
- ❌ `role="log"`인데 `aria-label` 없음 — 익명 log
- ❌ visible text 없는 listitem (모든 자식이 `aria-hidden="true"`)에 부모 aria-label도 없음 — silent log
- ❌ log 항목을 click 가능한 button으로 — log는 read-only, action은 list + 명시 button

## 관련 패턴

- 단발 status 메시지 → `role="status"` + `aria-live="polite"` (log보다 가벼움)
- 즉시 alert → `role="alert"`
- 대화형 메시지 → `role="region"` + 내부에 form
