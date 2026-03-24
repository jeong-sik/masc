// Sparkline — inline Canvas 2D sparkline chart
// Draws a filled area, polyline stroke, and a dot at the latest data point.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'

interface SparklineProps {
  values: number[]
  width?: number
  height?: number
  color?: string
}

export function Sparkline({
  values,
  width = 120,
  height = 28,
  color = '#22d3ee',
}: SparklineProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas || values.length < 2) return

    const dpr = window.devicePixelRatio || 1
    canvas.width = width * dpr
    canvas.height = height * dpr
    canvas.style.width = `${width}px`
    canvas.style.height = `${height}px`

    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    const padY = 3
    const min = Math.min(...values)
    const max = Math.max(...values)
    const range = max - min || 1

    function toX(i: number): number {
      return (i / (values.length - 1)) * width
    }

    function toY(v: number): number {
      return height - padY - ((v - min) / range) * (height - padY * 2)
    }

    // Filled area
    ctx.beginPath()
    ctx.moveTo(toX(0), height)
    for (let i = 0; i < values.length; i++) {
      ctx.lineTo(toX(i), toY(values[i]!))
    }
    ctx.lineTo(toX(values.length - 1), height)
    ctx.closePath()

    // Parse color for fill opacity
    ctx.fillStyle = color.startsWith('#')
      ? `${color}18`
      : color.replace(/[\d.]+\)$/, '0.08)')
    ctx.fill()

    // Polyline stroke
    ctx.beginPath()
    ctx.moveTo(toX(0), toY(values[0]!))
    for (let i = 1; i < values.length; i++) {
      ctx.lineTo(toX(i), toY(values[i]!))
    }
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.lineJoin = 'round'
    ctx.lineCap = 'round'
    ctx.stroke()

    // Dot at latest data point
    const lastIdx = values.length - 1
    const lastVal = values[lastIdx]!
    ctx.beginPath()
    ctx.arc(toX(lastIdx), toY(lastVal), 2.5, 0, Math.PI * 2)
    ctx.fillStyle = color
    ctx.fill()
  }, [values, width, height, color])

  if (values.length < 2) return null

  return html`<canvas ref=${canvasRef} class="block" />`
}
