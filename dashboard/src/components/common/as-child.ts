// as-child.ts — polymorphic asChild prop for headless primitives
//
// Kimi design system sec01 1.1.2: Inject headless behavior into a single
// child element while preserving its own props (href, target, etc.).
// Enables Chip-as-Trigger, Link-as-Button, etc.

import { cloneElement, isValidElement, h } from 'preact'
import type { VNode, ComponentChildren } from 'preact'

function mergeClass(a: unknown, b: unknown): string | undefined {
  const sa = typeof a === 'string' ? a : ''
  const sb = typeof b === 'string' ? b : ''
  if (sa && sb) return `${sa} ${sb}`
  return sa || sb || undefined
}

function chainHandler(
  childHandler: unknown,
  parentHandler: unknown
): (e: Event) => void {
  return (e: Event) => {
    if (typeof childHandler === 'function') {
      ;(childHandler as (e: Event) => void)(e)
    }
    if (typeof parentHandler === 'function') {
      ;(parentHandler as (e: Event) => void)(e)
    }
  }
}

/** Merge parent props into child props, composing classes and handlers. */
export function mergeProps(
  childProps: Record<string, unknown>,
  parentProps: Record<string, unknown>
): Record<string, unknown> {
  const merged: Record<string, unknown> = { ...parentProps }

  for (const [key, value] of Object.entries(childProps)) {
    if (key === 'class' || key === 'className') {
      merged[key] = mergeClass(value, merged[key])
    } else if (
      key.startsWith('on') &&
      typeof value === 'function' &&
      typeof merged[key] === 'function'
    ) {
      merged[key] = chainHandler(value, merged[key])
    } else {
      merged[key] = value
    }
  }

  return merged
}

/** Clone a VNode with merged props, or return a fallback wrapper. */
export function asChildClone(
  children: ComponentChildren,
  props: Record<string, unknown>
): VNode {
  if (isValidElement(children)) {
    const child = children as VNode
    const childProps =
      (child.props as Record<string, unknown> | undefined) ?? {}
    return cloneElement(child, mergeProps(childProps, props))
  }

  // Fallback: wrap in a span when child is not a valid element
  return h('span', props, children) as unknown as VNode
}
