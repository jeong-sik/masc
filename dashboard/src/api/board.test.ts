import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  derivePostTitle,
  createSubBoard,
  createPost,
  fetchBoard,
  fetchBoardCuration,
  fetchBoardHearths,
  fetchBoardKarmaLedger,
  fetchBoardPost,
  fetchBoardReactions,
  normalizeBoardKarmaLedger,
  sanitizeBoardTitle,
  toggleReaction,
  voteComment,
  asNullableIsoTimestamp,
  normalizePendingConfirmation,
  normalizeKeeperApprovalQueueItem,
  normalizeGovernanceJudgment,
  normalizeGovernanceDecisionItem,
  normalizeGovernanceTimelineEvent,
  normalizeGovernanceJudgeSummary,
  normalizeSubBoard,
} from './board'
import { boardLatencyMetrics, resetBoardLatencyMetrics } from '../board-metrics'

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  resetBoardLatencyMetrics()
})

// ================================================================
// board title helpers (existing)
// ================================================================

describe('board title helpers', () => {
  it('strips markdown headings from derived titles', () => {
    expect(derivePostTitle('## Deploy Plan\n\nBody')).toBe('Deploy Plan')
  })

  it('skips fenced code when deriving fallback titles', () => {
    expect(derivePostTitle('```md\n# sample\n```\n\n## Real Title\ncontent')).toBe('Real Title')
  })

  it('sanitizes explicit board titles before display', () => {
    expect(sanitizeBoardTitle('## Incident Review')).toBe('Incident Review')
  })
})

// ================================================================
// derivePostTitle (expanded)
// ================================================================

describe('derivePostTitle expanded', () => {
  it('extracts first non-empty line', () => {
    expect(derivePostTitle('Hello world')).toBe('Hello world')
  })

  it('skips leading blank lines', () => {
    expect(derivePostTitle('\n\nActual title')).toBe('Actual title')
  })

  it('strips [flair:...] prefix', () => {
    expect(derivePostTitle('[flair:alert] Important notice')).toBe('Important notice')
  })

  it('strips blockquote prefix', () => {
    expect(derivePostTitle('> Quoted text')).toBe('Quoted text')
  })

  it('strips list prefix', () => {
    expect(derivePostTitle('- List item')).toBe('List item')
    expect(derivePostTitle('* Star item')).toBe('Star item')
    expect(derivePostTitle('+ Plus item')).toBe('Plus item')
  })

  it('strips numbered list prefix', () => {
    expect(derivePostTitle('1. First item')).toBe('First item')
  })

  it('returns "제목 없음" for empty content', () => {
    expect(derivePostTitle('')).toBe('제목 없음')
    expect(derivePostTitle('   ')).toBe('제목 없음')
  })

  it('truncates long titles', () => {
    const long = 'a'.repeat(100)
    const result = derivePostTitle(long)
    expect(result!.length).toBeLessThanOrEqual(96)
    expect(result).toContain('...')
  })

  it('skips horizontal rules', () => {
    expect(derivePostTitle('---\nActual title')).toBe('Actual title')
  })
})

// ================================================================
// sanitizeBoardTitle (expanded)
// ================================================================

describe('sanitizeBoardTitle expanded', () => {
  it('uses first line only', () => {
    expect(sanitizeBoardTitle('Line one\nLine two')).toBe('Line one')
  })

  it('falls back to derivePostTitle from body', () => {
    expect(sanitizeBoardTitle('', 'Body title')).toBe('Body title')
  })

  it('falls back for whitespace-only title', () => {
    expect(sanitizeBoardTitle('   ', 'Fallback')).toBe('Fallback')
  })
})

// ================================================================
// asNullableIsoTimestamp
// ================================================================

