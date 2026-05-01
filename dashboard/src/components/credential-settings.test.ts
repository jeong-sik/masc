// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { coerceCredentialType, isRecord, credentialTypeLabel, credentialTypeBadgeClass } from "./credential-settings"

describe("coerceCredentialType", () => {
  it("returns github for unknown", () => {
    expect(coerceCredentialType("unknown")).toBe("github")
    expect(coerceCredentialType(null)).toBe("github")
  })
  it("returns gitlab", () => {
    expect(coerceCredentialType("gitlab")).toBe("gitlab")
  })
  it("returns local", () => {
    expect(coerceCredentialType("local")).toBe("local")
  })
})

describe("isRecord", () => {
  it("returns true for plain object", () => {
    expect(isRecord({})).toBe(true)
    expect(isRecord({ a: 1 })).toBe(true)
  })
  it("returns false for null", () => {
    expect(isRecord(null)).toBe(false)
  })
  it("returns false for arrays", () => {
    expect(isRecord([])).toBe(false)
  })
  it("returns false for primitives", () => {
    expect(isRecord("str")).toBe(false)
    expect(isRecord(1)).toBe(false)
  })
})

describe("credentialTypeLabel", () => {
  it("maps all types", () => {
    expect(credentialTypeLabel("github")).toBe("GitHub")
    expect(credentialTypeLabel("gitlab")).toBe("GitLab")
    expect(credentialTypeLabel("local")).toBe("Local")
  })
})

describe("credentialTypeBadgeClass", () => {
  it("returns non-empty strings", () => {
    expect(credentialTypeBadgeClass("github").length).toBeGreaterThan(0)
    expect(credentialTypeBadgeClass("gitlab").length).toBeGreaterThan(0)
    expect(credentialTypeBadgeClass("local").length).toBeGreaterThan(0)
  })
})
