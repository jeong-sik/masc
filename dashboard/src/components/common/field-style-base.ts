/**
 * Form-field base class string.
 *
 * `keeper-config-panel.ts` used this byte-identical
 * `const fieldStyle = 'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded-[var(--r-1)] py-2 px-3 font-sans focus:outline-none focus:border-accent-fg/50 focus:ring-1 focus:ring-accent-fg/50 transition-[border-color,box-shadow] duration-[var(--t-med)] shadow-inset'`
 * value for `<input>` / `<select>` / `<textarea>` elements with
 * `class="${fieldStyle}"` (and a couple of `${fieldStyle} resize-y …`
 * extensions for textarea variants).
 *
 * Note on `TextInput` / `TextArea` (../common/input.ts): those primitives
 * are the canonical SSOT for form inputs but their `INPUT_BASE` resolves
 * through the component-level input token family
 * (`--input-bg`, `--input-border`, `--input-fg`), whereas the two call
 * sites here paint with raw `bg-card/60`, `border-card-border`,
 * `text-text-strong`, plus a `backdrop-blur-sm` + `shadow-inset` finish
 * that the component-level slots do not currently carry. Migrating each
 * call site onto `TextInput` / `TextArea` requires deciding how the
 * raw-token palette plus the inset/blur affordance maps onto the
 * component-level tokens — a design call that lives outside an
 * SSOT-extraction sweep. Until then, this constant captures the shared
 * shape so the two files stop drifting.
 */
export const FIELD_STYLE_BASE =
  'w-full bg-card/60 backdrop-blur-sm text-text-strong text-sm border border-card-border rounded-[var(--r-1)] py-2 px-3 font-sans focus:outline-none focus:border-accent-fg/50 focus:ring-1 focus:ring-accent-fg/50 transition-[border-color,box-shadow] duration-[var(--t-med)] shadow-inset'