describe('asNullableIsoTimestamp', () => {
  it('returns null for null', () => {
    expect(asNullableIsoTimestamp(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(asNullableIsoTimestamp(undefined)).toBeNull()
  })

  it('returns trimmed string for valid ISO string', () => {
    expect(asNullableIsoTimestamp('  2026-04-17T12:00:00Z  ')).toBe('2026-04-17T12:00:00Z')
  })

  it('returns null for empty string', () => {
    expect(asNullableIsoTimestamp('')).toBeNull()
  })

  it('returns null for whitespace-only string', () => {
    expect(asNullableIsoTimestamp('   ')).toBeNull()
  })

  it('converts epoch seconds to ISO', () => {
    const result = asNullableIsoTimestamp(1_700_000_000)
    expect(result).not.toBeNull()
  })

  it('converts epoch milliseconds to ISO', () => {
    const result = asNullableIsoTimestamp(1_700_000_000_000)
    expect(result).not.toBeNull()
  })

  it('returns null for NaN', () => {
    expect(asNullableIsoTimestamp(NaN)).toBeNull()
  })

  it('returns null for Infinity', () => {
    expect(asNullableIsoTimestamp(Infinity)).toBeNull()
  })
})

// ================================================================
// normalizePendingConfirmation (board)
// ================================================================

describe('normalizePendingConfirmation (board)', () => {
  it('returns null for null', () => {
    expect(normalizePendingConfirmation(null)).toBeNull()
  })

  it('returns null when no confirm_token or token', () => {
    expect(normalizePendingConfirmation({ actor: 'a1' })).toBeNull()
  })

  it('extracts confirm_token', () => {
    const result = normalizePendingConfirmation({ confirm_token: 'tok-1' })
    expect(result!.confirm_token).toBe('tok-1')
  })

  it('falls back to token field', () => {
    const result = normalizePendingConfirmation({ token: 'tok-fallback' })
    expect(result!.confirm_token).toBe('tok-fallback')
  })

  it('extracts all optional fields', () => {
    const result = normalizePendingConfirmation({
      confirm_token: 'tok-1',
      actor: 'agent-1',
      action_type: 'pause',
      target_type: 'keeper',
      target_id: 'janitor',
      delegated_tool: 'shell',
      created_at: '2026-04-17T12:00:00Z',
      preview: { msg: 'hi' },
    })
    expect(result!.actor).toBe('agent-1')
    expect(result!.target_id).toBe('janitor')
    expect(result!.preview).toEqual({ msg: 'hi' })
  })
})

// ================================================================
// normalizeKeeperApprovalQueueItem
// ================================================================

describe('normalizeKeeperApprovalQueueItem', () => {
  it('returns null for null', () => {
    expect(normalizeKeeperApprovalQueueItem(null)).toBeNull()
  })

  it('returns null when id is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ keeper_name: 'k', tool_name: 't', risk_level: 'low' })).toBeNull()
  })

  it('returns null when keeper_name is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ id: '1', tool_name: 't', risk_level: 'low' })).toBeNull()
  })

  it('returns null when tool_name is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ id: '1', keeper_name: 'k', risk_level: 'low' })).toBeNull()
  })

  it('returns null when risk_level is missing', () => {
    expect(normalizeKeeperApprovalQueueItem({ id: '1', keeper_name: 'k', tool_name: 't' })).toBeNull()
  })

  it('extracts all fields', () => {
    const result = normalizeKeeperApprovalQueueItem({
      id: 'q-1',
      keeper_name: 'janitor',
      tool_name: 'shell_exec',
      action_key: 'op:gh',
      sandbox_target: 'docker',
      risk_level: 'high',
      requested_at_iso: '2026-04-17T12:00:00Z',
      waiting_s: 30,
      input: { cmd: 'ls' },
      input_preview: 'ls -la',
    })
    expect(result!.id).toBe('q-1')
    expect(result!.keeper_name).toBe('janitor')
    expect(result!.tool_name).toBe('shell_exec')
    expect(result!.action_key).toBe('op:gh')
    expect(result!.sandbox_target).toBe('docker')
    expect(result!.risk_level).toBe('high')
    expect(result!.waiting_s).toBe(30)
    expect(result!.input_preview).toBe('ls -la')
  })
})

