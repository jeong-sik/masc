// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { isWorkSection } from "./work"

describe("isWorkSection", () => {
  it.each([
    ["board", true],
    ["planning", true],
    ["repositories", true],
    ["collab-mvp", true],
    ["verification", true],
  ])("returns true for %s", (v, expected) => {
    expect(isWorkSection(v)).toBe(expected)
  })

  it.each([
    ["unknown", false],
    ["", false],
    [undefined, false],
    ["settings", false],
  ])("returns false for %s", (v, expected) => {
    expect(isWorkSection(v)).toBe(expected)
  })
})
