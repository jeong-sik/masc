import { readFile } from 'node:fs/promises'

const dashboardUrl = new URL(process.env.MASC_DASHBOARD_URL ?? 'http://127.0.0.1:8935')
const baseUrl = dashboardUrl.origin
const mcpUrl = process.env.MASC_MCP_URL ?? new URL('/mcp', baseUrl).toString()
const adminToken = process.env.MASC_BOARD_E2E_ADMIN_TOKEN
const authorAgent = process.env.MASC_KEEPER_E2E_AUTHOR
const voterAgent = process.env.MASC_KEEPER_E2E_VOTER
const authorTokenFile = process.env.MASC_KEEPER_E2E_AUTHOR_TOKEN_FILE
const voterTokenFile = process.env.MASC_KEEPER_E2E_VOTER_TOKEN_FILE

for (const [name, value] of Object.entries({
  MASC_BOARD_E2E_ADMIN_TOKEN: adminToken,
  MASC_KEEPER_E2E_AUTHOR: authorAgent,
  MASC_KEEPER_E2E_VOTER: voterAgent,
  MASC_KEEPER_E2E_AUTHOR_TOKEN_FILE: authorTokenFile,
  MASC_KEEPER_E2E_VOTER_TOKEN_FILE: voterTokenFile,
})) {
  if (!value) throw new Error(`${name} is required`)
}
if (authorAgent === voterAgent) throw new Error('Keeper author and voter must be different identities')

const authorToken = (await readFile(authorTokenFile, 'utf8')).trim()
const voterToken = (await readFile(voterTokenFile, 'utf8')).trim()
if (!authorToken || !voterToken) throw new Error('Keeper bearer token file is empty')

const runId = `${Date.now()}-${process.pid}`
const title = `Keeper direct Board matrix ${runId}`
const postBody = `Keeper-authored MCP fixture ${runId}`
const commentBody = `Keeper-authored MCP comment ${runId}`
const reactionEmoji = '👍'
const timeoutMs = 20_000
const transportTimeoutMs = 120_000
const karmaLedgerApiLimit = 5_000
const pollIntervalMs = 500
const matrix = []
const mcpSessionClosers = []
let postId
let commentId
let author
let testError

function check(condition, message) {
  if (!condition) throw new Error(message)
}

async function eventually(read, accept, label) {
  const deadline = Date.now() + timeoutMs
  let latest
  while (true) {
    const remainingMs = deadline - Date.now()
    if (remainingMs <= 0) break
    latest = await read(remainingMs)
    if (accept(latest)) return latest
    await new Promise(resolve => setTimeout(resolve, Math.min(pollIntervalMs, remainingMs)))
  }
  throw new Error(`${label}: timed out; latest=${JSON.stringify(latest)}`)
}

function authHeaders(token, agent) {
  return {
    Authorization: `Bearer ${token}`,
    'X-MASC-Agent': agent,
  }
}

async function fetchWithTimeout(label, url, options, requestTimeoutMs = transportTimeoutMs) {
  try {
    return await fetch(url, {
      ...options,
      signal: AbortSignal.timeout(requestTimeoutMs),
    })
  } catch (error) {
    throw new Error(`${label}: ${error instanceof Error ? error.message : error}`, { cause: error })
  }
}

