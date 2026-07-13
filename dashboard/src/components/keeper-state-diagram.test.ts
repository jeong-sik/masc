// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { transitionType, badgeTone } from "./keeper-state-diagram"

// RFC-0135 PR-2: the local `normalizePhase` export was removed; phase
// normalization now flows through `toKeeperPhase` (keeper-store-normalize)
// which is covered by `keeper-store-normalize.test.ts`. The two unmapped
// cases this file previously asserted (passthrough of unknown phase, null
// for falsy inputs) become the caller's fallback (`?? raw`) responsibility
// at the two render sites (keeper-state-diagram.ts:290, 292).

describe("transitionType", () => {
  it("extracts type from object", () => {
    expect(transitionType({ type: "operator_approve" })).toBe("operator approve")
  })

  it("returns 'event' for object with empty type", () => {
    expect(transitionType({ type: "  " })).toBe("event")
  })

  it("returns 'event' for object without type", () => {
    expect(transitionType({ foo: "bar" })).toBe("event")
  })

  it.each([
    [null, "event"],
    [undefined, "event"],
    ["string", "event"],
    [42, "event"],
  ])("returns 'event' for %s", (input, expected) => {
    expect(transitionType(input)).toBe(expected)
  })
})

describe("badgeTone", () => {
  const okClasses = "border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]"
  const errClasses = "border-[var(--err-border)] bg-[var(--bad-10)] text-[var(--color-status-err)]"

  it("returns ok tone for true", () => {
    expect(badgeTone(true)).toBe(okClasses)
  })

  it("returns err tone for false", () => {
    expect(badgeTone(false)).toBe(errClasses)
  })
})
