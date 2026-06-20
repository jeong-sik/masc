import { parse } from 'postcss'

export function declarationsForSelector(css: string, selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}
  let found = false

  parse(css).walkRules((rule) => {
    if (!rule.selectors.includes(selector)) return

    found = true
    rule.walkDecls((decl) => {
      declarations[decl.prop] = decl.value.trim()
    })
  })

  if (!found) {
    throw new Error(`Selector not found: ${selector}`)
  }

  return declarations
}
