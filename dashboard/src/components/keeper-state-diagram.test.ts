// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest"
import { transitionType, signalTone, badgeTone } from "./keeper-state-diagram"

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

describe("signalTone", () => {
  const warnClasses = "border-[var(--warn-24)] bg-[var(--warn-8)] text-[var(--color-status-warn)]"
  const errClasses = "border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)]"
  const okClasses = "border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]"

  it.each([
    ["bad", errClasses],
    ["warn", warnClasses],
    ["ok", okClasses],
  ])("maps %s to correct classes", (severity, expected) => {
    expect(signalTone(severity)).toBe(expected)
  })

  it("warns on unknown severity and returns warn tone", () => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(signalTone("unknown")).toBe(warnClasses)
    expect(warnSpy).toHaveBeenCalledWith(
      "[signalTone] unknown severity; rendering as warn",
      { severity: "unknown" },
    )
    warnSpy.mockRestore()
  })

  it.each([
    [null, warnClasses],
    [undefined, warnClasses],
    ["", warnClasses],
  ])("returns warn tone for %s without console warning", (input, expected) => {
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(signalTone(input)).toBe(expected)
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
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
