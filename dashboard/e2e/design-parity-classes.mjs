// The one definition of "a component class", shared by every probe that compares
// rendered vocabulary. Kept in one file so the forward and reverse audits cannot
// disagree about what counts.
//
// Visible elements only: a class inside a collapsed drawer is not on screen, and
// counting it would report vocabulary the operator never sees. Tailwind
// utilities, variants and state modifiers are dropped — they describe how one
// element looks, not which component it is.
export const VISIBLE_COMPONENT_CLASSES = `(() => {
  const out = new Set()
  for (const el of document.querySelectorAll('.v2-app *')) {
    if (el.offsetParent === null && getComputedStyle(el).position !== 'fixed') continue
    const cn = typeof el.className === 'string' ? el.className : ''
    for (const c of cn.trim().split(/\\s+/)) {
      if (!c || c.length < 4) continue
      if (c.includes(':') || c.includes('[') || c.includes('/')) continue
      if (/^(is-|has-|on$|active|open|flex|grid|items-|justify-|text-|bg-|px-|py-|mx-|my-|mt-|mb-|ml-|mr-|pt-|pb-|pl-|pr-|gap-|w-|h-|min-|max-|rounded|border|shrink|grow|absolute|relative|inline|hidden|overflow|whitespace|font-|leading-|tracking-|truncate|select-|cursor-|transition|group|size-|self-|space-|animate|fade|slide|zoom|duration|delay|ease|fill-mode|sr-only|skip-link|order-|z-|top-|left-|right-|bottom-|opacity-|shadow|ring|outline|pointer-|touch-|scroll-|snap-|list-|align-|place-|col-|row-|basis-|object-|aspect-|backdrop|filter|blur|contrast|invert|saturate|sepia|origin-|rotate-|scale-|translate|skew-|first|last|only|odd|even|visited|checked|disabled|indeterminate|placeholder|before|after|marker|file|selection|caret|accent|appearance|resize|will-change|content-)/.test(c)) continue
      out.add(c)
    }
  }
  return [...out]
})()`

// Design classes are prefixed per component family (`ap-hist-row`, `bd-stateblock`).
// Rolling three-token names up to their family turns a list of classes into a
// list of components, which is the unit a rewrite is actually scoped by.
export function family(cls) {
  const parts = cls.split('-')
  return parts.length >= 3 ? `${parts[0]}-${parts[1]}-*` : cls
}
