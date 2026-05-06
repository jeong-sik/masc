// TextInput / TextArea — consistent form inputs
// Replaces 6+ inline input patterns with consistent styling.
//
// Props are whitelisted (no implicit spread), so EVERY prop a caller
// expects to reach the DOM must be listed here explicitly. A missing
// entry silently drops the attribute — most painfully for `id`, which
// `<label for="...">` callers rely on for focus routing and screen
// readers. If you add a new prop to the interface, add it to the JSX
// below too.

import { html } from 'htm/preact'
import { ringFocusClasses } from './ring'

export type InputControlKind = 'text-input' | 'textarea'
export type InputAriaExpandedState = 'unset' | 'true' | 'false' | 'other'
export type TextAreaAutocompleteState = 'none' | 'partial' | 'complete'

export interface InputControlSummary {
  readonly kind: InputControlKind
  readonly type: string
  readonly rows: number
  readonly hasRows: boolean
  readonly hasValue: boolean
  readonly valueLength: number
  readonly hasPlaceholder: boolean
  readonly placeholderLength: number
  readonly disabled: boolean
  readonly required: boolean
  readonly hasCustomClass: boolean
  readonly classNameLength: number
  readonly hasId: boolean
  readonly hasName: boolean
  readonly hasAriaLabel: boolean
  readonly hasAutoComplete: boolean
  readonly hasTestId: boolean
  readonly autoFocus: boolean
  readonly ariaExpandedState: InputAriaExpandedState
  readonly autocompleteState: TextAreaAutocompleteState
}

// Form input surface — bg/fg/border + hover/focus state slots resolve
// from the input-* component-level token family (#11917). Future field
// retune (e.g. brand re-skin, dark/light) ripples to all 4 form
// primitives (TextInput/TextArea/NumberInput/Select) via these aliases.
// `placeholder` color and `focus-visible` border color remain inline
// pending follow-up token slots (input-placeholder, input-border-focus).
const INPUT_BASE = `w-full rounded-[var(--r-1)] bg-[var(--input-bg)] border border-[var(--input-border)] text-[var(--input-fg)] placeholder:text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--input-bg-hover)] focus-visible:bg-[var(--input-bg-focus)] focus-visible:border-[var(--info-border)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })}`

function nonEmptyLength(value: string | undefined): number {
  return value?.length ?? 0
}

function hasNonEmptyValue(value: string | undefined): boolean {
  return value !== undefined && value !== ''
}

function ariaExpandedState(value: boolean | string | undefined): InputAriaExpandedState {
  if (value === undefined) return 'unset'
  if (value === true || value === 'true') return 'true'
  if (value === false || value === 'false') return 'false'
  return 'other'
}

function textAreaAutocompleteState({
  role,
  ariaAutocomplete,
  ariaControls,
  ariaActiveDescendant,
}: {
  role?: string
  ariaAutocomplete?: string
  ariaControls?: string
  ariaActiveDescendant?: string
}): TextAreaAutocompleteState {
  const hasAutocompleteShape =
    hasNonEmptyValue(role) ||
    hasNonEmptyValue(ariaAutocomplete) ||
    hasNonEmptyValue(ariaControls) ||
    hasNonEmptyValue(ariaActiveDescendant)
  if (!hasAutocompleteShape) return 'none'
  if (
    role === 'combobox' &&
    hasNonEmptyValue(ariaAutocomplete) &&
    hasNonEmptyValue(ariaControls)
  ) return 'complete'
  return 'partial'
}