// ================================================================
// normalizeGovernanceJudgment
// ================================================================

describe('normalizeGovernanceJudgment', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceJudgment(null)).toBeNull()
  })

  it('returns null when no summary or target_id', () => {
    expect(normalizeGovernanceJudgment({})).toBeNull()
  })

  it('extracts judgment with summary', () => {
    const result = normalizeGovernanceJudgment({
      summary: 'All systems healthy',
      confidence: 0.92,
    })
    expect(result!.summary).toBe('All systems healthy')
    expect(result!.confidence).toBe(0.92)
  })

  it('extracts judgment with target_id only', () => {
    const result = normalizeGovernanceJudgment({ target_id: 'keeper:janitor' })
    expect(result!.target_id).toBe('keeper:janitor')
  })

  it('extracts all optional fields', () => {
    const result = normalizeGovernanceJudgment({
      summary: 'Test',
      judgment_id: 'j-1',
      target_kind: 'keeper',
      target_id: 'janitor',
      status: 'complete',
      model_used: 'gpt-4',
      keeper_name: 'janitor',
      evidence_refs: ['e1', 'e2'],
    })
    expect(result!.judgment_id).toBe('j-1')
    expect(result!.model_used).toBe('gpt-4')
    expect(result!.evidence_refs).toEqual(['e1', 'e2'])
  })

  it('returns null confidence for non-number', () => {
    const result = normalizeGovernanceJudgment({ summary: 's', confidence: 'high' })
    expect(result!.confidence).toBeNull()
  })
})

// ================================================================
// normalizeGovernanceDecisionItem
// ================================================================

describe('normalizeGovernanceDecisionItem', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceDecisionItem(null)).toBeNull()
  })

  it('returns null when id is missing', () => {
    expect(normalizeGovernanceDecisionItem({ topic: 'test' })).toBeNull()
  })

  it('returns null when topic and title are missing', () => {
    expect(normalizeGovernanceDecisionItem({ id: '1' })).toBeNull()
  })

  it('extracts required fields', () => {
    const result = normalizeGovernanceDecisionItem({
      id: 'case-1',
      topic: 'High CPU alert',
    })
    expect(result!.id).toBe('case-1')
    expect(result!.topic).toBe('High CPU alert')
    expect(result!.kind).toBe('case')
    expect(result!.status).toBe('open')
    expect(result!.related_agents).toEqual([])
    expect(result!.evidence_refs).toEqual([])
  })

  it('falls back to title for topic', () => {
    const result = normalizeGovernanceDecisionItem({
      id: '1',
      title: 'Fallback title',
    })
    expect(result!.topic).toBe('Fallback title')
  })

  it('falls back to state for status', () => {
    const result = normalizeGovernanceDecisionItem({
      id: '1',
      topic: 't',
      state: 'pending_ruling',
    })
    expect(result!.status).toBe('pending_ruling')
  })

  it('extracts context links', () => {
    const result = normalizeGovernanceDecisionItem({
      id: '1',
      topic: 't',
      context: {
        board_post_id: 'bp-1',
        task_id: 't-1',
        operation_id: 'op-1',
      },
      linked_session_id: 'sess-1',
    })
    expect(result!.linked_board_post_id).toBe('bp-1')
    expect(result!.linked_task_id).toBe('t-1')
    expect(result!.linked_operation_id).toBe('op-1')
    expect(result!.linked_session_id).toBe('sess-1')
  })
})

// ================================================================
// normalizeGovernanceTimelineEvent
// ================================================================

