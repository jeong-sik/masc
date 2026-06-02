// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest"
import { render, h } from "preact"
import { Btn, resolveVariant } from "./btn"

describe("resolveVariant", () => {
  it("returns default for undefined", () => {
    expect(resolveVariant(undefined)).toBe("default")
  })

  it("returns the passed variant", () => {
    expect(resolveVariant("primary")).toBe("primary")
    expect(resolveVariant("danger")).toBe("danger")
    expect(resolveVariant("ghost")).toBe("ghost")
  })
})

describe("Btn", () => {
  it("renders a button with default attributes", () => {
    const container = document.createElement("div")
    render(h(Btn, null, "Click"), container)
    const btn = container.querySelector("button")
    expect(btn).not.toBeNull()
    expect(btn!.getAttribute("type")).toBe("button")
    expect(btn!.textContent).toBe("Click")
  })

  it("applies variant data attribute and styles", () => {
    const container = document.createElement("div")
    render(h(Btn, { variant: "primary" }, "Save"), container)
    const btn = container.querySelector("button")
    expect(btn!.getAttribute("data-variant")).toBe("primary")
    expect(btn!.style.background).toContain("var(--color-accent-fg-dim)")
  })

  it("applies size data attribute and geometry", () => {
    const container = document.createElement("div")
    render(h(Btn, { size: "lg" }, "Big"), container)
    const btn = container.querySelector("button")
    expect(btn!.getAttribute("data-size")).toBe("lg")
    expect(btn!.style.height).toBe("28px")
  })

  it("renders icon mode as 22x22 square", () => {
    const container = document.createElement("div")
    render(h(Btn, { icon: true }, "X"), container)
    const btn = container.querySelector("button")
    expect(btn!.getAttribute("data-icon")).toBe("true")
    expect(btn!.style.width).toBe("22px")
    expect(btn!.style.height).toBe("22px")
    expect(btn!.style.padding).toBe("0px")
  })

  it("sets disabled state", () => {
    const container = document.createElement("div")
    render(h(Btn, { disabled: true }, "Off"), container)
    const btn = container.querySelector("button")
    expect(btn!.hasAttribute("disabled")).toBe(true)
    expect(btn!.style.opacity).toBe("0.5")
    expect(btn!.style.cursor).toBe("not-allowed")
  })

  it("forwards onClick handler", () => {
    const handler = vi.fn()
    const container = document.createElement("div")
    render(h(Btn, { onClick: handler }, "Go"), container)
    const btn = container.querySelector("button")
    btn!.click()
    expect(handler).toHaveBeenCalledTimes(1)
  })

  it("changes style on hover", async () => {
    const container = document.createElement("div")
    render(h(Btn, { variant: "primary" }, "Hover"), container)
    const btn = container.querySelector("button")!
    const idleBg = btn.style.background
    btn.dispatchEvent(new MouseEvent("mouseenter"))
    await new Promise((r) => setTimeout(r, 0))
    const hoverBg = container.querySelector("button")!.style.background
    expect(hoverBg).not.toBe(idleBg)
    expect(hoverBg).toContain("var(--color-accent-fg)")
  })

  it("forwards testId, ariaLabel, title, class", () => {
    const container = document.createElement("div")
    render(h(Btn, { testId: "my-btn", ariaLabel: "Close", title: "Close dialog", class: "mt-2" }), container)
    const btn = container.querySelector("button")
    expect(btn!.getAttribute("data-testid")).toBe("my-btn")
    expect(btn!.getAttribute("aria-label")).toBe("Close")
    expect(btn!.getAttribute("title")).toBe("Close dialog")
    expect(btn!.classList.contains("mt-2")).toBe(true)
  })

  it("respects explicit button type", () => {
    const container = document.createElement("div")
    render(h(Btn, { type: "submit" }, "Send"), container)
    const btn = container.querySelector("button")
    expect(btn!.getAttribute("type")).toBe("submit")
  })
})