function summarizeInputControl({
  kind,
  type,
  rows,
  value,
  placeholder,
  disabled,
  required,
  className,
  id,
  name,
  ariaLabel,
  autoComplete,
  testId,
  autoFocus,
  role,
  ariaAutocomplete,
  ariaControls,
  ariaExpanded,
  ariaActiveDescendant,
}: {
  kind: InputControlKind
  type?: string
  rows?: number
  value?: string
  placeholder?: string
  disabled?: boolean
  required?: boolean
  className?: string
  id?: string
  name?: string
  ariaLabel?: string
  autoComplete?: string
  testId?: string
  autoFocus?: boolean
  role?: string
  ariaAutocomplete?: string
  ariaControls?: string
  ariaExpanded?: boolean | string
  ariaActiveDescendant?: string
}): InputControlSummary {
  return {
    kind,
    type: type ?? '',
    rows: rows ?? 0,
    hasRows: rows !== undefined,
    hasValue: hasNonEmptyValue(value),
    valueLength: nonEmptyLength(value),
    hasPlaceholder: hasNonEmptyValue(placeholder),
    placeholderLength: nonEmptyLength(placeholder),
    disabled: disabled === true,
    required: required === true,
    hasCustomClass: hasNonEmptyValue(className),
    classNameLength: nonEmptyLength(className),
    hasId: hasNonEmptyValue(id),
    hasName: hasNonEmptyValue(name),
    hasAriaLabel: hasNonEmptyValue(ariaLabel),
    hasAutoComplete: hasNonEmptyValue(autoComplete),
    hasTestId: hasNonEmptyValue(testId),
    autoFocus: autoFocus === true,
    ariaExpandedState: ariaExpandedState(ariaExpanded),
    autocompleteState: textAreaAutocompleteState({
      role,
      ariaAutocomplete,
      ariaControls,
      ariaActiveDescendant,
    }),
  }
}

export interface TextInputProps {
  id?: string
  value?: string
  placeholder?: string
  disabled?: boolean
  required?: boolean
  class?: string
  type?: string
  name?: string
  ariaLabel?: string
  autoComplete?: string
  /** Rendered as `data-testid` so E2E / unit tests can target this
      <input> without coupling to placeholder text (which may be i18n'd).
      Mirrors the same prop on Select. */
  testId?: string
  /** Native autofocus — applied on initial mount. */
  autoFocus?: boolean
  /** Forwards a Preact ref to the inner <input>. Distinct from `id` —
      use this when callers need imperative focus control (e.g. an
      external "edit" button that focuses this field) or when a parent
      dialog component takes `initialFocusRef`. Pass a `useRef` result. */
  inputRef?: { current: HTMLInputElement | null }
  onInput?: (e: Event) => void
  onKeyDown?: (e: KeyboardEvent) => void
  /** Fires when the input loses focus. Common pattern: commit pending
      filter/search value when the user tabs away (mirrors Enter handling
      in onKeyDown). Accepts FocusEvent so callers can use relatedTarget
      without a cast. */
  onBlur?: (e: FocusEvent) => void
}

export function summarizeTextInput({
  id,
  value,
  placeholder,
  disabled,
  required,
  class: cx,
  type = 'text',
  name,
  ariaLabel,
  autoComplete,
  testId,
  autoFocus,
}: TextInputProps): InputControlSummary {
  return summarizeInputControl({
    kind: 'text-input',
    type,
    value,
    placeholder,
    disabled,
    required,
    className: cx,
    id,
    name,
    ariaLabel,
    autoComplete,
    testId,
    autoFocus,
  })
}

export function TextInput({
  id,
  value,
  placeholder,
  disabled,
  required,
  class: cx,
  type = 'text',
  name,
  ariaLabel,
  autoComplete,
  testId,
  autoFocus,
  inputRef,
  onInput,
  onKeyDown,
  onBlur,
}: TextInputProps) {
  const summary = summarizeTextInput({
    id,
    value,
    placeholder,
    disabled,
    required,
    class: cx,
    type,
    name,
    ariaLabel,
    autoComplete,
    testId,
    autoFocus,
  })

  return html`
    <input
      ref=${inputRef}
      id=${id}
      type=${type}
      class="${INPUT_BASE} px-3 py-2 text-sm ${cx ?? ''}"
      value=${value}
      placeholder=${placeholder}
      disabled=${disabled}
      required=${required}
      name=${name}
      aria-label=${ariaLabel}
      autocomplete=${autoComplete}
      data-testid=${testId}
      data-text-input
      data-text-input-kind=${summary.kind}
      data-text-input-type=${summary.type}
      data-text-input-has-value=${summary.hasValue}
      data-text-input-value-length=${summary.valueLength}
      data-text-input-has-placeholder=${summary.hasPlaceholder}
      data-text-input-placeholder-length=${summary.placeholderLength}
      data-text-input-disabled=${summary.disabled}
      data-text-input-required=${summary.required}
      data-text-input-has-custom-class=${summary.hasCustomClass}
      data-text-input-class-length=${summary.classNameLength}
      data-text-input-has-id=${summary.hasId}
      data-text-input-has-name=${summary.hasName}
      data-text-input-has-aria-label=${summary.hasAriaLabel}
      data-text-input-has-autocomplete=${summary.hasAutoComplete}
      data-text-input-has-test-id=${summary.hasTestId}
      data-text-input-autofocus=${summary.autoFocus}
      autofocus=${autoFocus}
      onInput=${onInput}
      onKeyDown=${onKeyDown}
      onBlur=${onBlur}
    />
  `
}

