// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest"

const { currentTimeRangeFilter } = vi.hoisted(() => ({
  currentTimeRangeFilter: vi.fn(),
}))

vi.mock("../observatory-filter-store", () => ({
  currentTimeRangeFilter,
}))

import { activityRange, DEFAULT_ACTIVITY_RANGE } from "./activity-graph-store"

describe("activityRange", () => {
  it("returns filter value when present", () => {
    currentTimeRangeFilter.mockReturnValue("24h")
    expect(activityRange()).toBe("24h")
  })

  it("returns default when filter is null", () => {
    currentTimeRangeFilter.mockReturnValue(null)
    expect(activityRange()).toBe(DEFAULT_ACTIVITY_RANGE)
  })

  it("returns default when filter is undefined", () => {
    currentTimeRangeFilter.mockReturnValue(undefined)
    expect(activityRange()).toBe(DEFAULT_ACTIVITY_RANGE)
  })
})
