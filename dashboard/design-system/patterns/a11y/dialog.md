# `role="dialog"` — Modal / drawer / confirm

> SPEC v0.1 §5.6 — pattern catalog

## 사용 시점

- 모달 (확인 prompt, 설정 패널)
- drawer (사이드 패널이 portal 또는 dimmed background와 함께 뜨는 경우)
- 일시적 콘텐츠인데 키보드 focus를 trap해야 하는 경우

## 사용하지 말 것

- 페이지 일부에 항상 보이는 패널 (그건 `region`)
- 자동으로 닫히는 toast (그건 `role="status"`)
- 인라인 dropdown menu (그건 `role="menu"` + `aria-haspopup`)

## 필수 attribute

| Attribute | 값 | 위치 | 이유 |
|-----------|-----|------|------|
| `role` | `"dialog"` | 부모 | dialog landmark |
| `aria-modal` | `"true"` | 부모 | 외부 콘텐츠 inert 표시 |
| `aria-labelledby` | 제목 element id | 부모 | dialog 제목 |
| `aria-describedby` | 설명 element id | 부모 (선택) | 추가 컨텍스트 |
| `tabIndex` | `-1` | 부모 (focus 받을 수 있게) | 첫 focus target |

## JSX 예시 (제안 패턴 — 현재 preview에 dialog 컴포넌트 부재)

```jsx
function ConfirmDialog({ titleId, descId, title, desc, onConfirm, onCancel }) {
  const ref = useRef(null);
  useEffect(() => { ref.current?.focus(); }, []);

  return (
    <div className="dialog-overlay">
      <div ref={ref}
           role="dialog"
           aria-modal="true"
           aria-labelledby={titleId}
           aria-describedby={descId}
           tabIndex={-1}
           onKeyDown={(e) => {
             if (e.key === 'Escape') {
               e.preventDefault();
               onCancel();
             }
           }}>
        <h2 id={titleId}>{title}</h2>
        <p id={descId}>{desc}</p>
        <button onClick={onConfirm}>Confirm</button>
        <button onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}
```

## Bonsai 예시 (제안 패턴)

```ocaml
let confirm_dialog ~title ~desc ~on_confirm ~on_cancel =
  Vdom.Node.div
    ~attrs:[ Style.dialog_overlay ]
    [ Vdom.Node.div
        ~attrs:[ Style.dialog
               ; Attr.role "dialog"
               ; Attr.create "aria-modal" "true"
               ; Attr.create "aria-labelledby" "dialog-title"
               ; Attr.create "aria-describedby" "dialog-desc"
               ; Attr.tabindex (-1)
               ; Attr.on_keydown (fun e ->
                   if String.equal e##.key "Escape"
                   then on_cancel
                   else Effect.Ignore) ]
        [ Vdom.Node.h2 ~attrs:[ Attr.id "dialog-title" ] [ Vdom.Node.text title ]
        ; Vdom.Node.p  ~attrs:[ Attr.id "dialog-desc"  ] [ Vdom.Node.text desc ]
        ; ... ] ]
```

## 키보드 동작 (필수)

| Key | 동작 |
|-----|------|
| `Esc` | dialog 닫기 (= cancel) |
| `Tab` | dialog 내부 focus 순환 (focus trap 필수) |
| `Shift+Tab` | 역방향 순환 |
| (open 시) | 첫 의미있는 element에 focus 자동 이동 |
| (close 시) | dialog 호출한 trigger element로 focus 복귀 |

**focus trap**은 dialog 내부의 `tabbable` element 첫/마지막을 wrap-around 시키는 로직. JSX는 `react-focus-trap`/`focus-trap-react`, Bonsai는 수동 구현 또는 `Vdom.Attr.on_keydown` + DOM API.

## Screen reader 기대값

| SR | Announcement (open 시) |
|----|------------------------|
| VoiceOver | "Confirm deletion, dialog · You are about to delete keeper-3. This cannot be undone. · Confirm button" |
| NVDA | "Confirm deletion · dialog · You are about to delete keeper-3. This cannot be undone." |

## Antipatterns

- ❌ `role="dialog"` 없이 visual modal만 — SR이 모달임을 모름, 외부 콘텐츠 계속 탐색 가능
- ❌ `aria-modal="true"` 없으면 SR이 외부와 분리하지 않음
- ❌ Esc 미구현 — 키보드 사용자가 갇힘
- ❌ focus가 자동 이동 안 함 — open 후 사용자가 Tab 1번 더 눌러야 dialog 진입
- ❌ close 후 focus가 body로 떨어짐 — trigger element로 복귀해야 흐름 유지
- ❌ `aria-labelledby` 없이 `aria-label`만 — 시각 제목과 SR 제목이 분리되어 동기화 깨짐 (둘 다 가능하지만 labelledby가 우선)

## 관련 패턴

- 비동기 알림 → `role="status"` (dialog보다 가벼움, focus trap 없음)
- inline expandable → `aria-expanded` + `aria-controls` (dialog 아님)
- dropdown menu → `role="menu"` + `aria-haspopup="menu"`