async function readJson(path, {
  token = adminToken,
  agent = 'dashboard-admin',
  method = 'GET',
  body,
  timeoutMs: requestTimeoutMs = timeoutMs,
} = {}) {
  const headers = authHeaders(token, agent)
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  const response = await fetchWithTimeout(`${method} ${path}`, `${baseUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  }, requestTimeoutMs)
  const text = await response.text()
  let json = null
  if (text) {
    try { json = JSON.parse(text) } catch { json = { raw: text } }
  }
  return { ok: response.ok, status: response.status, json }
}

function parseMcpBody(text) {
  const dataLines = text
    .split(/\r?\n/)
    .filter(line => line.startsWith('data:'))
    .map(line => line.slice(5).trim())
    .filter(Boolean)
  return JSON.parse(dataLines.at(-1) ?? text)
}

async function createMcpClient(token, agent) {
  const headers = {
    ...authHeaders(token, agent),
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
  }
  const response = await fetchWithTimeout(`MCP initialize ${agent}`, mcpUrl, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2025-11-25',
        clientInfo: { name: 'board-keeper-direct-matrix', version: '1.0' },
        capabilities: {},
      },
    }),
  })
  const text = await response.text()
  check(response.ok, `MCP initialize ${agent}: HTTP ${response.status} ${text}`)
  const payload = parseMcpBody(text)
  check(!payload.error, `MCP initialize ${agent}: ${JSON.stringify(payload.error)}`)
  const sessionId = response.headers.get('mcp-session-id')
  check(sessionId, `MCP initialize ${agent}: mcp-session-id is absent`)
  const protocolVersion = response.headers.get('mcp-protocol-version')
    ?? payload.result?.protocolVersion
  check(protocolVersion, `MCP initialize ${agent}: protocol version is absent`)
  const sessionHeaders = {
    ...headers,
    'Mcp-Session-Id': sessionId,
    'Mcp-Protocol-Version': protocolVersion,
  }
  mcpSessionClosers.push(async () => {
    const closeResponse = await fetchWithTimeout(`MCP session close ${agent}`, mcpUrl, {
      method: 'DELETE',
      headers: sessionHeaders,
    })
    const closeText = await closeResponse.text()
    check(closeResponse.ok, `MCP session close ${agent}: HTTP ${closeResponse.status} ${closeText}`)
  })
  const initializedResponse = await fetchWithTimeout(
    `MCP initialized notification ${agent}`,
    mcpUrl,
    {
      method: 'POST',
      headers: sessionHeaders,
      body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    },
  )
  const initializedText = await initializedResponse.text()
  check(
    initializedResponse.ok,
    `MCP initialized notification ${agent}: HTTP ${initializedResponse.status} ${initializedText}`,
  )

  let callId = 1
  return async (name, args) => {
    callId += 1
    const callResponse = await fetchWithTimeout(`${name} as ${agent}`, mcpUrl, {
      method: 'POST',
      headers: sessionHeaders,
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: callId,
        method: 'tools/call',
        params: { name, arguments: args },
      }),
    })
    const callText = await callResponse.text()
    check(callResponse.ok, `${name} as ${agent}: HTTP ${callResponse.status} ${callText}`)
    const callPayload = parseMcpBody(callText)
    check(!callPayload.error, `${name} as ${agent}: ${JSON.stringify(callPayload.error)}`)
    check(callPayload.result?.isError !== true, `${name} as ${agent}: ${JSON.stringify(callPayload.result)}`)
    process.stderr.write(`[keeper-e2e] ${agent} ${name} ok\n`)
    return callPayload.result
  }
}

async function boardDetail(id, credential, requestTimeoutMs = timeoutMs) {
  const query = new URLSearchParams({
    format: 'flat',
    voter: credential.agent,
  })
  const result = await readJson(`/api/v1/board/${id}?${query}`, {
    ...credential,
    timeoutMs: requestTimeoutMs,
  })
  check(result.ok, `board detail: HTTP ${result.status} ${JSON.stringify(result.json)}`)
  return result.json
}

function findComment(payload, id) {
  return (payload.comments ?? []).find(row => row.id === id)
}

function reaction(rows) {
  const row = (rows ?? []).find(candidate => candidate.emoji === reactionEmoji)
  return {
    count: row?.count ?? 0,
    reacted: row?.reacted ?? false,
    recentUserIds: row?.recent_user_ids ?? [],
  }
}

async function karmaLedger(agent, requestTimeoutMs = timeoutMs) {
  const query = new URLSearchParams({ agent, limit: String(karmaLedgerApiLimit) })
  const result = await readJson(`/api/v1/board/karma/ledger?${query}`, {
    timeoutMs: requestTimeoutMs,
  })
  check(result.ok, `karma ledger: HTTP ${result.status} ${JSON.stringify(result.json)}`)
  return result.json
}

function canonicalKeeperName(agent) {
  const match = /^keeper-(.+)-agent$/.exec(agent)
  return match?.[1] ?? agent
}

function fixtureKarmaEvents(payload) {
  return (payload.events ?? []).filter(event =>
    (event.target_kind === 'post' && event.target_id === postId)
    || (event.target_kind === 'comment' && event.target_id === commentId),
  )
}

try {
  const authorMcp = await createMcpClient(authorToken, authorAgent)
  const voterMcp = await createMcpClient(voterToken, voterAgent)
  const expectedAuthor = canonicalKeeperName(authorAgent)
  const expectedVoter = canonicalKeeperName(voterAgent)

  await authorMcp('masc_board_post', {
    title,
    body: postBody,
    author: 'anonymous',
  })
  const listResult = await eventually(
    remainingMs => readJson('/api/v1/board?limit=150&sort=recent', {
      timeoutMs: remainingMs,
    }),
    result => result.ok && result.json?.posts?.some(post => post.title === title),
    'Keeper-authored post projection',
  )
  const post = listResult.json.posts.find(candidate => candidate.title === title)
  postId = post.id
  author = post.author
  check(author === expectedAuthor, `Keeper bearer projected ${author}, expected ${expectedAuthor}`)

  await authorMcp('masc_board_comment', {
    post_id: postId,
    content: commentBody,
    author: 'anonymous',
  })
  const authoredDetail = await eventually(
    remainingMs => boardDetail(
      postId,
      { token: voterToken, agent: voterAgent },
      remainingMs,
    ),
    payload => payload.comments?.some(comment => comment.content === commentBody),
    'Keeper-authored comment projection',
  )
  const comment = authoredDetail.comments.find(candidate => candidate.content === commentBody)
  commentId = comment.id
  check(comment.author === author, `post/comment Keeper identity mismatch: ${author} vs ${comment.author}`)
  matrix.push('Keeper bearer -> MCP post/comment -> canonical author projection')

  const initialPostScore = authoredDetail.post?.score ?? authoredDetail.score
  const initialCommentScore = comment.score

  await voterMcp('masc_board_vote', { post_id: postId, direction: 'up' })
  await voterMcp('masc_board_comment_vote', { comment_id: commentId, direction: 'up' })
  const votedDetail = await eventually(
    remainingMs => boardDetail(
      postId,
      { token: voterToken, agent: voterAgent },
      remainingMs,
    ),
    payload => {
      const currentPost = payload.post ?? payload
      const currentComment = findComment(payload, commentId)
      return currentPost.current_vote === 'up' && currentComment?.current_vote === 'up'
    },
    'Keeper vote projection',
  )
  const votedPost = votedDetail.post ?? votedDetail
  const votedComment = findComment(votedDetail, commentId)
  check(votedPost.score === initialPostScore + 1, 'Keeper post vote did not add exactly one score')
  check(votedComment.score === initialCommentScore + 1, 'Keeper comment vote did not add exactly one score')
  matrix.push('second Keeper bearer -> MCP post/comment votes -> exact score deltas')

  await voterMcp('masc_board_reaction', {
    target_type: 'post',
    target_id: postId,
    user_id: 'anonymous',
    emoji: reactionEmoji,
  })
  await voterMcp('masc_board_reaction', {
    target_type: 'comment',
    target_id: commentId,
    user_id: 'anonymous',
    emoji: reactionEmoji,
  })
  const reactedDetail = await eventually(
    remainingMs => boardDetail(
      postId,
      { token: voterToken, agent: voterAgent },
      remainingMs,
    ),
    payload => {
      const currentPost = payload.post ?? payload
      const currentComment = findComment(payload, commentId)
      const postReaction = reaction(currentPost.reactions)
      const commentReaction = reaction(currentComment?.reactions)
      return postReaction.count === 1 && postReaction.reacted
        && commentReaction.count === 1 && commentReaction.reacted
    },
    'Keeper reaction projection',
  )
  check(reaction((reactedDetail.post ?? reactedDetail).reactions).count === 1, 'post reaction count mismatch')
  check(reaction(findComment(reactedDetail, commentId).reactions).count === 1, 'comment reaction count mismatch')
  check(
    reaction((reactedDetail.post ?? reactedDetail).reactions).recentUserIds.includes(expectedVoter),
    `post reaction voter is not ${expectedVoter}`,
  )
  check(
    reaction(findComment(reactedDetail, commentId).reactions).recentUserIds.includes(expectedVoter),
    `comment reaction voter is not ${expectedVoter}`,
  )
  matrix.push('second Keeper bearer -> MCP post/comment reactions -> actor state')

  const earned = await eventually(
    remainingMs => karmaLedger(author, remainingMs),
    payload => {
      const events = fixtureKarmaEvents(payload)
      return events.length === 2
        && events.every(event => event.delta === 1 && event.voter === expectedVoter)
    },
    'Keeper-authored Karma projection',
  )
  const fixtureEvents = fixtureKarmaEvents(earned)
  const targets = new Set(fixtureEvents.map(event => `${event.target_kind}:${event.target_id}`))
  check(targets.has(`post:${postId}`), 'post Karma ledger event is absent')
  check(targets.has(`comment:${commentId}`), 'comment Karma ledger event is absent')
  check(fixtureEvents.reduce((total, event) => total + event.delta, 0) === 2, 'fixture Karma delta is not +2')
  matrix.push('Keeper votes -> author Karma +2 -> exact target ledger rows')
} catch (error) {
  testError = error
} finally {
  let cleanupError
  if (!postId) {
    try {
      const candidates = await readJson('/api/v1/board?limit=150&sort=recent')
      const orphan = candidates.json?.posts?.find(candidate => candidate.title === title)
      if (orphan) {
        postId = orphan.id
        author = orphan.author
      }
    } catch (error) {
      cleanupError = error
    }
  }
  if (postId) {
    try {
      const deleted = await readJson('/api/v1/dashboard/board/delete', {
        method: 'POST',
        body: { post_id: postId },
        timeoutMs: transportTimeoutMs,
      })
      check(deleted.ok && deleted.json?.ok === true, `delete failed: ${JSON.stringify(deleted)}`)
      const deletedDetail = await readJson(`/api/v1/board/${postId}`)
      check(deletedDetail.status === 404, `deleted post still reads with HTTP ${deletedDetail.status}`)
      if (author !== undefined) {
        const cleaned = await eventually(
          remainingMs => karmaLedger(author, remainingMs),
          payload => fixtureKarmaEvents(payload).length === 0,
          'Karma cleanup projection',
        )
        const staleTargets = new Set((cleaned.events ?? []).map(event => `${event.target_kind}:${event.target_id}`))
        check(!staleTargets.has(`post:${postId}`), 'deleted post left a Karma ledger event')
        check(!staleTargets.has(`comment:${commentId}`), 'deleted comment left a Karma ledger event')
      }
      matrix.push('admin cleanup -> post/comment/vote/reaction/Karma removed')
    } catch (error) {
      cleanupError = error
    }
  }
  const sessionCloseResults = await Promise.allSettled(mcpSessionClosers.map(close => close()))
  const sessionCloseErrors = sessionCloseResults
    .filter(result => result.status === 'rejected')
    .map(result => result.reason)
  if (sessionCloseErrors.length > 0) {
    const sessionCloseError = new AggregateError(sessionCloseErrors, 'MCP session cleanup failed')
    cleanupError = cleanupError
      ? new AggregateError([cleanupError, sessionCloseError], 'Board and MCP cleanup both failed')
      : sessionCloseError
  }
  if (testError && cleanupError) {
    throw new AggregateError([testError, cleanupError], 'Keeper matrix and cleanup both failed')
  }
  if (testError) throw testError
  if (cleanupError) throw cleanupError
}

process.stdout.write(`${JSON.stringify({
  ok: true,
  run_id: runId,
  author_keeper: authorAgent,
  voter_keeper: voterAgent,
  projected_author: author,
  projected_voter: canonicalKeeperName(voterAgent),
  post_id: postId,
  comment_id: commentId,
  fixture_karma_delta: 2,
  matrix,
}, null, 2)}\n`)
