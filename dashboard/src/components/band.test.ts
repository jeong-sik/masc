// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { render, h } from "preact"
import { Band } from "./band"

describe("Band", () => {
  it("renders default kind with top radius", () => {
    const container = document.createElement("div")
    render(h(Band, null), container)
    const band = container.querySelector("div")
    expect(band).not.toBeNull()
    expect(band!.getAttribute("data-kind")).toBe("default")
    expect(band!.style.background).toBe("var(--color-border-strong)")
    expect(band!.style.borderRadius).toBe("1px 1px 0px 0px")
    expect(band!.getAttribute("aria-hidden")).toBe("true")
  })

  it("renders running kind with glow shadow", () => {
    const container = document.createElement("div")
    render(h(Band, { kind: "running" }), container)
    const band = container.querySelector("div")
    expect(band!.getAttribute("data-kind")).toBe("running")
    expect(band!.style.background).toBe("var(--color-accent-fg)")
    expect(band!.style.boxShadow).toContain("0 0 6px")
  })

  it("renders ok kind", () => {
    const container = document.createElement("div")
    render(h(Band, { kind: "ok" }), container)
    const band = container.querySelector("div")
    expect(band!.getAttribute("data-kind")).toBe("ok")
    expect(band!.style.background).toBe("var(--color-status-ok)")
  })

  it("renders warn kind", () => {
    const container = document.createElement("div")
    render(h(Band, { kind: "warn" }), container)
    const band = container.querySelector("div")
    expect(band!.getAttribute("data-kind")).toBe("warn")
    expect(band!.style.background).toBe("var(--color-status-warn)")
  })

  it("renders err kind", () => {
    const container = document.createElement("div")
    render(h(Band, { kind: "err" }), container)
    const band = container.querySelector("div")
    expect(band!.getAttribute("data-kind")).toBe("err")
    expect(band!.style.background).toBe("var(--color-status-err)")
  })

  it("renders stalled kind", () => {
    const container = document.createElement("div")
    render(h(Band, { kind: "stalled" }), container)
    const band = container.querySelector("div")
    expect(band!.getAttribute("data-kind")).toBe("stalled")
    expect(band!.style.background).toBe("var(--color-status-stalled)")
  })

  it("disables top radius when topRadius is false", () => {
    const container = document.createElement("div")
    render(h(Band, { topRadius: false }), container)
    const band = container.querySelector("div")
    expect(band!.style.borderRadius).toBe("0px")
  })

  it("forwards testId", () => {
    const container = document.createElement("div")
    render(h(Band, { testId: "status-band" }), container)
    const band = container.querySelector("div")
    expect(band!.getAttribute("data-testid")).toBe("status-band")
  })
})