describe('normalizeGovernanceTimelineEvent', () => {
  it('returns null for null', () => {
    expect(normalizeGovernanceTimelineEvent(null)).toBeNull()
  })

  it('returns null when kind is missing', () => {
    expect(normalizeGovernanceTimelineEvent({})).toBeNull()
  })

  it('returns null when kind is empty', () => {
    expect(normalizeGovernanceTimelineEvent({ kind: '  ' })).toBeNull()
  })

  it('extracts kind and optional fields', () => {
    const result = normalizeGovernanceTimelineEvent({
      kind: 'ruling_issued',
      item_kind: 'case',
      item_id: 'case-1',
      topic: 'High CPU',
      summary: 'Ruling: auto-execute',
      actor: 'judge',
      index: 5,
      decision: 'approve',
    })
    expect(result!.kind).toBe('ruling_issued')
    expect(result!.item_kind).toBe('case')
    expect(result!.summary).toBe('Ruling: auto-execute')
    expect(result!.index).toBe(5)
  })
})

// ================================================================
// normalizeGovernanceJudgeSummary
// ================================================================

describe('normalizeGovernanceJudgeSummary', () => {
  it('returns undefined for null', () => {
    expect(normalizeGovernanceJudgeSummary(null)).toBeUndefined()
  })

  it('returns undefined for non-record', () => {
    expect(normalizeGovernanceJudgeSummary('invalid')).toBeUndefined()
  })

  it('extracts all fields', () => {
    const result = normalizeGovernanceJudgeSummary({
      judge_online: true,
      refreshing: false,
      status: 'stale_visible',
      degraded_reason: 'timeout',
      cached_judgments_visible: true,
      model_used: 'gpt-4',
      keeper_name: 'janitor',
      last_error: null,
    })
    expect(result!.judge_online).toBe(true)
    expect(result!.refreshing).toBe(false)
    expect(result!.status).toBe('stale_visible')
    expect(result!.degraded_reason).toBe('timeout')
    expect(result!.cached_judgments_visible).toBe(true)
    expect(result!.model_used).toBe('gpt-4')
    expect(result!.keeper_name).toBe('janitor')
    expect(result!.last_error).toBeNull()
  })

  it('returns undefined for non-boolean judge_online', () => {
    const result = normalizeGovernanceJudgeSummary({ judge_online: 'yes' })
    expect(result!.judge_online).toBeUndefined()
  })
})

// ================================================================
// fetchBoard
// ================================================================

describe('fetchBoard', () => {
  it('preserves board actor identity provenance from the server', async () => {
    const rawResponse = {
      posts: [
        {
          id: 'post-1',
          author: 'analyst',
          title: 'Status',
          body: 'Working',
          created_at: 1_713_000_000,
          updated_at: 1_713_000_000,
          current_vote: 'up',
          has_voted: true,
          report_count: 2,
          moderation_status: 'flagged',
          reactions: [
            {
              emoji: '🔥',
              count: 2,
              reacted: true,
              recent_user_ids: ['analyst', 'reviewer'],
            },
          ],
          author_identity: {
            kind: 'keeper',
            id: 'analyst',
            key: 'keeper:analyst',
            display_name: 'analyst',
            raw: 'keeper-analyst-agent',
            source: 'keeper_alias_contract',
            runtime_agent_name: 'keeper-analyst-agent',
          },
        },
      ],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoard()

    expect(result.posts[0]).toMatchObject({
      current_vote: 'up',
      has_voted: true,
      report_count: 2,
      moderation_status: 'flagged',
      reactions: [
        {
          emoji: '🔥',
          count: 2,
          reacted: true,
          has_reacted: true,
          recent_user_ids: ['analyst', 'reviewer'],
        },
      ],
    })
    expect(result.posts[0]?.author_identity).toMatchObject({
      kind: 'keeper',
      id: 'analyst',
      raw: 'keeper-analyst-agent',
      source: 'keeper_alias_contract',
      runtime_agent_name: 'keeper-analyst-agent',
    })
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('voter=')
  })

  it('passes hearth filters through to the board API', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ posts: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await fetchBoard('recent', { hearth: 'ops' })

    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/board?')
    expect(url).toContain('hearth=ops')
    expect(url).toContain('limit=150')
  })

  it('normalizes vote-blind rows and opts into the board projection when requested', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        posts: [
          {
            id: 'post-blind',
            author: 'analyst',
            title: 'Blind score',
            body: 'Working',
            created_at: 1_713_000_000,
            updated_at: 1_713_000_000,
            votes: null,
            score: null,
            votes_up: null,
            votes_down: null,
            vote_blind: true,
            vote_blind_reason: 'vote_before_score',
          },
        ],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoard('hot', { blindVotes: true })

    expect(result.posts[0]).toMatchObject({
      id: 'post-blind',
      vote_blind: true,
      vote_blind_reason: 'vote_before_score',
    })
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('blind_votes=true')
  })
})

