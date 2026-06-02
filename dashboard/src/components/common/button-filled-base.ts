/**
 * Filled-button base class string.
 *
 * Three component files (`credential-settings.ts`, `keeper-repo-mapping.ts`,
 * `keeper-config-panel.ts`) each shipped a byte-identical local
 * `const btnBase = 'py-1.5 px-4 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none'`
 * and used it as the prefix for `${btnBase} bg-X text-Y` filled buttons.
 *
 * Note on `ActionButton` (../common/button.ts): that component is the
 * canonical SSOT for buttons but its variants resolve through the
 * component-level token layer (`--button-ok-bg`, `--button-primary-bg`,
 * etc.), whereas the call sites here paint with raw role tokens
 * (`--color-status-ok`, `--color-bg-hover`, `--purple`). Migrating each
 * call site onto `ActionButton` requires deciding how the raw-token
 * palette maps onto component-level tokens — a design call that lives
 * outside an SSOT-extraction sweep. Until then, this constant captures
 * the shared shape (padding, radius, text size/weight, cursor, no border)
 * so the three files stop drifting.
 *
 * A fourth file (`components/keeper-shared.ts`) ships a separate
 * `const btnBase = '… text-xs font-medium cursor-pointer transition-colors border'`
 * — visually a different design intent (outlined / transitioned) and
 * deliberately left unchanged here. The shared name there is a homonym,
 * not a missed SSOT.
 */
export const BTN_FILLED_BASE =
  'py-1.5 px-4 rounded-[var(--r-1)] text-xs font-semibold cursor-pointer border-none'
