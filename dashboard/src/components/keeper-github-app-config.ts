import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { Save, Trash2, GitBranch, KeyRound, CheckCircle2, AlertCircle } from 'lucide-preact'
import {
  deleteKeeperSecretFile,
  deleteKeeperSecretEnv,
  setKeeperSecretFile,
  setKeeperSecretEnv,
  type KeeperSecretEnvSetMutation,
  type KeeperSecretFileSetMutation,
  type KeeperSecretEnvMutation,
  type KeeperSecretFileMutation,
} from '../api/dashboard-keeper-secrets'
import type { KeeperSecretProjection } from '../api/schemas/keeper-composite'
import { ActionButton } from './common/button'
import { TextArea, TextInput } from './common/input'
import { StatusChip } from './common/status-chip'

const GITHUB_APP_ID_ENV = 'MASC_GITHUB_APP_ID'
const GITHUB_APP_INSTALLATION_ID_ENV = 'MASC_GITHUB_APP_INSTALLATION_ID'
const GITHUB_APP_PRIVATE_KEY_PATH = '/github-app/private-key.pem'

type AppliedGithubAppSecret =
  | { kind: 'env'; name: typeof GITHUB_APP_ID_ENV | typeof GITHUB_APP_INSTALLATION_ID_ENV }
  | { kind: 'file'; path: typeof GITHUB_APP_PRIVATE_KEY_PATH }

interface KeeperGithubAppConfigPanelProps {
  projection: KeeperSecretProjection | null | undefined
  keeperName?: string
  onProjectionChange?: (projection: KeeperSecretProjection) => void
  setSecretEnv?: typeof setKeeperSecretEnv
  deleteSecretEnv?: typeof deleteKeeperSecretEnv
  setSecretFile?: typeof setKeeperSecretFile
  deleteSecretFile?: typeof deleteKeeperSecretFile
}

function messageFromError(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback
}

function hasGithubAppPrivateKey(projection: KeeperSecretProjection | null | undefined): boolean {
  return (projection?.file_mounts ?? []).some(
    (mount: { container_path: string }) => mount.container_path === GITHUB_APP_PRIVATE_KEY_PATH,
  )
}

async function rollbackAppliedGithubAppSecrets({
  keeperName,
  applied,
  deleteSecretEnv,
  deleteSecretFile,
}: {
  keeperName: string
  applied: AppliedGithubAppSecret[]
  deleteSecretEnv: typeof deleteKeeperSecretEnv
  deleteSecretFile: typeof deleteKeeperSecretFile
}): Promise<{ projection: KeeperSecretProjection | null; failures: string[] }> {
  let projection: KeeperSecretProjection | null = null
  const failures: string[] = []

  for (const secret of [...applied].reverse()) {
    try {
      if (secret.kind === 'env') {
        projection = await deleteSecretEnv(keeperName, {
          scope: 'keeper',
          name: secret.name,
        })
      } else {
        projection = await deleteSecretFile(keeperName, {
          scope: 'keeper',
          path: secret.path,
        })
      }
    } catch (error) {
      failures.push(messageFromError(error, `failed to roll back ${secret.kind}`))
    }
  }

  return { projection, failures }
}