describe('fetchBoardHearths', () => {
  it('normalizes active hearth rows from the server', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        hearths: [
          { name: 'ops', count: 3 },
          { name: '  ', count: 9 },
          { name: 'research' },
        ],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchBoardHearths()).resolves.toEqual([
      { name: 'ops', count: 3 },
      { name: 'research', count: 0 },
    ])
    expect(fetchMock).toHaveBeenCalledWith('/api/v1/board/hearths', expect.any(Object))
  })
})

describe('fetchBoardCuration', () => {
  it('normalizes summary, tags, answer matches, and health score from the curation snapshot', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        snapshot: {
          id: 'cu-1',
          generated_at: 1_748_779_200,
          submitted_by: 'keeper-curator',
          model: 'gpt-5',
          summary: 'Two active incidents need review.',
          ordering: ['post-a', { id: 'not-coerced' }, 'post-b', 7, ' '],
          highlights: ['post-a', { name: 'not-coerced' }, null],
          tag_suggestions: [
            { post_id: 'post-a', tags: ['incident', { name: 'not-coerced' }, ' ops ', ' '], rationale: 'Incident thread' },
            { post_id: ' ', tags: ['ignored'], rationale: 'missing post id' },
          ],
          answer_matches: [
            {
              question_post_id: 'post-question',
              answer_post_id: 'post-answer',
              score: 0.86,
              rationale: 'Same stack trace',
            },
          ],
          health_score: 0.74,
          health_components: [
            { name: 'answer_rate', score: 0.8, weight: 0.25, rationale: 'Most questions have replies' },
          ],
          rationale: 'Prioritize incidents before planning threads.',
          provenance: { run_id: 'curation-run-1' },
        },
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoardCuration()

    expect(result).toMatchObject({
      id: 'cu-1',
      submitted_by: 'keeper-curator',
      model: 'gpt-5',
      summary: 'Two active incidents need review.',
      ordering: ['post-a', 'post-b'],
      highlights: ['post-a'],
      tag_suggestions: [
        { post_id: 'post-a', tags: ['incident', 'ops'], rationale: 'Incident thread' },
      ],
      answer_matches: [
        {
          question_post_id: 'post-question',
          answer_post_id: 'post-answer',
          score: 0.86,
          rationale: 'Same stack trace',
        },
      ],
      health_score: 0.74,
      health_components: [
        { name: 'answer_rate', score: 0.8, weight: 0.25, rationale: 'Most questions have replies' },
      ],
      rationale: 'Prioritize incidents before planning threads.',
      provenance: { run_id: 'curation-run-1' },
    })
    expect(fetchMock).toHaveBeenCalledWith('/api/v1/board/curation', expect.any(Object))
  })

  it('returns null when no curation snapshot exists', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ snapshot: null }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchBoardCuration()).resolves.toBeNull()
  })
})

