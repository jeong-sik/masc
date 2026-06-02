# `role="radiogroup"` / `role="radio"` — Single-choice form

> SPEC v0.1 §5.4 — pattern catalog

## 사용 시점

- 단일 선택 (branch selector, channel chooser, theme selector)
- 옵션 수가 고정적이고 SR에게 "N 중 1 선택"을 알려야 할 때
- 시각적으로 라디오 버튼이 아니어도 의미가 라디오라면 ARIA로 표현

## 사용하지 말 것

- 콘텐츠 전환 (그건 `tablist`)
- 복수 선택 (그건 checkbox 또는 `aria-pressed` 토글)
- form value가 아닌 단순 view filter (그건 toolbar + `aria-pressed`)

## 필수 attribute

| Attribute | 값 | 위치 |
|-----------|-----|------|
| `role` | `"radiogroup"` | 부모 |
| `aria-label` | "Branch selection" 등 | 부모 |
| `role` | `"radio"` | 각 옵션 |
| `aria-checked` | `"true"` / `"false"` | 각 옵션 |
| `tabIndex` | checked만 `0`, 나머지 `-1` | 각 옵션 (roving) |
| `aria-label` | 옵션 의미 | 텍스트가 안 보이거나 메타데이터가 추가 정보일 때 |

## JSX 예시 — `dashboard/design-system/preview/cb-group-i.jsx`

```jsx
<div className="br-list" role="radiogroup" aria-label="Branch list">
  {P2i.branches.map(b => (
    <div key={b.name}
         role="radio"
         aria-checked={b.name === sel}
         aria-label={`${b.name} · ${b.tag} · ${b.status} · ${b.ahead} ahead, ${b.behind} behind · HEAD ${b.head}`}
         tabIndex={0}
         onClick={() => setSel(b.name)}
         onKeyDown={(e) => {
           if (e.key === 'Enter' || e.key === ' ') {
             e.preventDefault();
             setSel(b.name);
           }
         }}
         className={`row ${b.name === sel ? 'on' : ''}`}>
      {/* visual content with aria-hidden */}
    </div>
  ))}
</div>
```

## Bonsai 예시 (제안 패턴)

```ocaml
let radiogroup ~options ~selected ~on_select ~label =
  Vdom.Node.div
    ~attrs:[ Attr.role "radiogroup"
           ; Attr.create "aria-label" label ]
    (List.map options ~f:(fun (id, label) ->
      let checked = String.equal id selected in
      Vdom.Node.div
        ~attrs:[ Attr.role "radio"
               ; Attr.create "aria-checked" (Bool.to_string checked)
               ; Attr.create "aria-label" label
               ; Attr.tabindex (if checked then 0 else -1)
               ; Attr.on_click (fun _ -> on_select id) ]
        [ ... ]))
```

## 키보드 동작 (필수)

| Key | 동작 |
|-----|------|
| `↑` `↓` (또는 `←` `→`) | 이전/다음 옵션 + 자동 선택 |
| `Home` | 첫 옵션 |
| `End` | 마지막 옵션 |
| `Tab` | radiogroup 진입/탈출만 (그룹 내부 이동은 화살표) |

## Screen reader 기대값

| SR | Announcement |
|----|--------------|
| VoiceOver | "Branch list · 5 options · feat/design-system-spec, radio button, checked, 2 of 5" |
| NVDA | "Branch list, grouping · feat/design-system-spec, radio button, checked, 2 of 5" |

## `aria-checked` vs `aria-selected` vs `aria-pressed`

| Attribute | 사용처 | 의미 |
|-----------|--------|------|
| `aria-checked` | radio, checkbox, switch | "값이 선택된 상태인가" |
| `aria-selected` | tab, listbox option, gridcell | "현재 보여지는/하이라이트된 것인가" |
| `aria-pressed` | toggle button | "버튼이 눌린 상태인가 (sticky)" |

이 셋을 혼용하면 SR이 무엇을 announce할지 결정 못 함. radiogroup에는 **반드시 `aria-checked`만**.

## Antipatterns

- ❌ `role="radio"`에 `aria-pressed` 부착 — 두 개의 state 모델 충돌
- ❌ 모든 옵션 `tabIndex={0}` — 그룹이 Tab 키 N번 (roving 깨짐). 단, 옵션 수가 적고 모두 Tab으로 도달해야 하는 특수 케이스라면 전체 `0` + Arrow 미구현도 받아들임. SPEC §5는 표준 권장.
- ❌ `aria-checked` 없이 visual class만 — SR 사용자가 활성 옵션 모름

## 관련 패턴

- 콘텐츠 전환 → `tablist.md`
- 다중 선택 → checkbox 또는 toolbar + `aria-pressed`
