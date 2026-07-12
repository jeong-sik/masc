import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'
import { Hash, Pencil, Plus, RefreshCw, Trash2, Users } from 'lucide-preact'
import { createSubBoard, deleteSubBoard, fetchSubBoards, updateSubBoard } from '../../api/board'
import { boardHearthFilter } from '../../store'
import type { SubBoard, SubBoardAccess } from '../../types'
import { ActionButton } from '../common/button'
import { EmptyState, LoadingState } from '../common/feedback-state'
import { TextArea, TextInput } from '../common/input'
import { Select } from '../common/select'
import { SurfaceCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { navigateBoard } from './board-route'

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

function formatMembers(members: string[]): string {
  return members.join(', ')
}

interface SubBoardRowProps {
  board: SubBoard
  onEdit: (board: SubBoard) => void
  onDelete: (board: SubBoard) => void
  deleting: boolean
}

function SubBoardRow({ board, onEdit, onDelete, deleting }: SubBoardRowProps) {
  return html`
    <${SurfaceCard} variant="compact" class="v2-workspace-row" testId=${`sub-board-row-${board.slug}`}>
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0 space-y-2">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="inline-flex size-7 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]" aria-hidden="true">
              <${Hash} size=${15} />
            </span>
            <button
              type="button"
              class="v2-mobile-operator-target min-w-0 cursor-pointer border-0 bg-transparent p-0 text-left"
              aria-label=${`서브보드 열기: ${board.name || board.slug}`}
              data-testid=${`sub-board-open-${board.slug}`}
              onClick=${() => {
              boardHearthFilter.value = board.slug
              navigateBoard()
              }}
            >
              <h3 class="truncate text-sm font-semibold text-[var(--color-fg-primary)] hover:underline">${board.name || board.slug}</h3>
              <div class="truncate font-mono text-2xs text-[var(--color-fg-muted)]">/${board.slug}</div>
            </button>
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
        <div class="shrink-0 flex flex-col items-end gap-2 text-right text-2xs text-[var(--color-fg-muted)]">
          <div class="font-medium text-[var(--color-fg-secondary)]">${board.owner || 'dashboard'}</div>
          <${TimeAgo} timestamp=${board.created_at} />
          <div class="flex gap-1">
            <${ActionButton}
              variant="ghost"
              size="sm"
              class="v2-workspace-action"
              onClick=${() => onEdit(board)}
              ariaLabel="Edit sub-board"
            >
              <${Pencil} size=${12} aria-hidden="true" />
            <//>
            <${ActionButton}
              variant="ghost"
              size="sm"
              class="v2-workspace-action"
              onClick=${() => onDelete(board)}
              disabled=${deleting}
              ariaLabel="Delete sub-board"
            >
              <${Trash2} size=${12} aria-hidden="true" />
            <//>
          </div>
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

  const [editingBoard, setEditingBoard] = useState<SubBoard | null>(null)
  const [editName, setEditName] = useState('')
  const [editDescription, setEditDescription] = useState('')
  const [editAccess, setEditAccess] = useState<SubBoardAccess>('open')
  const [editMembers, setEditMembers] = useState('')
  const [editSubmitting, setEditSubmitting] = useState(false)

  const [deletingId, setDeletingId] = useState<string | null>(null)

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

  const startEdit = (board: SubBoard) => {
    setEditingBoard(board)
    setEditName(board.name)
    setEditDescription(board.description)
    setEditAccess(board.access)
    setEditMembers(formatMembers(board.members))
  }

  const cancelEdit = () => {
    setEditingBoard(null)
    setEditName('')
    setEditDescription('')
    setEditMembers('')
    setEditAccess('open')
  }

  const submitEdit = async (event: Event) => {
    event.preventDefault()
    if (!editingBoard) return
    setEditSubmitting(true)
    setError(null)
    try {
      const updates = {
        name: editName.trim(),
        description: editDescription.trim(),
        access: editAccess,
        members: parseMembers(editMembers),
      }
      await updateSubBoard(editingBoard.id, updates)
      showToast('Sub-board updated', 'success')
      cancelEdit()
      await load()
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to update sub-board'
      setError(message)
      showToast(`Sub-board update failed: ${message}`, 'error')
    } finally {
      setEditSubmitting(false)
    }
  }

  const handleDelete = async (board: SubBoard) => {
    const confirmed = await requestConfirm({
      title: 'Delete Sub-board',
      message: `Delete "/${board.slug}"? Posts inside will keep their hearth tag but the space itself will be removed.`,
      tone: 'danger',
    })
    if (!confirmed) return
    setDeletingId(board.id)
    try {
      await deleteSubBoard(board.id)
      showToast('Sub-board deleted', 'success')
      await load()
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to delete sub-board'
      showToast(`Sub-board delete failed: ${message}`, 'error')
    } finally {
      setDeletingId(null)
    }
  }

  return html`
    <section class="v2-workspace-surface flex min-w-0 flex-col gap-4" aria-label="Sub-boards">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h2 class="text-base font-semibold text-[var(--color-fg-primary)]">Sub-Boards</h2>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">Named board spaces with owner, member, access, and post-count state.</p>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          class="v2-workspace-action"
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

      ${!editingBoard ? html`
        <form class="v2-workspace-panel grid gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" onSubmit=${submit}>
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
              class="v2-workspace-action"
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
      ` : html`
        <form class="v2-workspace-panel grid gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" onSubmit=${submitEdit}>
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">Edit /${editingBoard.slug}</h3>
            <${ActionButton} variant="ghost" size="sm" class="v2-workspace-action" onClick=${cancelEdit} ariaLabel="Cancel edit">Cancel<//>
          </div>
          <div class="grid gap-3 lg:grid-cols-[1fr_0.8fr]">
            <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
              Name
              <${TextInput}
                value=${editName}
                disabled=${editSubmitting}
                ariaLabel="Sub-board name"
                onInput=${(event: Event) => setEditName((event.target as HTMLInputElement).value)}
              />
            </label>
            <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
              Access
              <${Select}
                value=${editAccess}
                options=${ACCESS_OPTIONS}
                disabled=${editSubmitting}
                ariaLabel="Sub-board access"
                onInput=${(value: string) => setEditAccess(value as SubBoardAccess)}
              />
            </label>
          </div>
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Description
            <${TextArea}
              value=${editDescription}
              rows=${3}
              disabled=${editSubmitting}
              ariaLabel="Sub-board description"
              onInput=${(event: Event) => setEditDescription((event.target as HTMLTextAreaElement).value)}
            />
          </label>
          <div class="grid gap-3 lg:grid-cols-[1fr_auto] lg:items-end">
            <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
              Members
              <${TextInput}
                value=${editMembers}
                placeholder="keeper-a, keeper-b"
                disabled=${editSubmitting}
                ariaLabel="Sub-board members"
                onInput=${(event: Event) => setEditMembers((event.target as HTMLInputElement).value)}
              />
            </label>
            <${ActionButton}
              type="submit"
              variant="primary"
              size="md"
              class="v2-workspace-action"
              disabled=${editSubmitting}
              ariaBusy=${editSubmitting}
            >
              Save
            <//>
          </div>
        </form>
      `}

      ${error ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-status-err)]/40 bg-[var(--color-status-err)]/10 px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert">${error}</div>
      ` : null}

      ${loading
        ? html`<${LoadingState}>Loading sub-boards...<//>`
        : boards.length === 0
          ? html`
            <div class="v2-workspace-panel rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
              <${EmptyState} message="No sub-boards yet. Create one above when a board category needs owner, member, or access policy. Plain board categories stay as hearth tags until a Sub-board is explicitly created." compact />
            </div>
          `
          : html`
            <div class="grid gap-3" data-testid="sub-board-list">
              ${boards.map(board => html`<${SubBoardRow}
                key=${board.id}
                board=${board}
                onEdit=${startEdit}
                onDelete=${handleDelete}
                deleting=${deletingId === board.id}
              />`)}
            </div>
          `}
    </section>
  `
}