describe('fetchBoardPost', () => {
  it('normalizes comment vote fields from the server detail payload', async () => {
    const rawResponse = {
      post: {
        id: 'post-1',
        author: 'analyst',
        title: 'Status',
        body: 'Working',
        created_at: 1_713_000_000,
        updated_at: 1_713_000_000,
        current_vote: 'down',
        has_voted: true,
        reactions: [
          {
            emoji: '👍',
            count: 1,
            has_reacted: false,
            recent_user_ids: ['reader-a'],
          },
        ],
      },
      comments: [
        {
          id: 'comment-1',
          post_id: 'post-1',
          author: 'reviewer',
          content: 'Useful',
          created_at: 1_713_000_100,
          votes_up: 5,
          votes_down: 2,
          score: 3,
          current_vote: 'up',
          has_voted: true,
          report_count: 1,
          moderation_status: 'hidden',
          reactions: [
            {
              emoji: '🚀',
              count: 4,
              reacted: true,
              recent_user_ids: ['reviewer'],
            },
          ],
        },
      ],
    }
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(rawResponse), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoardPost('post-1')

    expect(result.comments[0]).toMatchObject({
      id: 'comment-1',
      votes: 3,
      vote_balance: 3,
      votes_up: 5,
      votes_down: 2,
      current_vote: 'up',
      has_voted: true,
      report_count: 1,
      moderation_status: 'hidden',
      reactions: [
        {
          emoji: '🚀',
          count: 4,
          reacted: true,
          has_reacted: true,
          recent_user_ids: ['reviewer'],
        },
      ],
    })
    expect(result.current_vote).toBe('down')
    expect(result.reactions).toEqual([
      {
        emoji: '👍',
        count: 1,
        reacted: false,
        has_reacted: false,
        recent_user_ids: ['reader-a'],
      },
    ])
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('format=flat')
    expect(url).toContain('voter=')
    expect(url).toContain('blind_votes=true')
  })
})

describe('createPost', () => {
  it('passes hearth assignment through to the board post tool', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await createPost('Plan', 'Body', 'dashboard-user', { hearth: ' ops ' })

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/tools/masc_board_post')
    expect(JSON.parse(String(init.body))).toMatchObject({
      title: 'Plan',
      content: 'Body',
      author: 'dashboard-user',
      hearth: 'ops',
    })
  })
})

describe('SubBoard API helpers', () => {
  it('normalizes sub-board members', () => {
    expect(normalizeSubBoard({
      id: 'sb-1',
      slug: 'ops',
      name: 'Ops',
      owner: 'agent-owner',
      members: [' agent-owner ', { name: 'agent-a' }, ''],
      access: 'members_only',
      created_at: 1_700_000_000,
      post_count: 2,
    })).toMatchObject({
      id: 'sb-1',
      slug: 'ops',
      owner: 'agent-owner',
      members: ['agent-owner', 'agent-a'],
      access: 'members_only',
      post_count: 2,
    })
  })

  it('sends create-time members with the sub-board create request', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await createSubBoard('ops', 'Ops', 'Operations', 'members_only', [' agent-a ', '', 'agent-b'])

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/board/sub-boards')
    expect(JSON.parse(String(init.body))).toMatchObject({
      slug: 'ops',
      name: 'Ops',
      description: 'Operations',
      access: 'members_only',
      members: ['agent-a', 'agent-b'],
    })
  })
})

