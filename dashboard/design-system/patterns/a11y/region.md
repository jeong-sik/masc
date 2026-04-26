# `role="region"` — Named landmark

> SPEC v0.1 §5.1 — pattern catalog

## 사용 시점

- 데이터 시각화 박스(KPI, lifeline, swimlane mock 등)
- 명명된 콘텐츠 영역인데 `<section>` 의미만으로 부족할 때
- screen reader 사용자가 landmark navigation으로 점프할 가치가 있는 영역

## 사용하지 말 것

- 너무 작은 부분(버튼, 단일 라벨)
- 페이지 전체 레이아웃 (이미 `<main>`, `<nav>` 등의 native landmark가 있음)
- 동질적 항목의 컬렉션 (그건 `role="list"` 사용)

## 필수 attribute

| Attribute | 값 | 이유 |
|-----------|-----|------|
| `role` | `"region"` | landmark로 식별 |
| `aria-label` | 영역 의미를 한 문장으로 | landmark navigation 시 announce |
| (또는) `aria-labelledby` | 가까운 헤딩 id | label이 페이지에 보이는 텍스트면 이쪽 |

## JSX 예시 — `dashboard/design-system/preview/cb-group-j.jsx`

```jsx
<div className="lifeline-card"
     role="region"
     aria-label={`Lifeline · ${lane.name} · ${lane.points.length}-point sparkline`}>
  <div className="lifeline-svg">{/* ... */}</div>
</div>
```

## Bonsai 예시 — `dashboard_bonsai/src/keepers_view.ml`

```ocaml
let directory ~keepers =
  Vdom.Node.div
    ~attrs:[ Style.directory
           ; Attr.role "region"
           ; Attr.create "aria-label" "Live keepers" ]
    [ ... ]
```

## 키보드 동작

별도 동작 없음. landmark navigation은 screen reader 단축키(NVDA `D`, VoiceOver rotor 등)로 처리.

## Screen reader 기대값

| SR | Announcement |
|----|--------------|
| VoiceOver | "Lifeline, keeper-1, 24-point sparkline, region" |
| NVDA | "region, Lifeline keeper-1 24-point sparkline" |

## Antipatterns

- ❌ `aria-label` 없이 `role="region"`만 — 이름 없는 landmark는 SR rotor에서 무용지물
- ❌ `role="region"`을 `<button>`/`<a>` 같은 interactive element에 부착 — interactive role과 충돌
- ❌ 시각 mock의 SVG/canvas 자체에 `role="region"` — 부모 div에 부착하고 SVG는 `aria-hidden="true"`

## 관련 패턴

- 동질적 항목 컬렉션 → `list.md`
- 시간순 추가 콘텐츠 → `log.md`
- 콘텐츠 전환 UI → `tablist.md`
