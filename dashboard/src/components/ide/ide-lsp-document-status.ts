import { signal } from '@preact/signals'

export type LspDocumentConnection =
  | { kind: 'connecting' }
  | { kind: 'connected' }
  | { kind: 'disconnected'; reason: string }
  | { kind: 'unavailable'; reason: string }
  | { kind: 'failed'; reason: string }
  | { kind: 'unsupported' }

export type LspDocumentDiagnostics =
  | { kind: 'pending' }
  | { kind: 'complete'; count: number }
  | { kind: 'failed'; reason: string }
  | { kind: 'unversioned'; count: number }

export interface LspDocumentStatus {
  readonly filePath: string
  readonly scope: string
  readonly language: string
  readonly version: number
  readonly command: string | null
  readonly connection: LspDocumentConnection
  readonly diagnostics: LspDocumentDiagnostics
}

export const lspDocumentStatus = signal<LspDocumentStatus | null>(null)
let owner: object | null = null

export function ownLspDocument(nextOwner: object): void { owner = nextOwner }
export function ownsLspDocument(candidate: object): boolean { return owner === candidate }
export function publishLspDocument(nextOwner: object, status: LspDocumentStatus | null): boolean {
  if (owner !== nextOwner) return false
  lspDocumentStatus.value = status
  return true
}

export function lspDocumentStatusLabel(status: LspDocumentStatus): string {
  const prefix = `LSP ${status.language}`
  switch (status.connection.kind) {
    case 'connecting': return `${prefix} connecting`
    case 'disconnected': return `${prefix} disconnected`
    case 'unavailable': return `${prefix} unavailable`
    case 'failed': return `${prefix} failed`
    case 'unsupported': return `${prefix} unsupported`
    case 'connected':
      switch (status.diagnostics.kind) {
        case 'pending': return `${prefix} checking`
        case 'complete': return `${prefix} ${status.diagnostics.count} diagnostics`
        case 'failed': return `${prefix} diagnostics failed`
        case 'unversioned': return `${prefix} ${status.diagnostics.count} reported · version unconfirmed`
      }
  }
}

export function lspDocumentStatusDetail(status: LspDocumentStatus): string {
  const details = [`${status.filePath} · document version ${status.version}`,
    status.command ?? 'Language server command not reported',
    'Browser editor analysis; Keeper tool usage is recorded separately.']
  if ('reason' in status.connection) details.push(status.connection.reason)
  if ('reason' in status.diagnostics) details.push(status.diagnostics.reason)
  if (status.diagnostics.kind === 'unversioned') {
    details.push('The server did not identify the document version; this result cannot confirm the updated source.')
  }
  return details.join('\n')
}
