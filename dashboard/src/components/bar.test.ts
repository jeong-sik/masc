// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { render, h } from "preact"
import { Bar, barPercent } from "./bar"

describe("barPercent", () => {
  it("returns 0 for NaN", () => {
    expect(barPercent(NaN)).toBe(0)
  })

  it("clamps negative to 0", () => {
    expect(barPercent(-10)).toBe(0)
  })

  it("clamps over 100 to 100", () => {
    expect(barPercent(150)).toBe(100)
  })

  it("rounds to integer", () => {
    expect(barPercent(66.6)).toBe(67)
  })

  it("passes through valid values", () => {
    expect(barPercent(0)).toBe(0)
    expect(barPercent(50)).toBe(50)
    expect(barPercent(100)).toBe(100)
  })
})

describe("Bar", () => {
  it("renders progressbar role and aria values", () => {
    const container = document.createElement("div")
    render(h(Bar, { value: 42 }), container)
    const bar = container.querySelector("[role=\"progressbar\"]")
    expect(bar).not.toBeNull()
    expect(bar!.getAttribute("aria-valuenow")).toBe("42")
    expect(bar!.getAttribute("aria-valuemin")).toBe("0")
    expect(bar!.getAttribute("aria-valuemax")).toBe("100")
    expect(bar!.getAttribute("aria-label")).toBe("42%")
  })

  it("sets fill width from value", () => {
    const container = document.createElement("div")
    render(h(Bar, { value: 75 }), container)
    const fill = container.querySelector("span[aria-hidden=\"true\"]")
    expect(fill).not.toBeNull()
    expect((fill as HTMLElement).style.width).toBe("75%")
  })

  it("applies kind-specific fill color", () => {
    const container = document.createElement("div")
    render(h(Bar, { value: 30, kind: "err" }), container)
    const bar = container.querySelector("[role=\"progressbar\"]")
    expect(bar!.getAttribute("data-kind")).toBe("err")
    const fill = container.querySelector("span[aria-hidden=\"true\"]") as HTMLElement
    expect(fill.style.background).toBe("var(--color-status-err)")
  })

  it("omits transition when noTransition is true", () => {
    const container = document.createElement("div")
    render(h(Bar, { value: 50, noTransition: true }), container)
    const fill = container.querySelector("span[aria-hidden=\"true\"]") as HTMLElement
    expect(fill.style.transition).toBe("")
  })

  it("uses custom aria-label when provided", () => {
    const container = document.createElement("div")
    render(h(Bar, { value: 80, ariaLabel: "Eighty percent complete" }), container)
    const bar = container.querySelector("[role=\"progressbar\"]")
    expect(bar!.getAttribute("aria-label")).toBe("Eighty percent complete")
  })

  it("forwards testId and title", () => {
    const container = document.createElement("div")
    render(h(Bar, { value: 10, testId: "prog", title: "Progress" }), container)
    const bar = container.querySelector("[role=\"progressbar\"]")
    expect(bar!.getAttribute("data-testid")).toBe("prog")
    expect(bar!.getAttribute("title")).toBe("Progress")
  })
})
