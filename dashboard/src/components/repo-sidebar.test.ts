// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { normalizeRepoStatus, repositoryRows, normalizeRepository, type Repository } from "./repo-sidebar"

describe("normalizeRepoStatus", () => {
  it("maps active", () => {
    expect(normalizeRepoStatus("active")).toBe("active")
  })
  it("maps paused", () => {
    expect(normalizeRepoStatus("paused")).toBe("paused")
  })
  it("maps cloning to active", () => {
    expect(normalizeRepoStatus("cloning")).toBe("active")
  })
  it("maps error", () => {
    expect(normalizeRepoStatus("error")).toBe("error")
  })
  it("defaults unknown to active", () => {
    expect(normalizeRepoStatus("unknown")).toBe("active")
    expect(normalizeRepoStatus(undefined)).toBe("active")
  })
  it("is case-insensitive", () => {
    expect(normalizeRepoStatus("ACTIVE")).toBe("active")
    expect(normalizeRepoStatus("Error")).toBe("error")
  })
})

describe("repositoryRows", () => {
  it("returns array as-is", () => {
    expect(repositoryRows([1, 2])).toEqual([1, 2])
  })
  it("extracts .repositories", () => {
    expect(repositoryRows({ repositories: [3] })).toEqual([3])
  })
  it("extracts .data when ok", () => {
    expect(repositoryRows({ ok: true, data: [4] })).toEqual([4])
  })
  it("returns empty for invalid", () => {
    expect(repositoryRows(null)).toEqual([])
    expect(repositoryRows("str")).toEqual([])
    expect(repositoryRows({})).toEqual([])
  })
})

describe("normalizeRepository", () => {
  it("returns null for non-object", () => {
    expect(normalizeRepository(null)).toBeNull()
    expect(normalizeRepository("str")).toBeNull()
  })
  it("returns null when id and name missing", () => {
    expect(normalizeRepository({})).toBeNull()
  })
  it("builds minimal repo", () => {
    const r = normalizeRepository({ id: "r1", name: "Repo" }) as Repository
    expect(r.id).toBe("r1")
    expect(r.name).toBe("Repo")
    expect(r.default_branch).toBe("main")
    expect(r.status).toBe("active")
    expect(r.auto_sync).toBe(false)
    expect(r.sync_interval).toBe(300)
    expect(r.credential_id).toBeNull()
  })
  it("preserves all fields", () => {
    const r = normalizeRepository({
      id: "r2",
      name: "Full",
      url: "http://example.com",
      local_path: "/path",
      default_branch: "dev",
      status: "paused",
      auto_sync: true,
      sync_interval: 60,
      credential_id: "c1",
      created_at: "2024-01-01",
      updated_at: 1700000000,
    }) as Repository
    expect(r.url).toBe("http://example.com")
    expect(r.local_path).toBe("/path")
    expect(r.default_branch).toBe("dev")
    expect(r.status).toBe("paused")
    expect(r.auto_sync).toBe(true)
    expect(r.sync_interval).toBe(60)
    expect(r.credential_id).toBe("c1")
    expect(r.created_at).toBe("2024-01-01")
    expect(r.updated_at).toBe(1700000000)
  })
})