export interface TextAreaProps {
  id?: string
  value?: string
  placeholder?: string
  rows?: number
  class?: string
  name?: string
  ariaLabel?: string
  ariaAutocomplete?: string
  ariaControls?: string
  ariaExpanded?: boolean | string
  ariaActiveDescendant?: string
  role?: string
  disabled?: boolean
  required?: boolean
  /** Forwards a Preact ref to the inner <textarea>. Mirrors TextInput —
      see that component's docstring for when this is needed (imperative
      focus, dialog `initialFocusRef`, etc.). */
  inputRef?: { current: HTMLTextAreaElement | null }
  onInput?: (e: Event) => void
  onKeyDown?: (e: KeyboardEvent) => void
}

export function summarizeTextArea({
  id,
  value,
  placeholder,
  rows,
  class: cx,
  name,
  ariaLabel,
  ariaAutocomplete,
  ariaControls,
  ariaExpanded,
  ariaActiveDescendant,
  role,
  disabled,
  required,
}: TextAreaProps): InputControlSummary {
  return summarizeInputControl({
    kind: 'textarea',
    rows,
    value,
    placeholder,
    disabled,
    required,
    className: cx,
    id,
    name,
    ariaLabel,
    role,
    ariaAutocomplete,
    ariaControls,
    ariaExpanded,
    ariaActiveDescendant,
  })
}

export function TextArea({
  id,
  value,
  placeholder,
  rows,
  class: cx,
  name,
  ariaLabel,
  ariaAutocomplete,
  ariaControls,
  ariaExpanded,
  ariaActiveDescendant,
  role,
  disabled,
  required,
  inputRef,
  onInput,
  onKeyDown,
}: TextAreaProps) {
  const summary = summarizeTextArea({
    id,
    value,
    placeholder,
    rows,
    class: cx,
    name,
    ariaLabel,
    ariaAutocomplete,
    ariaControls,
    ariaExpanded,
    ariaActiveDescendant,
    role,
    disabled,
    required,
  })

  return html`
    <textarea
      ref=${inputRef}
      id=${id}
      class="${INPUT_BASE} px-3 py-2 text-sm min-h-20 resize-y ${cx ?? ''}"
      placeholder=${placeholder}
      rows=${rows}
      name=${name}
      role=${role}
      aria-label=${ariaLabel}
      aria-autocomplete=${ariaAutocomplete}
      aria-controls=${ariaControls}
      aria-expanded=${ariaExpanded}
      aria-activedescendant=${ariaActiveDescendant}
      disabled=${disabled}
      required=${required}
      value=${value}
      data-textarea
      data-textarea-kind=${summary.kind}
      data-textarea-rows=${summary.rows}
      data-textarea-has-rows=${summary.hasRows}
      data-textarea-has-value=${summary.hasValue}
      data-textarea-value-length=${summary.valueLength}
      data-textarea-has-placeholder=${summary.hasPlaceholder}
      data-textarea-placeholder-length=${summary.placeholderLength}
      data-textarea-disabled=${summary.disabled}
      data-textarea-required=${summary.required}
      data-textarea-has-custom-class=${summary.hasCustomClass}
      data-textarea-class-length=${summary.classNameLength}
      data-textarea-has-id=${summary.hasId}
      data-textarea-has-name=${summary.hasName}
      data-textarea-has-aria-label=${summary.hasAriaLabel}
      data-textarea-aria-expanded-state=${summary.ariaExpandedState}
      data-textarea-autocomplete-state=${summary.autocompleteState}
      onInput=${onInput}
      onKeyDown=${onKeyDown}
    ></textarea>
  `
}
