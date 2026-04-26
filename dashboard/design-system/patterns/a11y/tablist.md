# `role="tablist"` / `role="tab"` — Content switcher

> SPEC v0.1 §5.3 — pattern catalog

## 사용 시점

- 컨텐츠 전환 UI (keeper inspector tab, deck mode, code mode chooser)
- 한 번에 하나의 panel만 보임
- 탭 활성화가 page navigation이 아니라 같은 컨테이너 내 콘텐츠 교체

## 사용하지 말 것

- 페이지 전환 (그건 `<a href>` + `aria-current` 사용)
- 단순 토글 버튼 (그건 `aria-pressed` 사용)
- 복수 선택 (그건 group + checkbox 사용)

## 필수 attribute

| Attribute | 값 | 위치 |
|-----------|-----|------|
| `role` | `"tablist"` | 부모 |
| `aria-label` | "Keeper inspector views" 등 | 부모 |
| `role` | `"tab"` | 각 탭 버튼 |
| `aria-selected` | `"true"` / `"false"` | 각 탭 |
| `aria-controls` | 해당 panel id | 각 탭 (강력 권장) |
| `tabIndex` | 활성 탭만 `0`, 나머지 `-1` | 각 탭 (roving tabindex) |
| `role` | `"tabpanel"` | 콘텐츠 영역 (옵션) |
| `id` | 탭의 aria-controls 대상 | tabpanel |

## JSX 예시 — `dashboard/design-system/preview/cb-group-h.jsx`

```jsx
function KeeperTabs({ tabs, active, onSelect, label }) {
  return (
    <div className="kt-tabs" role="tablist" aria-label={label}>
      {tabs.map(t => (
        <button key={t.id}
                type="button"
                role="tab"
                aria-selected={active === t.id}
                aria-controls={`tabpanel-${t.id}`}
                tabIndex={active === t.id ? 0 : -1}
                onClick={() => onSelect(t.id)}
                onKeyDown={(e) => {
                  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
                    e.preventDefault();
                    const idx = tabs.findIndex(x => x.id === active);
                    const next = e.key === 'ArrowLeft' ? idx - 1 : idx + 1;
                    onSelect(tabs[(next + tabs.length) % tabs.length].id);
                  }
                }}
                className={active === t.id ? 'on' : ''}>
          {t.label}
        </button>
      ))}
    </div>
  );
}
```

## Bonsai 예시 (제안 패턴 — 향후 적용)

```ocaml
let tablist ~tabs ~active ~on_select ~label =
  Vdom.Node.div
    ~attrs:[ Style.tablist
           ; Attr.role "tablist"
           ; Attr.create "aria-label" label ]
    (List.map tabs ~f:(fun (id, label) ->
      let selected = String.equal id active in
      Vdom.Node.button
        ~attrs:[ Attr.role "tab"
               ; Attr.create "aria-selected" (Bool.to_string selected)
               ; Attr.create "aria-controls" ("tabpanel-" ^ id)
               ; Attr.tabindex (if selected then 0 else -1)
               ; Attr.on_click (fun _ -> on_select id) ]
        [ Vdom.Node.text label ]))
```

## 키보드 동작 (필수)

| Key | 동작 |
|-----|------|
| `←` `→` | 이전/다음 탭으로 이동 + 자동 선택 |
| `Home` | 첫 탭 |
| `End` | 마지막 탭 |
| `Enter` `Space` | 명시적 활성화 (자동 선택 없는 모드일 때) |

**Roving tabindex**: 탭 그룹 전체가 Tab 키 1번에 진입, 그 후 ←→로 이동. 비활성 탭의 `tabIndex={-1}` 필수.

## Screen reader 기대값

| SR | Announcement |
|----|--------------|
| VoiceOver | "Activity, tab, selected, 1 of 4, tab list, Keeper inspector views" |
| NVDA | "Keeper inspector views, tab list, Activity tab, selected, 1 of 4" |

## Antipatterns

- ❌ 모든 탭이 `tabIndex={0}` — Tab 키 N번에 모든 탭 통과 (roving 깨짐)
- ❌ `role="tab"` 부모가 `role="tablist"`가 아닌 경우 — 탭 그룹 식별 불가
- ❌ `aria-selected` 없이 visual class만 — SR 사용자가 활성 탭 모름
- ❌ Arrow key 없이 click만 — 키보드 사용자에게 비효율적

## 관련 패턴

- 단일 선택 (라디오) → `radiogroup.md` (tab과 다름 — radio는 form value, tab은 view switch)
- 토글 버튼 → `aria-pressed` (별도 catalog 항목 없음)
- 페이지 전환 → `aria-current="page"`
