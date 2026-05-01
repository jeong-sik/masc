// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import {
  buildCredentialCreateRequest,
  coerceCredentialType,
  credentialStateBadgeClass,
  credentialStateLabel,
  credentialTypeBadgeClass,
  credentialTypeLabel,
  githubLoginCommand,
  isRecord,
  normalizeCredentialsResponse,
  parseCredentialState,
  sanitizeOptionalString,
} from "./credential-settings"

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

describe("credential state helpers", () => {
  it("parses known state objects", () => {
    expect(parseCredentialState({ kind: "Materialized", last_verified_at_unix_ms: "42" })).toEqual({
      kind: "Materialized",
      last_verified_at_unix_ms: "42",
      reason: null,
    })
    expect(parseCredentialState(null)).toBeNull()
    expect(parseCredentialState({ reason: "missing kind" })).toBeNull()
  })

  it("labels states and returns badge classes", () => {
    expect(credentialStateLabel({ kind: "Materialized" })).toBe("Materialized")
    expect(credentialStateLabel({ kind: "Stale" })).toBe("Stale")
    expect(credentialStateLabel({ kind: "Unmaterialized" })).toBe("Unmaterialized")
    expect(credentialStateLabel(null)).toBe("Unknown")
    expect(credentialStateBadgeClass({ kind: "Materialized" }).length).toBeGreaterThan(0)
  })
})

describe("normalizeCredentialsResponse", () => {
  it("normalizes wrapped credential rows", () => {
    expect(normalizeCredentialsResponse({
      credentials: [
        {
          id: "gh-main",
          name: "Main",
          cred_type: "github",
          username: "sangsu",
          gh_config_dir: "/tmp/gh",
          state: { kind: "Materialized" },
        },
      ],
    })).toEqual([
      expect.objectContaining({
        id: "gh-main",
        name: "Main",
        type: "github",
        username: "sangsu",
        gh_config_dir: "/tmp/gh",
        state: expect.objectContaining({ kind: "Materialized" }),
      }),
    ])
  })

  it("returns an empty list for unexpected payloads", () => {
    expect(normalizeCredentialsResponse({ credentials: null })).toEqual([])
    expect(normalizeCredentialsResponse(null)).toEqual([])
  })
})

describe("credential create request", () => {
  it("trims optional paths and omits web token", () => {
    expect(sanitizeOptionalString("  ")).toBeNull()
    expect(sanitizeOptionalString(" /tmp/key ")).toBe("/tmp/key")
    expect(buildCredentialCreateRequest({
      id: " gh-main ",
      name: "",
      type: "github",
      username: " sangsu ",
      gh_config_dir: " ",
      ssh_key_path: " /tmp/id_ed25519 ",
      oauth_method: "web",
      token: "secret",
    })).toEqual({
      id: "gh-main",
      cred_type: "github",
      username: "sangsu",
      gh_config_dir: null,
      ssh_key_path: "/tmp/id_ed25519",
      gpg_key_id: null,
      oauth_method: "web",
      token: null,
    })
  })

  it("keeps with-token payload and command quoting explicit", () => {
    expect(buildCredentialCreateRequest({
      id: "keepers",
      name: "",
      type: "github",
      username: "keeper-user",
      gh_config_dir: "/Users/dancer/me/.masc/github-identities/keepers/gh",
      oauth_method: "with_token",
      token: "ghp_x",
    })).toMatchObject({
      oauth_method: "with_token",
      token: "ghp_x",
    })
    expect(githubLoginCommand("/tmp/keeper's-gh")).toBe(
      "GH_CONFIG_DIR='/tmp/keeper'\\''s-gh' gh auth login --hostname github.com --git-protocol https --web --clipboard",
    )
  })
})
