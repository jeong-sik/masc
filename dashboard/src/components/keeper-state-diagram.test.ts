// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest"
import { normalizePhase, transitionType, signalTone, badgeTone } from "./keeper-state-diagram"

describe("normalizePhase", () => {
  it.each([
    ["Offline", "Offline"],
    ["Running", "Running"],
    ["Failing", "Failing"],
    ["overflowed", "Overflowed"],
    ["handing_off", "HandingOff"],
    ["paused", "Paused"],
    ["dead", "Dead"],
  ])("maps %s to %s", (input, expected) => {
    expect(normalizePhase(input)).toBe(expected)
  })

  it("returns unmapped phase as-is", () => {
    expect(normalizePhase("custom_phase")).toBe("custom_phase")
  })

  it.each([
    [null, null],
    [undefined, null],
    ["", null],
  ])("returns null for %s", (input, expected) => {
    expect(normalizePhase(input)).toBe(expected)
  })
})

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