export function KeeperGithubAppConfigPanel({
  projection,
  keeperName,
  onProjectionChange,
  setSecretEnv = setKeeperSecretEnv,
  deleteSecretEnv = deleteKeeperSecretEnv,
  setSecretFile = setKeeperSecretFile,
  deleteSecretFile = deleteKeeperSecretFile,
}: KeeperGithubAppConfigPanelProps) {
  const [appId, setAppId] = useState('')
  const [installationId, setInstallationId] = useState('')
  const [privateKeyPem, setPrivateKeyPem] = useState('')
  const [pending, setPending] = useState<'saving' | 'deleting' | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  // Detect presence in the projection
  const envNames = projection?.env_names ?? []
  const hasAppId = envNames.includes(GITHUB_APP_ID_ENV)
  const hasInstallationId = envNames.includes(GITHUB_APP_INSTALLATION_ID_ENV)
  const hasPrivateKey = hasGithubAppPrivateKey(projection)
  const hasCompleteConfig = hasAppId && hasInstallationId && hasPrivateKey
  const appIdValue = appId.trim()
  const installationIdValue = installationId.trim()
  const privateKeyPemValue = privateKeyPem.trim()
  const hasCompleteDraft = Boolean(appIdValue && installationIdValue && privateKeyPemValue)

  const canSave = Boolean(keeperName) && pending === null && hasCompleteDraft
  const canDelete = Boolean(keeperName) && pending === null && (hasAppId || hasInstallationId || hasPrivateKey)

  async function handleSave(event: Event) {
    event.preventDefault()
    if (!keeperName || pending !== null) return
    if (!hasCompleteDraft) {
      setError('GitHub App credentials must be saved as a complete bundle.')
      return
    }

    setPending('saving')
    setMessage(null)
    setError(null)

    try {
      let currentProjection = projection
      const steps: string[] = []
      const applied: AppliedGithubAppSecret[] = []

      try {
        const mutation: KeeperSecretEnvSetMutation = {
          scope: 'keeper',
          name: GITHUB_APP_ID_ENV,
          value: appIdValue,
        }
        currentProjection = await setSecretEnv(keeperName, mutation)
        applied.push({ kind: 'env', name: GITHUB_APP_ID_ENV })
        steps.push('App ID')

        const installationMutation: KeeperSecretEnvSetMutation = {
          scope: 'keeper',
          name: GITHUB_APP_INSTALLATION_ID_ENV,
          value: installationIdValue,
        }
        currentProjection = await setSecretEnv(keeperName, installationMutation)
        applied.push({ kind: 'env', name: GITHUB_APP_INSTALLATION_ID_ENV })
        steps.push('Installation ID')

        const fileMutation: KeeperSecretFileSetMutation = {
          scope: 'keeper',
          path: GITHUB_APP_PRIVATE_KEY_PATH,
          value: privateKeyPemValue,
        }
        currentProjection = await setSecretFile(keeperName, fileMutation)
        applied.push({ kind: 'file', path: GITHUB_APP_PRIVATE_KEY_PATH })
        steps.push('Private Key')
      } catch (saveError) {
        const rollback = await rollbackAppliedGithubAppSecrets({
          keeperName,
          applied,
          deleteSecretEnv,
          deleteSecretFile,
        })
        if (rollback.projection) {
          currentProjection = rollback.projection
          onProjectionChange?.(rollback.projection)
        }
        const saveMessage = messageFromError(saveError, 'Failed to save GitHub App configuration')
        const rollbackMessage =
          applied.length === 0
            ? ''
            : rollback.failures.length > 0
            ? ` Rollback failed: ${rollback.failures.join('; ')}`
            : ' Partially written GitHub App credentials were purged.'
        throw new Error(`${saveMessage}.${rollbackMessage}`)
      }

      if (currentProjection) {
        onProjectionChange?.(currentProjection)
      }

      setAppId('')
      setInstallationId('')
      setPrivateKeyPem('')
      setMessage(`Successfully saved: ${steps.join(', ')}`)
    } catch (e) {
      setError(messageFromError(e, 'Failed to save GitHub App configuration'))
    } finally {
      setPending(null)
    }
  }

  async function handleDelete() {
    if (!keeperName || pending !== null) return

    if (!confirm('Are you sure you want to delete the GitHub App configuration for this keeper?')) {
      return
    }

    setPending('deleting')
    setMessage(null)
    setError(null)

    try {
      let currentProjection = projection
      const steps: string[] = []

      // 1. App ID
      if (hasAppId) {
        const mutation: KeeperSecretEnvMutation = {
          scope: 'keeper',
          name: GITHUB_APP_ID_ENV,
        }
        currentProjection = await deleteSecretEnv(keeperName, mutation)
        steps.push('App ID')
      }

      // 2. Installation ID
      if (hasInstallationId) {
        const mutation: KeeperSecretEnvMutation = {
          scope: 'keeper',
          name: GITHUB_APP_INSTALLATION_ID_ENV,
        }
        currentProjection = await deleteSecretEnv(keeperName, mutation)
        steps.push('Installation ID')
      }

      // 3. Private Key PEM
      if (hasPrivateKey) {
        const mutation: KeeperSecretFileMutation = {
          scope: 'keeper',
          path: GITHUB_APP_PRIVATE_KEY_PATH,
        }
        currentProjection = await deleteSecretFile(keeperName, mutation)
        steps.push('Private Key')
      }

      if (currentProjection) {
        onProjectionChange?.(currentProjection)
      }

      setMessage(`Successfully removed: ${steps.join(', ')}`)
    } catch (e) {
      setError(messageFromError(e, 'Failed to delete GitHub App configuration'))
    } finally {
      setPending(null)
    }
  }

  return html`
    <div
      class="mt-4 rounded-[var(--r-5)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel)] p-5 shadow-sm transition-all hover:shadow"
      data-testid="keeper-github-app-config-panel"
    >
      <div class="flex items-center justify-between border-b border-[var(--color-border-divider)] pb-3">
        <div class="flex items-center gap-3">
          <div class="rounded-full bg-[var(--color-bg-panel-alt)] p-2.5 text-[var(--color-fg-primary)]">
            <${GitBranch} size=${20} strokeWidth=${2} aria-hidden="true" />
          </div>
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">OAuth / Git Credentials</div>
            <h4 class="text-sm font-bold text-[var(--color-fg-primary)]">GitHub App Installation (RFC-0236 §10)</h4>
          </div>
        </div>
        <${StatusChip} tone=${hasCompleteConfig ? 'warn' : 'neutral'} uppercase=${false}>
          ${hasCompleteConfig ? 'configured / unvalidated' : 'partial / inactive'}
        <//>
      </div>

      <div class="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div class="flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-panel-alt)] p-2.5">
          <${KeyRound} size=${14} class=${hasAppId ? 'text-[var(--color-status-success-fg)]' : 'text-[var(--color-fg-muted)]'} />
          <div class="min-w-0 flex-1">
            <div class="text-3xs font-semibold uppercase text-[var(--color-fg-muted)]">App ID</div>
            <div class="truncate text-xs font-medium text-[var(--color-fg-primary)]">
              ${hasAppId ? html`<span class="text-[var(--color-status-success-fg)] font-semibold">Configured</span>` : 'Not Configured'}
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-panel-alt)] p-2.5">
          <${KeyRound} size=${14} class=${hasInstallationId ? 'text-[var(--color-status-success-fg)]' : 'text-[var(--color-fg-muted)]'} />
          <div class="min-w-0 flex-1">
            <div class="text-3xs font-semibold uppercase text-[var(--color-fg-muted)]">Installation ID</div>
            <div class="truncate text-xs font-medium text-[var(--color-fg-primary)]">
              ${hasInstallationId ? html`<span class="text-[var(--color-status-success-fg)] font-semibold">Configured</span>` : 'Not Configured'}
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-panel-alt)] p-2.5">
          <${GitBranch} size=${14} class=${hasPrivateKey ? 'text-[var(--color-status-success-fg)]' : 'text-[var(--color-fg-muted)]'} />
          <div class="min-w-0 flex-1">
            <div class="text-3xs font-semibold uppercase text-[var(--color-fg-muted)]">Private Key PEM</div>
            <div class="truncate text-xs font-medium text-[var(--color-fg-primary)]">
              ${hasPrivateKey ? html`<span class="text-[var(--color-status-success-fg)] font-semibold">Uploaded</span>` : 'Not Uploaded'}
            </div>
          </div>
        </div>
      </div>

      <form class="mt-4 flex flex-col gap-4" onSubmit=${handleSave}>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <label class="flex flex-col gap-1.5 text-3xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            GitHub App ID
            <${TextInput}
              value=${appId}
              disabled=${pending !== null || !keeperName}
              placeholder="e.g. 1024356"
              ariaLabel="GitHub App ID"
              autoComplete="off"
              onInput=${(event: Event) => setAppId((event.currentTarget as HTMLInputElement).value)}
            />
          </label>

          <label class="flex flex-col gap-1.5 text-3xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            GitHub App Installation ID
            <${TextInput}
              value=${installationId}
              disabled=${pending !== null || !keeperName}
              placeholder="e.g. 89456123"
              ariaLabel="GitHub App Installation ID"
              autoComplete="off"
              onInput=${(event: Event) => setInstallationId((event.currentTarget as HTMLInputElement).value)}
            />
          </label>
        </div>

        <label class="flex flex-col gap-1.5 text-3xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          Private Key PEM Content
          <${TextArea}
            value=${privateKeyPem}
            rows=${4}
            disabled=${pending !== null || !keeperName}
            placeholder="-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----"
            ariaLabel="GitHub App Private Key PEM"
            onInput=${(event: Event) => setPrivateKeyPem((event.currentTarget as HTMLTextAreaElement).value)}
            class="font-mono text-xs"
          />
        </label>

        ${message ? html`
          <div class="flex items-center gap-2 rounded-[var(--r-1)] bg-[var(--color-status-success-bg)] p-3 text-xs text-[var(--color-status-success-fg)]">
            <${CheckCircle2} size=${14} class="flex-shrink-0" />
            <span>${message}</span>
          </div>
        ` : null}

        ${error ? html`
          <div class="flex items-center gap-2 rounded-[var(--r-1)] bg-[var(--color-status-error-bg)] p-3 text-xs text-[var(--color-status-error-fg)]">
            <${AlertCircle} size=${14} class="flex-shrink-0" />
            <span>${error}</span>
          </div>
        ` : null}

        <div class="flex justify-end gap-3 border-t border-[var(--color-border-divider)] pt-4">
          <${ActionButton}
            type="button"
            variant="danger"
            size="md"
            disabled=${!canDelete}
            ariaBusy=${pending === 'deleting'}
            class="inline-flex items-center gap-2"
            onClick=${handleDelete}
          >
            <${Trash2} size=${14} strokeWidth=${2.25} aria-hidden="true" />
            <span>${pending === 'deleting' ? 'Purging...' : 'Purge Credentials'}</span>
          <//>
          
          <${ActionButton}
            type="submit"
            size="md"
            disabled=${!canSave}
            ariaBusy=${pending === 'saving'}
            class="inline-flex items-center gap-2"
          >
            <${Save} size=${14} strokeWidth=${2.25} aria-hidden="true" />
            <span>${pending === 'saving' ? 'Saving...' : 'Save Configuration'}</span>
          <//>
        </div>
      </form>
    </div>
  `
}
