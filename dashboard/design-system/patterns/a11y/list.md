# `role="list"` / `role="listitem"` — Homogeneous collection

> SPEC v0.1 §5.2 — pattern catalog

## 사용 시점

- keeper 리스트, swimlane row 컬렉션, log line 컬렉션
- DOM이 `<ul><li>`가 아닌데 의미는 list인 경우 (CSS reset 또는 div-based layout)
- 항목 수와 위치를 SR에게 알릴 가치가 있는 경우

## 사용하지 말 것

- `<ul><li>` native element를 쓰는 경우 (native가 더 우수)
- 항목들이 *서로 다른 의미*를 가질 때 (그땐 region 또는 group 사용)
- 단일 선택을 위한 항목들 (그건 `radiogroup` 사용)

## 필수 attribute

| Attribute | 값 | 위치 | 이유 |
|-----------|-----|------|------|
| `role` | `"list"` | 부모 컨테이너 | list landmark |
| `aria-label` | "Active keepers" 등 | 부모 | list 의미 |
| `role` | `"listitem"` | 각 자식 | 항목 식별 |
| `aria-label` | 항목 의미 | 각 자식 (텍스트가 안 보이면) | 항목 announce |

## JSX 예시 — `dashboard/design-system/preview/cb-group-a.jsx`

```jsx
<div className="kpi-strip" role="list" aria-label={`${kpis.length} key indicators`}>
  {kpis.map(k => (
    <div key={k.id}
         role="listitem"
         aria-label={`${k.label} · ${k.value} · ${k.delta}`}
         className="kpi">
      <span className="lbl" aria-hidden="true">{k.label}</span>
      <span className="val" aria-hidden="true">{k.value}</span>
      <span className="dlt" aria-hidden="true">{k.delta}</span>
    </div>
  ))}
</div>
```

## Bonsai 예시 — `dashboard_bonsai/src/dead_keepers_view.ml`

```ocaml
Vdom.Node.div
  ~attrs:[ Attr.role "list"
         ; Attr.create "aria-label" "Dead keepers list" ]
  (List.map keepers ~f:(fun k ->
     Vdom.Node.div
       ~attrs:[ Attr.role "listitem"
              ; Attr.create "aria-label" (sprintf "%s · %s" k.name k.cause) ]
       [ ... ]))
```

## 키보드 동작

별도 동작 없음 (탐색용). 항목이 활성화 가능하면 별도 `tabIndex={0}` + `onKeyDown`이 필요하지만, 그 시점에선 list가 아니라 `tablist`/`radiogroup`/`grid` 검토.

## Screen reader 기대값

| SR | Announcement |
|----|--------------|
| VoiceOver | "list, 5 items" → "keeper-1 active 12 tasks done, list item, 1 of 5" |
| NVDA | "list with 5 items" → "keeper-1 active 12 tasks done, list item, 1 of 5" |

## Antipatterns

- ❌ 부모 `role="list"` 없이 자식만 `role="listitem"` — orphan listitem은 무효
- ❌ 자식 div에 `role="listitem"`을 박았는데 텍스트가 다 `aria-hidden="true"` — 라벨 없는 listitem
- ❌ 매 listitem에 동일 aria-label (예: "Item") — 항목 구분 불가
- ❌ list 안에 list가 깊게 중첩 — 평면 listitem이 SR에게 더 명확

## 관련 패턴

- 단일 선택 → `radiogroup.md`
- tab 전환 → `tablist.md`
- 시간순 누적 → `log.md`
