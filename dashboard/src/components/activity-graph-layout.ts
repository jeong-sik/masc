// Fruchterman-Reingold force-directed layout
// Pure math, no DOM dependencies

export interface LayoutNode {
  id: string
  x: number
  y: number
  vx: number
  vy: number
  weight: number
}

export interface LayoutEdge {
  source: string
  target: string
  weight: number
}

export interface LayoutResult {
  positions: Map<string, { x: number; y: number }>
}

export function layoutGraph(
  nodes: Array<{ id: string; weight: number }>,
  edges: Array<{ source: string; target: string; weight: number }>,
  width: number,
  height: number,
  iterations = 120,
): LayoutResult {
  if (nodes.length === 0) {
    return { positions: new Map() }
  }

  const area = width * height
  const k = Math.sqrt(area / Math.max(nodes.length, 1))

  // Initialize positions in a circle
  const layoutNodes: LayoutNode[] = nodes.map((node, i) => {
    const angle = (2 * Math.PI * i) / nodes.length
    const radius = Math.min(width, height) * 0.35
    return {
      id: node.id,
      x: width / 2 + radius * Math.cos(angle),
      y: height / 2 + radius * Math.sin(angle),
      vx: 0,
      vy: 0,
      weight: node.weight,
    }
  })

  const nodeMap = new Map<string, LayoutNode>()
  for (const node of layoutNodes) {
    nodeMap.set(node.id, node)
  }

  // Filter edges to only include valid source/target
  const validEdges = edges.filter(
    e => nodeMap.has(e.source) && nodeMap.has(e.target) && e.source !== e.target,
  )

  let temperature = width / 4

  for (let iter = 0; iter < iterations; iter++) {
    // Reset velocities
    for (const node of layoutNodes) {
      node.vx = 0
      node.vy = 0
    }

    // Repulsive forces between all node pairs
    for (let i = 0; i < layoutNodes.length; i++) {
      for (let j = i + 1; j < layoutNodes.length; j++) {
        const a = layoutNodes[i]!
        const b = layoutNodes[j]!
        const dx = a.x - b.x
        const dy = a.y - b.y
        const dist = Math.max(Math.sqrt(dx * dx + dy * dy), 0.01)
        const force = (k * k) / dist

        const fx = (dx / dist) * force
        const fy = (dy / dist) * force

        a.vx += fx
        a.vy += fy
        b.vx -= fx
        b.vy -= fy
      }
    }

    // Attractive forces along edges
    for (const edge of validEdges) {
      const source = nodeMap.get(edge.source)!
      const target = nodeMap.get(edge.target)!
      const dx = target.x - source.x
      const dy = target.y - source.y
      const dist = Math.max(Math.sqrt(dx * dx + dy * dy), 0.01)
      const force = (dist * dist) / k
      // Stronger attraction for heavier edges
      const edgeMul = 1 + Math.log1p(edge.weight) * 0.3

      const fx = (dx / dist) * force * edgeMul
      const fy = (dy / dist) * force * edgeMul

      source.vx += fx
      source.vy += fy
      target.vx -= fx
      target.vy -= fy
    }

    // Gravity toward center (prevents disconnected components from drifting)
    const cx = width / 2
    const cy = height / 2
    for (const node of layoutNodes) {
      const dx = cx - node.x
      const dy = cy - node.y
      node.vx += dx * 0.01
      node.vy += dy * 0.01
    }

    // Apply forces with temperature limit
    for (const node of layoutNodes) {
      const speed = Math.sqrt(node.vx * node.vx + node.vy * node.vy)
      if (speed > 0) {
        const capped = Math.min(speed, temperature)
        node.x += (node.vx / speed) * capped
        node.y += (node.vy / speed) * capped
      }
      // Clamp to canvas bounds with padding
      const pad = 30
      node.x = Math.max(pad, Math.min(width - pad, node.x))
      node.y = Math.max(pad, Math.min(height - pad, node.y))
    }

    // Cool down
    temperature *= 0.95
  }

  const positions = new Map<string, { x: number; y: number }>()
  for (const node of layoutNodes) {
    positions.set(node.id, { x: node.x, y: node.y })
  }

  return { positions }
}
