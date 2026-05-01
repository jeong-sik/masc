// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest"
import { DAY_LABELS, HOUR_LABELS, CELL, GAP, LEFT_MARGIN, TOP_PAD, LEGEND_HEIGHT, intensityColor, canvasWidth, canvasHeight, drawHeatmap, hitTest } from "./activity-heatmap-draw"

describe("constants", () => {
  it("has 7 day labels", () => {
    expect(DAY_LABELS.length).toBe(7)
    expect(DAY_LABELS[0]).toBe("월")
    expect(DAY_LABELS[6]).toBe("일")
  })
  it("has expected hour labels", () => {
    expect(HOUR_LABELS).toEqual([0, 3, 6, 9, 12, 15, 18, 21])
  })
})

describe("intensityColor", () => {
  it("returns base color for count 0", () => {
    expect(intensityColor(0, 100)).toBe("var(--slate-800)")
  })
  it("returns base color for max 0", () => {
    expect(intensityColor(5, 0)).toBe("var(--slate-800)")
  })
  it("maps ratio <= 0.25", () => {
    expect(intensityColor(25, 100)).toBe("#0e4a5c")
  })
  it("maps ratio <= 0.50", () => {
    expect(intensityColor(50, 100)).toBe("#0e6e7e")
  })
  it("maps ratio <= 0.75", () => {
    expect(intensityColor(75, 100)).toBe("#14919b")
  })
  it("maps ratio > 0.75", () => {
    expect(intensityColor(100, 100)).toBe("var(--cyan)")
  })
})

describe("canvas dimensions", () => {
  it("canvasWidth is correct", () => {
    expect(canvasWidth()).toBe(LEFT_MARGIN + 24 * (CELL + GAP) - GAP)
  })
  it("canvasHeight is correct", () => {
    expect(canvasHeight()).toBe(TOP_PAD + 7 * (CELL + GAP) - GAP + LEGEND_HEIGHT)
  })
})

describe("hitTest", () => {
  it("returns null outside grid", () => {
    expect(hitTest(0, 0)).toBeNull()
  })
  it("hits first cell", () => {
    expect(hitTest(LEFT_MARGIN, TOP_PAD)).toEqual({ day: 0, hour: 0, count: 0 })
  })
  it("hits last cell", () => {
    expect(hitTest(LEFT_MARGIN + 23 * (CELL + GAP), TOP_PAD + 6 * (CELL + GAP))).toEqual({ day: 6, hour: 23, count: 0 })
  })
  it("returns null between cells", () => {
    expect(hitTest(LEFT_MARGIN + CELL + 1, TOP_PAD)).toBeNull()
  })
})

describe("drawHeatmap", () => {
  it("draws without error", () => {
    const ctx = {
      fillStyle: "",
      font: "",
      textAlign: "start",
      fillRect: vi.fn(),
      fillText: vi.fn(),
      beginPath: vi.fn(),
      roundRect: vi.fn(),
      fill: vi.fn(),
    } as unknown as CanvasRenderingContext2D
    const matrix = Array.from({ length: 7 }, () => Array.from({ length: 24 }, () => 0))
    drawHeatmap(ctx, matrix, 0)
    expect(ctx.fillRect).toHaveBeenCalled()
    expect(ctx.fillText).toHaveBeenCalled()
  })
})
