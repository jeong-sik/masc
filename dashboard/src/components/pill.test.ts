// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { render, h } from "preact"
import { Pill, pillAriaLabel } from "./pill"

describe("pillAriaLabel", () => {
  it("returns override when provided", () => {
    expect(pillAriaLabel({ children: "A", ariaLabel: "Override" }, "A")).toBe("Override")
  })

  it("returns content for neutral kind", () => {
    expect(pillAriaLabel({ children: "OK", kind: "neutral" }, "OK")).toBe("OK")
  })

  it("returns content for undefined kind", () => {
    expect(pillAriaLabel({ children: "OK" }, "OK")).toBe("OK")
  })

  it("appends state for running kind", () => {
    expect(pillAriaLabel({ children: "Build", kind: "running" }, "Build")).toBe("Build (running)")
  })

  it("appends state for err kind", () => {
    expect(pillAriaLabel({ children: "Test", kind: "err" }, "Test")).toBe("Test (failing)")
  })
})

describe("Pill", () => {
  it("renders neutral without role or dot", () => {
    const container = document.createElement("div")
    render(h(Pill, null, "Idle"), container)
    const pill = container.querySelector("span")
    expect(pill).not.toBeNull()
    expect(pill!.getAttribute("data-kind")).toBe("neutral")
    expect(pill!.getAttribute("role")).toBeNull()
    expect(pill!.querySelector("span")).toBeNull()
    expect(pill!.textContent).toBe("Idle")
  })

  it("renders running with dot and status role", () => {
    const container = document.createElement("div")
    render(h(Pill, { kind: "running", dot: true }, "Build"), container)
    const pill = container.querySelector("span")
    expect(pill!.getAttribute("data-kind")).toBe("running")
    expect(pill!.getAttribute("role")).toBe("status")
    const dot = pill!.querySelector("span")
    expect(dot).not.toBeNull()
    expect(pill!.textContent).toBe("Build")
  })

  it("suppresses dot for neutral even when dot=true", () => {
    const container = document.createElement("div")
    render(h(Pill, { kind: "neutral", dot: true }, "None"), container)
    const pill = container.querySelector("span")
    expect(pill!.querySelector("span")).toBeNull()
  })

  it("applies kind-specific colors", () => {
    const kinds = ["ok", "warn", "err", "info", "stalled"] as const
    for (const kind of kinds) {
      const container = document.createElement("div")
      render(h(Pill, { kind }, kind), container)
      const pill = container.querySelector("span") as HTMLElement
      expect(pill.style.color).toContain("var(--color-status-")
      expect(pill.getAttribute("data-kind")).toBe(kind)
    }
  })

  it("forwards testId and title", () => {
    const container = document.createElement("div")
    render(h(Pill, { testId: "status-pill", title: "Details" }, "On"), container)
    const pill = container.querySelector("span")
    expect(pill!.getAttribute("data-testid")).toBe("status-pill")
    expect(pill!.getAttribute("title")).toBe("Details")
  })

  it("computes aria-label from content", () => {
    const container = document.createElement("div")
    render(h(Pill, { kind: "warn" }, "Slow"), container)
    const pill = container.querySelector("span")
    expect(pill!.getAttribute("aria-label")).toBe("Slow (warning)")
  })

  it("uses uppercase transform and mono font", () => {
    const container = document.createElement("div")
    render(h(Pill, null, "text"), container)
    const pill = container.querySelector("span") as HTMLElement
    expect(pill.style.textTransform).toBe("uppercase")
    expect(pill.style.fontFamily).toContain("monospace")
  })
})
