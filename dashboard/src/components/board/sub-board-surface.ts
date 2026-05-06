import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { Hash, Plus, RefreshCw, Users } from 'lucide-preact'
import { createSubBoard, fetchSubBoards } from '../../api/board'
import type { SubBoard, SubBoardAccess } from '../../types'
import { ActionButton } from '../common/button'
import { EmptyState, LoadingState } from '../common/feedback-state'
import { TextArea, TextInput } from '../common/input'
import { Select } from '../common/select'
import { SurfaceCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { showToast } from '../common/toast'

const ACCESS_OPTIONS: Array<{ value: SubBoardAccess; label: string }> = [
  { value: 'open', label: 'Open' },
  { value: 'members_only', label: 'Members only' },
  { value: 'owner_only', label: 'Owner only' },
]

function accessLabel(access: SubBoardAccess): string {
  return ACCESS_OPTIONS.find(option => option.value === access)?.label ?? 'Open'
}

function parseMembers(value: string): string[] {
  return value
    .split(',')
    .map(member => member.trim())
    .filter(Boolean)
}

function slugFromName(name: string): string {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

function SubBoardRow({ board }: { board: SubBoard }) {
  return html`
    <${SurfaceCard} variant="compact" testId=${`sub-board-row-${board.slug}`}>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0 space-y-2">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="inline-flex size-7 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]" aria-hidden="true">
              <${Hash} size=${15} />
            </span>
            <div class="min-w-0">
              <h3 class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${board.name || board.slug}</h3>
              <div class="truncate font-mono text-2xs text-[var(--color-fg-muted)]">/${board.slug}</div>
            </div>
          </div>
          ${board.description ? html`
            <p class="max-w-3xl text-xs leading-relaxed text-[var(--color-fg-secondary)]">${board.description}</p>
          ` : null}
          <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
            <span class="inline-flex items-center gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5">
              <${Users} size=${12} aria-hidden="true" />
              ${board.members.length} members
            </span>
            <span class="inline-flex rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5">${accessLabel(board.access)}</span>
            <span>${board.post_count} posts</span>
          </div>
        </div>
        <div class="shrink-0 text-right text-2xs text-[var(--color-fg-muted)]">
          <div class="font-medium text-[var(--color-fg-secondary)]">${board.owner || 'dashboard'}</div>
          <${TimeAgo} timestamp=${board.created_at} />
        </div>
      </div>
    <//>
  `
}

export function SubBoardSurface() {
  const [boards, setBoards] = useState<SubBoard[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [slug, setSlug] = useState('')
  const [description, setDescription] = useState('')
  const [access, setAccess] = useState<SubBoardAccess>('open')
  const [members, setMembers] = useState('')
  const [submitting, setSubmitting] = useState(false)

  const effectiveSlug = useMemo(() => slug.trim() || slugFromName(name), [name, slug])
  const memberList = useMemo(() => parseMembers(members), [members])

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setBoards(await fetchSubBoards())
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load sub-boards'
      setError(message)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const canSubmit = effectiveSlug !== '' && name.trim() !== '' && !submitting

  const submit = async (event: Event) => {
    event.preventDefault()
    if (!canSubmit) return
    setSubmitting(true)
    setError(null)
    try {
      await createSubBoard(effectiveSlug, name.trim(), description.trim(), access, memberList)
      setName('')
      setSlug('')
      setDescription('')
      setMembers('')
      setAccess('open')
      showToast('Sub-board created', 'success')
      await load()
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to create sub-board'
      setError(message)
      showToast(`Sub-board create failed: ${message}`, 'error')
    } finally {
      setSubmitting(false)
    }
  }

  return html`
    <section class="flex min-w-0 flex-col gap-4" aria-label="Sub-boards">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h2 class="text-base font-semibold text-[var(--color-fg-primary)]">Sub-Boards</h2>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">Named board spaces with owner, member, access, and post-count state.</p>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          onClick=${() => { void load() }}
          disabled=${loading}
          ariaLabel="Refresh sub-boards"
        >
          <span class="inline-flex items-center gap-1.5">
            <${RefreshCw} size=${14} aria-hidden="true" />
            Refresh
          </span>
        <//>
      </div>

      <form class="grid gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" onSubmit=${submit}>
        <div class="grid gap-3 lg:grid-cols-[1fr_0.8fr_0.8fr]">
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Name
            <${TextInput}
              value=${name}
              placeholder="Operations"
              required
              disabled=${submitting}
              ariaLabel="Sub-board name"
              testId="sub-board-name"
              onInput=${(event: Event) => setName((event.target as HTMLInputElement).value)}
            />
          </label>
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Slug
            <${TextInput}
              value=${slug}
              placeholder=${effectiveSlug || 'operations'}
              disabled=${submitting}
              ariaLabel="Sub-board slug"
              testId="sub-board-slug"
              onInput=${(event: Event) => setSlug((event.target as HTMLInputElement).value)}
            />
          </label>
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Access
            <${Select}
              value=${access}
              options=${ACCESS_OPTIONS}
              disabled=${submitting}
              ariaLabel="Sub-board access"
              testId="sub-board-access"
              onInput=${(value: string) => setAccess(value as SubBoardAccess)}
            />
          </label>
        </div>
        <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
          Description
          <${TextArea}
            value=${description}
            rows=${3}
            placeholder="Board lane for runtime operators"
            disabled=${submitting}
            ariaLabel="Sub-board description"
            onInput=${(event: Event) => setDescription((event.target as HTMLTextAreaElement).value)}
          />
        </label>
        <div class="grid gap-3 lg:grid-cols-[1fr_auto] lg:items-end">
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Members
            <${TextInput}
              value=${members}
              placeholder="keeper-a, keeper-b"
              disabled=${submitting}
              ariaLabel="Sub-board members"
              testId="sub-board-members"
              onInput=${(event: Event) => setMembers((event.target as HTMLInputElement).value)}
            />
          </label>
          <${ActionButton}
            type="submit"
            variant="primary"
            size="md"
            disabled=${!canSubmit}
            ariaBusy=${submitting}
            testId="sub-board-create"
          >
            <span class="inline-flex items-center gap-1.5">
              <${Plus} size=${14} aria-hidden="true" />
              Create
            </span>
          <//>
        </div>
      </form>

      ${error ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-status-err)]/40 bg-[var(--color-status-err)]/10 px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert">${error}</div>
      ` : null}

      ${loading
        ? html`<${LoadingState}>Loading sub-boards...<//>`
        : boards.length === 0
          ? html`<${EmptyState} message="No sub-boards yet." compact />`
          : html`
            <div class="grid gap-3" data-testid="sub-board-list">
              ${boards.map(board => html`<${SubBoardRow} key=${board.id} board=${board} />`)}
            </div>
          `}
    </section>
  `
}
