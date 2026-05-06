// Checkbox — consistent checkbox primitive for forms and toggles.
//
// Props are a strict whitelist — htm/preact function components do NOT
// implicitly spread unlisted props to children. This matters more for
// <input type="checkbox"> than for most primitives: without `id` a
// `<label for="...">` can't resolve, and without `ariaLabel` /
// `ariaLabelledby` a screen reader reading the checkbox alone has no
// accessible name at all. If you add a new prop to the interface below,
// also add it to the JSX — missing entries silently drop, which is how
// two earlier callers (ActionButton pre-refactor, TextInput pre-refactor)
// ended up shipping orphan labels.

import { html } from 'htm/preact'
import { ringFocusClasses } from './ring'

const CHECKBOX_BASE = `w-4 h-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] cursor-pointer transition-colors hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })} accent-[var(--color-accent-fg)]`

export type CheckboxCheckedState = 'unset' | 'true' | 'false'
export type CheckboxA11yHook = 'aria-label' | 'aria-labelledby' | 'id' | 'none'

export interface CheckboxSummary {
  readonly checkedState: CheckboxCheckedState
  readonly checked: boolean
  readonly disabled: boolean
  readonly hasCustomClass: boolean
  readonly classNameLength: number
  readonly hasId: boolean
  readonly idLength: number
  readonly hasName: boolean
  readonly nameLength: number
  readonly a11yHook: CheckboxA11yHook
  readonly hasAriaLabel: boolean
  readonly ariaLabelLength: number
  readonly hasAriaLabelledby: boolean
  readonly ariaLabelledbyLength: number
  readonly hasValue: boolean
  readonly valueLength: number
  readonly hasTestId: boolean
  readonly testIdLength: number
  readonly hasOnChange: boolean
  readonly hasOnClick: boolean
}

export interface CheckboxProps {
  checked?: boolean
  disabled?: boolean
  class?: string
  /** Forwarded to the DOM id so `<label for="...">` can resolve. Without
      this, external labels are orphan and screen readers read "checkbox"
      with no name. */
  id?: string
  /** Form field name for native submit + FormData serialization. */
  name?: string
  /** Accessible name when no visible label is associated via `for`. */
  ariaLabel?: string
  /** Reference another element's id as the accessible name. Useful when
      the label sits near the checkbox but isn't wrapped around it. */
  ariaLabelledby?: string
  /** The submitted form value when the checkbox is checked. Distinct
      from `checked`: `value` is the string that ends up in FormData. */
  value?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      checkbox without coupling to DOM position. */
  testId?: string
  onChange?: (checked: boolean) => void
  /** Click handler that receives the raw Event. Use this when the
      checkbox sits inside a clickable parent (a row or a card) and
      you need `event.stopPropagation()` to prevent the parent's
      click from also firing. `onChange` runs alongside it for state
      updates; `onClick` is purely for event-flow control. */
  onClick?: (e: Event) => void
}

function hasNonEmptyString(value: string | undefined): boolean {
  return value !== undefined && value !== ''
}

function checkedState(checked: boolean | undefined): CheckboxCheckedState {
  if (checked === undefined) return 'unset'
  return checked ? 'true' : 'false'
}

function a11yHook({
  id,
  ariaLabel,
  ariaLabelledby,
}: {
  id?: string
  ariaLabel?: string
  ariaLabelledby?: string
}): CheckboxA11yHook {
  if (hasNonEmptyString(ariaLabelledby)) return 'aria-labelledby'
  if (hasNonEmptyString(ariaLabel)) return 'aria-label'
  if (hasNonEmptyString(id)) return 'id'
  return 'none'
}

export function summarizeCheckbox({
  checked,
  disabled,
  class: cx,
  id,
  name,
  ariaLabel,
  ariaLabelledby,
  value,
  testId,
  onChange,
  onClick,
}: CheckboxProps): CheckboxSummary {
  return {
    checkedState: checkedState(checked),
    checked: checked === true,
    disabled: disabled === true,
    hasCustomClass: hasNonEmptyString(cx),
    classNameLength: cx?.length ?? 0,
    hasId: hasNonEmptyString(id),
    idLength: id?.length ?? 0,
    hasName: hasNonEmptyString(name),
    nameLength: name?.length ?? 0,
    a11yHook: a11yHook({ id, ariaLabel, ariaLabelledby }),
    hasAriaLabel: hasNonEmptyString(ariaLabel),
    ariaLabelLength: ariaLabel?.length ?? 0,
    hasAriaLabelledby: hasNonEmptyString(ariaLabelledby),
    ariaLabelledbyLength: ariaLabelledby?.length ?? 0,
    hasValue: hasNonEmptyString(value),
    valueLength: value?.length ?? 0,
    hasTestId: hasNonEmptyString(testId),
    testIdLength: testId?.length ?? 0,
    hasOnChange: onChange !== undefined,
    hasOnClick: onClick !== undefined,
  }
}

export function Checkbox({
  checked,
  disabled,
  class: cx,
  id,
  name,
  ariaLabel,
  ariaLabelledby,
  value,
  testId,
  onChange,
  onClick,
}: CheckboxProps) {
  const summary = summarizeCheckbox({
    checked,
    disabled,
    class: cx,
    id,
    name,
    ariaLabel,
    ariaLabelledby,
    value,
    testId,
    onChange,
    onClick,
  })
  const handleChange = onChange === undefined
    ? undefined
    : (e: Event) => { onChange((e.target as HTMLInputElement).checked) }
  return html`
    <input
      type="checkbox"
      id=${id}
      name=${name}
      value=${value}
      class="${CHECKBOX_BASE} ${cx ?? ''}"
      checked=${checked}
      disabled=${disabled}
      aria-label=${ariaLabel}
      aria-labelledby=${ariaLabelledby}
      data-checkbox
      data-checkbox-checked-state=${summary.checkedState}
      data-checkbox-checked=${summary.checked}
      data-checkbox-disabled=${summary.disabled}
      data-checkbox-has-custom-class=${summary.hasCustomClass}
      data-checkbox-class-length=${summary.classNameLength}
      data-checkbox-has-id=${summary.hasId}
      data-checkbox-id-length=${summary.idLength}
      data-checkbox-has-name=${summary.hasName}
      data-checkbox-name-length=${summary.nameLength}
      data-checkbox-a11y-hook=${summary.a11yHook}
      data-checkbox-has-aria-label=${summary.hasAriaLabel}
      data-checkbox-aria-label-length=${summary.ariaLabelLength}
      data-checkbox-has-aria-labelledby=${summary.hasAriaLabelledby}
      data-checkbox-aria-labelledby-length=${summary.ariaLabelledbyLength}
      data-checkbox-has-value=${summary.hasValue}
      data-checkbox-value-length=${summary.valueLength}
      data-checkbox-has-test-id=${summary.hasTestId}
      data-checkbox-test-id-length=${summary.testIdLength}
      data-checkbox-has-change-handler=${summary.hasOnChange}
      data-checkbox-has-click-handler=${summary.hasOnClick}
      data-testid=${testId}
      onChange=${handleChange}
      onClick=${onClick}
    />
  `
}
