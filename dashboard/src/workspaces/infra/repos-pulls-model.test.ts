import { describe, expect, it } from 'vitest'
import {
  decodePullsSnapshot,
  filterPulls,
  summarizePulls,
  type PullFilter,
  type RepoPull,
} from './repos-pulls-model'

describe('workspaces/infra repos-pulls-model', () => {
  const pull = (number: number, over: Record<string, unknown> = {}) => ({
    repo_slug: 'jeong-sik/masc',
    number,
    draft: false,
    checks: 'passing',
    review: 'waiting',
    mergeable: 'mergeable',
    author: 'someone',
    keeper: null,
    title: `pull ${number}`,
    head_oid: 'abc',
    head_review: 'not_reviewed_on_head',
    reviews: { state: 'read', truncated: false, latest: [] },
    ...over,
  })

  it('reads every repository state the server can report', () => {
    const snapshot = decodePullsSnapshot({
      reader: { state: 'ready', keeper: 'pr-updater' },
      repositories_error: null,
      keepers: { state: 'listed' },
      repositories: [
        { repository_id: 'masc', url: 'u', slug: 'jeong-sik/masc', pulls: { state: 'read', observed_at: 100, undecodable: 1, pulls: [pull(1), pull(2, { keeper: 'ocaml-dev' })] } },
        { repository_id: 'local', url: 'u', slug: null, pulls: { state: 'not_github' } },
        { repository_id: 'new', url: 'u', slug: 'a/b', pulls: { state: 'not_read' } },
        { repository_id: 'limited', url: 'u', slug: 'a/c', pulls: { state: 'failed', observed_at: 90, failure: { kind: 'rate_limited', reset_at: 200 } } },
      ],
    })
    expect(snapshot.reader).toEqual({ kind: 'ready', keeper: 'pr-updater' })
    const masc = snapshot.byRepo.get('masc')!
    expect(masc.slug).toBe('jeong-sik/masc')
    expect(masc.pulls.kind === 'read' && masc.pulls.pulls.map((p) => p.number)).toEqual([1, 2])
    expect(masc.pulls.kind === 'read' && masc.pulls.unreadable).toBe(1)
    expect(snapshot.byRepo.get('local')!.pulls).toEqual({ kind: 'not_github' })
    expect(snapshot.byRepo.get('new')!.pulls).toEqual({ kind: 'not_read' })
    expect(snapshot.byRepo.get('limited')!.pulls).toEqual({
      kind: 'failed',
      observedAt: 90,
      failure: { kind: 'rate_limited', resetAt: 200 },
    })
  })

  it('counts a pull request with an unknown word as unreadable instead of guessing', () => {
    const snapshot = decodePullsSnapshot({
      reader: { state: 'ready', keeper: 'pr-updater' },
      repositories_error: null,
      keepers: { state: 'list_failed', reason: 'keeper store unreadable' },
      repositories: [{
        repository_id: 'masc',
        url: 'u',
        slug: 'jeong-sik/masc',
        pulls: { state: 'read', observed_at: 100, undecodable: 0, pulls: [pull(1), pull(2, { checks: 'skipped' })] },
      }],
    })
    const masc = snapshot.byRepo.get('masc')!
    expect(masc.pulls.kind === 'read' && masc.pulls.pulls).toHaveLength(1)
    expect(masc.pulls.kind === 'read' && masc.pulls.unreadable).toBe(1)
    expect(snapshot.keepers).toEqual({ kind: 'list_failed', reason: 'keeper store unreadable' })
  })

  it('refuses a read state that does not say how many pull requests it could not decode', () => {
    const snapshot = (pulls: Record<string, unknown>) => ({
      reader: { state: 'ready', keeper: 'pr-updater' },
      repositories_error: null,
      keepers: { state: 'listed' },
      repositories: [{ repository_id: 'masc', url: 'u', slug: 'a/b', pulls }],
    })
    expect(() => decodePullsSnapshot(snapshot({ state: 'read', observed_at: 100, pulls: [] }))).toThrow('undecodable')
    expect(() => decodePullsSnapshot(snapshot({
      state: 'failed', observed_at: 100, failure: { kind: 'transport_failed' },
    }))).toThrow('failure.message')
  })

  it('refuses a snapshot whose reader or repository state it does not know', () => {
    expect(() => decodePullsSnapshot({ reader: { state: 'asleep' }, repositories: [] })).toThrow()
    expect(() => decodePullsSnapshot({
      reader: { state: 'not_declared' },
      repositories: [{ repository_id: 'masc', slug: null, pulls: { state: 'half_read' } }],
    })).toThrow()
  })

  it('summarizes what needs a hand', () => {
    const pulls: RepoPull[] = [
      { number: 1, draft: false, checks: 'passing', review: 'approved', mergeable: 'mergeable', headReview: 'reviewed_on_head', author: 'a', keeper: null, title: 't' },
      { number: 2, draft: true, checks: 'passing', review: 'approved', mergeable: 'mergeable', headReview: 'reviewed_on_head', author: 'a', keeper: null, title: 't' },
      { number: 3, draft: false, checks: 'failing', review: 'changes_requested', mergeable: 'conflicting', headReview: 'unknown', author: null, keeper: null, title: null },
    ]
    expect(summarizePulls(pulls)).toEqual({ total: 3, conflicting: 1, checksFailing: 1, changesRequested: 1, ready: 1 })
  })

  it('does not count an approval of an earlier commit as ready to merge', () => {
    const approved = (number: number, headReview: RepoPull['headReview']): RepoPull => (
      { number, draft: false, checks: 'passing', review: 'approved', mergeable: 'mergeable', headReview, author: 'a', keeper: null, title: 't' }
    )
    const pulls = [approved(1, 'reviewed_on_head'), approved(2, 'not_reviewed_on_head'), approved(3, 'review_history_incomplete'), approved(4, 'unknown')]
    expect(summarizePulls(pulls).ready).toBe(1)
    expect(filterPulls(pulls, 'ready').map((pull) => pull.number)).toEqual([1])
  })

  it('reads when a rate limit lifts as a number or as not said, and refuses anything else', () => {
    const limited = (resetAt: unknown) => decodePullsSnapshot({
      reader: { state: 'not_declared' },
      repositories_error: null,
      keepers: { state: 'listed' },
      repositories: [{ repository_id: 'a', url: 'u', slug: 'a/b', pulls: { state: 'failed', observed_at: 90, failure: { kind: 'rate_limited', reset_at: resetAt } } }],
    }).byRepo.get('a')?.pulls
    expect(limited(200)).toMatchObject({ kind: 'failed', failure: { kind: 'rate_limited', resetAt: 200 } })
    expect(limited(null)).toMatchObject({ kind: 'failed', failure: { kind: 'rate_limited', resetAt: null } })
    expect(() => limited('soon')).toThrow('reset_at')
  })

  it('narrows the table to the rows a chip counts', () => {
    const pulls: RepoPull[] = [
      { number: 1, draft: false, checks: 'passing', review: 'approved', mergeable: 'mergeable', headReview: 'reviewed_on_head', author: 'a', keeper: null, title: 't' },
      { number: 2, draft: false, checks: 'failing', review: 'waiting', mergeable: 'mergeable', headReview: 'unknown', author: 'a', keeper: null, title: 't' },
      { number: 3, draft: false, checks: 'passing', review: 'changes_requested', mergeable: 'conflicting', headReview: 'unknown', author: 'a', keeper: null, title: 't' },
    ]
    const numbers = (filter: PullFilter) => filterPulls(pulls, filter).map((pull) => pull.number)
    expect(numbers('all')).toEqual([1, 2, 3])
    expect(numbers('ready')).toEqual([1])
    expect(numbers('checksFailing')).toEqual([2])
    expect(numbers('conflicting')).toEqual([3])
    expect(numbers('changesRequested')).toEqual([3])
  })
})
