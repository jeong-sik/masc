// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import {
  isRepoSelected,
  isAllowAll,
  toggleAllowAll,
  hasChanges,
  buildRepoSetFromMapping,
} from "./keeper-repo-mapping"
import type { KeeperRepoMapping } from "./keeper-repo-mapping"

describe("isRepoSelected", () => {
  it("returns true when current is '*', ignoring repoId", () => {
    expect(isRepoSelected("k1", "repo-a", "*")).toBe(true)
    expect(isRepoSelected("k1", "repo-b", "*")).toBe(true)
  })

  it("returns true when repoId is in the set", () => {
    expect(isRepoSelected("k1", "repo-a", new Set(["repo-a", "repo-b"]))).toBe(true)
  })

  it("returns false when repoId is not in the set", () => {
    expect(isRepoSelected("k1", "repo-c", new Set(["repo-a", "repo-b"]))).toBe(false)
  })

  it("returns false for empty set", () => {
    expect(isRepoSelected("k1", "repo-a", new Set())).toBe(false)
  })
})

describe("isAllowAll", () => {
  it("returns true for '*'", () => {
    expect(isAllowAll("k1", "*")).toBe(true)
  })

  it("returns false for a Set", () => {
    expect(isAllowAll("k1", new Set(["repo-a"]))).toBe(false)
    expect(isAllowAll("k1", new Set())).toBe(false)
  })
})

describe("toggleAllowAll", () => {
  it("switches '*' to empty Set", () => {
    const result = toggleAllowAll("k1", "*")
    expect(result).toBeInstanceOf(Set)
    expect((result as Set<string>).size).toBe(0)
  })

  it("switches Set to '*'", () => {
    const result = toggleAllowAll("k1", new Set(["repo-a"]))
    expect(result).toBe("*")
  })

  it("switches empty Set to '*'", () => {
    const result = toggleAllowAll("k1", new Set())
    expect(result).toBe("*")
  })
})

describe("hasChanges", () => {
  it("returns false when both are '*'", () => {
    expect(hasChanges("k1", "*", "*")).toBe(false)
  })

  it("returns true when original is '*' and draft is a Set", () => {
    expect(hasChanges("k1", "*", new Set())).toBe(true)
    expect(hasChanges("k1", "*", new Set(["repo-a"]))).toBe(true)
  })

  it("returns true when original is a Set and draft is '*'", () => {
    expect(hasChanges("k1", new Set(), "*")).toBe(true)
    expect(hasChanges("k1", new Set(["repo-a"]), "*")).toBe(true)
  })

  it("returns false when both sets have same elements", () => {
    expect(hasChanges("k1", new Set(["a", "b"]), new Set(["b", "a"]))).toBe(false)
  })

  it("returns true when sizes differ", () => {
    expect(hasChanges("k1", new Set(["a"]), new Set(["a", "b"]))).toBe(true)
    expect(hasChanges("k1", new Set(["a", "b"]), new Set(["a"]))).toBe(true)
  })

  it("returns true when elements differ", () => {
    expect(hasChanges("k1", new Set(["a"]), new Set(["b"]))).toBe(true)
  })

  it("returns false for two empty sets", () => {
    expect(hasChanges("k1", new Set(), new Set())).toBe(false)
  })
})

describe("buildRepoSetFromMapping", () => {
  it("returns '*' when allow_all is true", () => {
    const mapping: KeeperRepoMapping = {
      keeper_id: "k1",
      keeper_name: "Keeper 1",
      allowed_repos: ["repo-a"],
      allow_all: true,
    }
    expect(buildRepoSetFromMapping(mapping)).toBe("*")
  })

  it("returns Set from allowed_repos when allow_all is false", () => {
    const mapping: KeeperRepoMapping = {
      keeper_id: "k1",
      keeper_name: "Keeper 1",
      allowed_repos: ["repo-a", "repo-b"],
      allow_all: false,
    }
    const result = buildRepoSetFromMapping(mapping)
    expect(result).toBeInstanceOf(Set)
    expect((result as Set<string>).has("repo-a")).toBe(true)
    expect((result as Set<string>).has("repo-b")).toBe(true)
    expect((result as Set<string>).has("repo-c")).toBe(false)
  })

  it("returns empty Set for empty allowed_repos", () => {
    const mapping: KeeperRepoMapping = {
      keeper_id: "k1",
      keeper_name: "Keeper 1",
      allowed_repos: [],
      allow_all: false,
    }
    const result = buildRepoSetFromMapping(mapping)
    expect(result).toBeInstanceOf(Set)
    expect((result as Set<string>).size).toBe(0)
  })
})