describe('fetchBoardKarmaLedger', () => {
  it('normalizes ledger events, totals, and scoring rule', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        events: [
          {
            recipient: 'keeper-a',
            voter: 'operator',
            target_kind: 'post',
            target_id: 'post-1',
            delta: 1,
            ts: 1_748_779_200,
            ts_iso: '2025-06-01T12:00:00Z',
          },
          { recipient: '', voter: 'ignored', target_kind: 'post', target_id: 'post-x' },
        ],
        count: 2,
        scoring_rule: 'up=+1,down=0',
        totals: [
          { agent: 'keeper-a', karma: 3 },
          { agent: '', karma: 9 },
        ],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoardKarmaLedger({ agent: ' keeper-a ', limit: 25.9 })

    expect(result).toEqual({
      events: [
        {
          recipient: 'keeper-a',
          voter: 'operator',
          target_kind: 'post',
          target_id: 'post-1',
          delta: 1,
          ts: 1_748_779_200,
          ts_iso: '2025-06-01T12:00:00Z',
        },
      ],
      count: 2,
      scoring_rule: 'up=+1,down=0',
      totals: [{ agent: 'keeper-a', karma: 3 }],
    })
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/v1/board/karma/ledger?agent=keeper-a&limit=25',
      expect.any(Object),
    )
  })

  it('falls back to event length when the ledger count is absent', () => {
    expect(normalizeBoardKarmaLedger({
      events: [
        {
          recipient: 'keeper-a',
          voter: 'operator',
          target_kind: 'comment',
          target_id: 'comment-1',
          delta: 1,
          ts: 1_748_779_200,
        },
      ],
    })).toMatchObject({
      count: 1,
      events: [{ ts_iso: '2025-06-01T12:00:00.000Z' }],
      totals: [],
    })
  })
})

describe('voteComment', () => {
  it('posts to the comment vote tool with the dashboard voter', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-reviewer')
    const fetchMock = vi.fn().mockResolvedValue(
      new Response('{}', {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await voteComment('comment-1', 'down')

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/tools/masc_board_comment_vote')
    expect(JSON.parse(String(init.body))).toMatchObject({
      comment_id: 'comment-1',
      direction: 'down',
      vote: 'down',
      voter: 'dashboard-reviewer',
    })
  })
})

describe('board reactions', () => {
  it('fetches reaction summaries with the dashboard voter', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-reviewer')
    vi.spyOn(performance, 'now')
      .mockReturnValueOnce(0)
      .mockReturnValueOnce(18)
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        reactions: [{
          emoji: '👍',
          count: 2,
          has_reacted: true,
          recent_user_ids: ['agent-b', 'agent-a'],
        }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await fetchBoardReactions('post', 'post-1')

    expect(result).toEqual([{
      emoji: '👍',
      count: 2,
      reacted: true,
      has_reacted: true,
      recent_user_ids: ['agent-b', 'agent-a'],
    }])
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/api/v1/board/reactions?')
    expect(url).toContain('target_type=post')
    expect(url).toContain('target_id=post-1')
    expect(url).toContain('user_id=dashboard-reviewer')
    expect(boardLatencyMetrics.value.reaction_summary).toMatchObject({
      last_latency_ms: 18,
      last_ok: true,
      sample_count: 1,
    })
  })

  it('toggles a reaction through the board reaction endpoint', async () => {
    window.history.replaceState({}, '', '/?agent=dashboard-reviewer')
    vi.spyOn(performance, 'now')
      .mockReturnValueOnce(10)
      .mockReturnValueOnce(31)
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({
        target_type: 'comment',
        target_id: 'comment-1',
        user_id: 'dashboard-reviewer',
        emoji: '🚀',
        reacted: true,
        summary: [{
          emoji: '🚀',
          count: 1,
          has_reacted: true,
          recent_user_ids: ['dashboard-reviewer'],
        }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const result = await toggleReaction('comment', 'comment-1', '🚀')

    expect(result.summary).toEqual([{
      emoji: '🚀',
      count: 1,
      reacted: true,
      has_reacted: true,
      recent_user_ids: ['dashboard-reviewer'],
    }])
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/v1/board/reactions')
    expect(JSON.parse(String(init.body))).toMatchObject({
      target_type: 'comment',
      target_id: 'comment-1',
      user_id: 'dashboard-reviewer',
      emoji: '🚀',
    })
    expect(boardLatencyMetrics.value.reaction_toggle).toMatchObject({
      last_latency_ms: 21,
      last_ok: true,
      sample_count: 1,
    })
  })
})
