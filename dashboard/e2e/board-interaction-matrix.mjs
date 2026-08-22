import { chromium } from 'playwright'

const baseUrl = process.env.MASC_DASHBOARD_URL ?? 'http://127.0.0.1:8935'
const artifactDir = process.env.MASC_BOARD_E2E_ARTIFACT_DIR ?? '/tmp'
const adminToken = process.env.MASC_BOARD_E2E_ADMIN_TOKEN
if (!adminToken) throw new Error('MASC_BOARD_E2E_ADMIN_TOKEN is required for fixture cleanup')
const runId = `${Date.now()}-${process.pid}`
const requestedActor = `board-e2e-author-${runId}`
const observerActor = `board-e2e-observer-${runId}`
let author = requestedActor
const title = `Board interaction matrix ${runId}`
const postBody = [
  'Live Board matrix fixture.',
  '',
  '[Matrix link](https://example.com/masc-board-matrix)',
  '',
  '```ocaml',
  'let matrix = "post-vote-karma-reaction"',
  '```',
].join('\n')
const commentBody = [
  `Comment matrix fixture ${runId}.`,
  '',
  '[Comment link](https://example.com/masc-board-comment)',
  '',
  '```ocaml',
  'let comment_matrix = "vote-reaction"',
  '```',
].join('\n')
const formCommentBody = `Comment form interaction ${runId}`
const interactionScreenshot = `${artifactDir}/board-interaction-matrix.png`
const karmaScreenshot = `${artifactDir}/board-karma-matrix.png`
const timeoutMs = 20_000
const pollIntervalMs = 750

function check(condition, message) {
  if (!condition) throw new Error(message)
}

async function eventually(read, accept, label) {
  const deadline = Date.now() + timeoutMs
  let latest
  while (Date.now() < deadline) {
    latest = await read()
    if (accept(latest)) return latest
    await new Promise(resolve => setTimeout(resolve, pollIntervalMs))
  }
  throw new Error(`${label}: timed out; latest=${JSON.stringify(latest)}`)
}

async function api(page, credential, path, options = {}) {
  return page.evaluate(async ({ credential, path, options }) => {
    const headers = {
      Authorization: `Bearer ${credential.token}`,
      'X-MASC-Agent': options.actor ?? credential.actor,
    }
    if (options.body !== undefined) headers['Content-Type'] = 'application/json'
    const response = await fetch(path, {
      method: options.method ?? 'GET',
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.timeout(options.timeoutMs ?? 20_000),
    })
    const text = await response.text()
    let json = null
    if (text) {
      try { json = JSON.parse(text) } catch { json = { raw: text } }
    }
    return { status: response.status, ok: response.ok, json }
  }, { credential, path, options })
}

async function tool(page, credential, path, actor, body) {
  const result = await api(page, credential, path, {
    method: 'POST',
    actor,
    body,
  })
  check(result.ok, `${path}: HTTP ${result.status} ${JSON.stringify(result.json)}`)
  check(result.json?.ok === true, `${path}: tool rejected ${JSON.stringify(result.json)}`)
  return result.json
}

async function clickForResponse(page, locator, path, label) {
  await eventually(
    () => locator.isEnabled(),
    enabled => enabled === true,
    `${label} enabled state`,
  )
  let requestSeen = false
  const observeRequest = request => {
    if (request.url().includes(path) && request.method() === 'POST') requestSeen = true
  }
  page.on('request', observeRequest)
  const responsePromise = page.waitForResponse(response =>
    response.url().includes(path) && response.request().method() === 'POST',
  )
  try {
    await locator.click()
    const response = await responsePromise
    const body = await response.text()
    check(response.ok(), `${label}: HTTP ${response.status()} ${body}`)
  } catch (error) {
    throw new Error(`${label}: request_seen=${requestSeen}; ${error instanceof Error ? error.message : error}`)
  } finally {
    page.off('request', observeRequest)
  }
}

async function detail(page, credential, postId, voter) {
  const params = new URLSearchParams({
    format: 'flat',
    voter,
  })
  const result = await api(page, credential, `/api/v1/board/${postId}?${params}`, { actor: observerActor })
  check(result.ok, `board detail: HTTP ${result.status} ${JSON.stringify(result.json)}`)
  return result.json
}

function postState(payload) {
  const post = payload.post ?? payload
  return {
    score: post.score,
    votesUp: post.votes_up,
    votesDown: post.votes_down,
    currentVote: post.current_vote ?? null,
    reactions: post.reactions ?? [],
  }
}

function findComment(payload, commentId) {
  const comment = (payload.comments ?? []).find(row => row.id === commentId)
  check(comment, `comment ${commentId} is absent from board detail`)
  return comment
}

function reactionState(rows, emoji) {
  const row = (rows ?? []).find(candidate => candidate.emoji === emoji)
  return { count: row?.count ?? 0, reacted: row?.reacted ?? false }
}

async function karma(page, credential) {
  const params = new URLSearchParams({ agent: author, limit: '25' })
  const result = await api(page, credential, `/api/v1/board/karma/ledger?${params}`, { actor: observerActor })
  check(result.ok, `karma ledger: HTTP ${result.status} ${JSON.stringify(result.json)}`)
  return result.json
}

function karmaTotal(payload) {
  return payload.totals?.find(row => row.agent === author)?.karma ?? 0
}

function karmaTargets(payload) {
  return new Set((payload.events ?? []).map(event => `${event.target_kind}:${event.target_id}`))
}

const browser = await chromium.launch({ headless: true })
let page
let credential
let postId
let commentId
let testError = null
const matrix = []

try {
  page = await browser.newPage({ viewport: { width: 1440, height: 1000 } })
  const browserErrors = []
  const httpErrors = []
  const httpErrorCaptures = []
  page.on('console', message => {
    if (message.type() === 'error') browserErrors.push(message.text())
  })
  page.on('pageerror', error => browserErrors.push(error.message))
  page.on('response', response => {
    if (response.status() >= 400) {
      httpErrorCaptures.push((async () => {
        let body = ''
        try { body = await response.text() } catch {}
        httpErrors.push({
          status: response.status(),
          url: response.url(),
          actor: response.request().headers()['x-masc-agent'] ?? null,
          body,
        })
      })())
    }
  })

  const credentialResponse = page.waitForResponse(response =>
    response.url().includes('/api/v1/dashboard/dev-token') && response.request().method() === 'GET',
  )
  await page.goto(`${baseUrl}/#board`)
  await page.getByTestId('bd-composer').waitFor({ timeout: timeoutMs })
  const bootCredentialResponse = await credentialResponse
  check(bootCredentialResponse.ok(), `dev token HTTP ${bootCredentialResponse.status()}`)
  credential = await bootCredentialResponse.json()
  check(typeof credential.token === 'string' && credential.token.length > 0, 'dashboard dev token is absent')
  check(typeof credential.actor === 'string' && credential.actor.length > 0, 'dashboard actor is absent')

  await tool(page, credential, '/api/v1/tools/masc_board_post', requestedActor, {
    title,
    content: postBody,
    author,
  })
  const authorList = await eventually(
    () => api(
      page,
      credential,
      `/api/v1/board?limit=150&voter=${encodeURIComponent(credential.actor)}`,
      { actor: observerActor },
    ),
    result => result.ok && result.json?.posts?.some(row => row.title === title),
    'created post list projection',
  )
  check(authorList.ok, `author board list: HTTP ${authorList.status}`)
  const createdPost = authorList.json?.posts?.find(row => row.title === title)
  check(createdPost, 'created post was not returned by its exact title query')
  postId = createdPost.id
  author = createdPost.author

  await tool(page, credential, '/api/v1/tools/masc_board_comment', requestedActor, {
    post_id: postId,
    author,
    content: commentBody,
  })
  const createdDetail = await detail(page, credential, postId, credential.actor)
  const createdComment = createdDetail.comments?.find(row => row.author === author && row.content === commentBody)
  check(createdComment, 'created comment was not returned by exact author/content')
  commentId = createdComment.id
  matrix.push('create fixture -> exact API read')

  await page.evaluate(postId => {
    window.location.hash = `#board?post=${encodeURIComponent(postId)}`
  }, postId)
  const detailPanel = page
  try {
    await detailPanel.getByRole('link', { name: 'Matrix link', exact: true }).waitFor({ timeout: timeoutMs })
  } catch (error) {
    process.stderr.write(`${JSON.stringify({
      url: page.url(),
      body: (await page.locator('body').innerText()).slice(0, 4_000),
      browser_errors: browserErrors,
    }, null, 2)}\n`)
    throw error
  }
  await detailPanel.getByText('let matrix = "post-vote-karma-reaction"', { exact: true }).waitFor()
  await detailPanel.getByRole('link', { name: 'Comment link', exact: true }).waitFor()
  await detailPanel.getByText('let comment_matrix = "vote-reaction"', { exact: true }).waitFor()
  matrix.push('post/comment markdown link + code rendering')

  const commentInput = detailPanel.getByPlaceholder('댓글 추가...')
  await commentInput.fill(formCommentBody)
  const formResponse = page.waitForResponse(response => response.url().includes('/api/v1/tools/masc_board_comment'))
  await detailPanel.getByRole('button', { name: '등록', exact: true }).click()
  const formResult = await formResponse
  check(formResult.ok(), `comment form HTTP ${formResult.status()}`)
  await detailPanel.getByText(formCommentBody, { exact: true }).waitFor()
  matrix.push('comment form -> rendered comment')

  const initial = postState(await detail(page, credential, postId, credential.actor))
  check(initial.currentVote === null, `post initial current vote is ${initial.currentVote}`)
  const initialKarma = await karma(page, credential)
  check(karmaTotal(initialKarma) === 0, 'unique fixture author already has karma')

  const postUp = detailPanel.getByRole('button', { name: '▲ 추천', exact: true })
  const postDown = detailPanel.getByRole('button', { name: '▼ 비추천', exact: true })
  await clickForResponse(page, postUp, '/api/v1/tools/masc_board_vote', 'post upvote')
  await eventually(
    () => postUp.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'post upvote UI state',
  )
  let liveDetail = await detail(page, credential, postId, credential.actor)
  check(postState(liveDetail).currentVote === 'up', 'post upvote current_vote mismatch')
  check(postState(liveDetail).score === initial.score + 1, 'post upvote did not add exactly one score')
  check(karmaTotal(await karma(page, credential)) === 1, 'post upvote did not add exactly one author karma')
  check(await postUp.isDisabled(), 'active post upvote is not disabled in the UI')

  const duplicatePost = await api(page, credential, '/api/v1/tools/masc_board_vote', {
    method: 'POST',
    body: { post_id: postId, direction: 'up', vote: 'up', voter: credential.actor },
  })
  check(
    duplicatePost.status === 200 && duplicatePost.json?.ok === true,
    `duplicate post upvote was not idempotent: ${JSON.stringify(duplicatePost)}`,
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(postState(liveDetail).score === initial.score + 1, 'duplicate post upvote changed the score')
  check(karmaTotal(await karma(page, credential)) === 1, 'duplicate post upvote changed karma')
  matrix.push('post upvote + duplicate idempotence + karma +1')

  await clickForResponse(page, postDown, '/api/v1/tools/masc_board_vote', 'post downvote')
  await eventually(
    () => postDown.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'post up-to-down UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(postState(liveDetail).currentVote === 'down', 'post up-to-down current_vote mismatch')
  check(postState(liveDetail).score === initial.score - 1, 'post up-to-down flip did not move score by two')
  check(karmaTotal(await karma(page, credential)) === 0, 'post downvote retained positive karma')
  await clickForResponse(page, postUp, '/api/v1/tools/masc_board_vote', 'post upvote restore')
  await eventually(
    () => postUp.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'post down-to-up UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(postState(liveDetail).currentVote === 'up', 'post down-to-up current_vote mismatch')
  check(postState(liveDetail).score === initial.score + 1, 'post down-to-up flip did not restore score')
  check(karmaTotal(await karma(page, credential)) === 1, 'post down-to-up flip did not restore karma')
  matrix.push('post up/down/up flips -> score and karma reversible')

  const commentRow = detailPanel.locator('.board-comment').filter({ hasText: `Comment matrix fixture ${runId}.` })
  const commentUp = commentRow.getByRole('button', { name: '댓글 추천', exact: true })
  const commentDown = commentRow.getByRole('button', { name: '댓글 비추천', exact: true })
  const beforeCommentVote = await detail(page, credential, postId, credential.actor)
  const initialComment = findComment(beforeCommentVote, commentId)
  const postScoreBeforeComment = postState(beforeCommentVote).score
  await clickForResponse(page, commentUp, '/api/v1/tools/masc_board_comment_vote', 'comment upvote')
  await eventually(
    () => commentUp.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'comment upvote UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(findComment(liveDetail, commentId).current_vote === 'up', 'comment upvote current_vote mismatch')
  check(findComment(liveDetail, commentId).score === initialComment.score + 1, 'comment upvote did not add one score')
  check(postState(liveDetail).score === postScoreBeforeComment, 'comment vote mutated post score')
  check(karmaTotal(await karma(page, credential)) === 2, 'comment upvote did not add its own karma')
  check(await commentUp.isDisabled(), 'active comment upvote is not disabled in the UI')

  const duplicateComment = await api(page, credential, '/api/v1/tools/masc_board_comment_vote', {
    method: 'POST',
    body: { comment_id: commentId, direction: 'up', vote: 'up', voter: credential.actor },
  })
  check(
    duplicateComment.status === 200 && duplicateComment.json?.ok === true,
    `duplicate comment upvote was not idempotent: ${JSON.stringify(duplicateComment)}`,
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(findComment(liveDetail, commentId).score === initialComment.score + 1, 'duplicate comment vote changed score')
  check(karmaTotal(await karma(page, credential)) === 2, 'duplicate comment vote changed karma')

  await clickForResponse(page, commentDown, '/api/v1/tools/masc_board_comment_vote', 'comment downvote')
  await eventually(
    () => commentDown.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'comment up-to-down UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(findComment(liveDetail, commentId).current_vote === 'down', 'comment up-to-down current_vote mismatch')
  check(findComment(liveDetail, commentId).score === initialComment.score - 1, 'comment up-to-down flip did not move score by two')
  check(postState(liveDetail).score === postScoreBeforeComment, 'comment flip mutated post score')
  check(karmaTotal(await karma(page, credential)) === 1, 'comment downvote retained positive karma')
  await clickForResponse(page, commentUp, '/api/v1/tools/masc_board_comment_vote', 'comment upvote restore')
  await eventually(
    () => commentUp.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'comment down-to-up UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(findComment(liveDetail, commentId).current_vote === 'up', 'comment down-to-up current_vote mismatch')
  check(findComment(liveDetail, commentId).score === initialComment.score + 1, 'comment down-to-up flip did not restore score')
  check(karmaTotal(await karma(page, credential)) === 2, 'comment down-to-up flip did not restore karma')
  matrix.push('comment upvote + duplicate idempotence + flips + post isolation')

  const postReactionGroup = detailPanel.getByRole('group', { name: '리액션', exact: true }).first()
  const postReactionButton = postReactionGroup.getByRole('button').first()
  const postReactionEmoji = (await postReactionButton.getAttribute('aria-label')).split(' ')[0]
  const postReactionInitial = reactionState(postState(liveDetail).reactions, postReactionEmoji)
  await clickForResponse(page, postReactionButton, '/api/v1/board/reactions', 'post reaction on')
  await eventually(
    () => postReactionButton.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'post reaction on UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(reactionState(postState(liveDetail).reactions, postReactionEmoji).count === postReactionInitial.count + 1, 'post reaction on count mismatch')
  await clickForResponse(page, postReactionButton, '/api/v1/board/reactions', 'post reaction off')
  await eventually(
    () => postReactionButton.getAttribute('aria-pressed'),
    pressed => pressed === 'false',
    'post reaction off UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(reactionState(postState(liveDetail).reactions, postReactionEmoji).count === postReactionInitial.count, 'post reaction off count mismatch')
  await clickForResponse(page, postReactionButton, '/api/v1/board/reactions', 'post reaction restore')
  await eventually(
    () => postReactionButton.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'post reaction final UI state',
  )

  const commentReactionGroup = commentRow.getByRole('group', { name: '리액션', exact: true })
  const commentReactionButton = commentReactionGroup.getByRole('button').first()
  const commentReactionEmoji = (await commentReactionButton.getAttribute('aria-label')).split(' ')[0]
  const commentReactionInitial = reactionState(findComment(liveDetail, commentId).reactions, commentReactionEmoji)
  await clickForResponse(page, commentReactionButton, '/api/v1/board/reactions', 'comment reaction on')
  await eventually(
    () => commentReactionButton.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'comment reaction on UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(reactionState(findComment(liveDetail, commentId).reactions, commentReactionEmoji).count === commentReactionInitial.count + 1, 'comment reaction on count mismatch')
  await clickForResponse(page, commentReactionButton, '/api/v1/board/reactions', 'comment reaction off')
  await eventually(
    () => commentReactionButton.getAttribute('aria-pressed'),
    pressed => pressed === 'false',
    'comment reaction off UI state',
  )
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(reactionState(findComment(liveDetail, commentId).reactions, commentReactionEmoji).count === commentReactionInitial.count, 'comment reaction off count mismatch')
  await clickForResponse(page, commentReactionButton, '/api/v1/board/reactions', 'comment reaction restore')
  await eventually(
    () => commentReactionButton.getAttribute('aria-pressed'),
    pressed => pressed === 'true',
    'comment reaction final UI state',
  )
  matrix.push('post/comment reaction on/off/on')

  await page.screenshot({ path: interactionScreenshot, fullPage: true })
  await page.reload()
  await detailPanel.getByRole('link', { name: 'Matrix link', exact: true }).waitFor({ timeout: timeoutMs })
  liveDetail = await detail(page, credential, postId, credential.actor)
  check(postState(liveDetail).currentVote === 'up', 'post vote was not durable across reload')
  check(findComment(liveDetail, commentId).current_vote === 'up', 'comment vote was not durable across reload')
  check(reactionState(postState(liveDetail).reactions, postReactionEmoji).count === postReactionInitial.count + 1, 'post reaction was not durable across reload')
  check(reactionState(findComment(liveDetail, commentId).reactions, commentReactionEmoji).count === commentReactionInitial.count + 1, 'comment reaction was not durable across reload')
  check(await postReactionButton.getAttribute('aria-pressed') === 'true', 'post reaction actor state was not durable across reload')
  check(await commentReactionButton.getAttribute('aria-pressed') === 'true', 'comment reaction actor state was not durable across reload')
  const durableKarma = await karma(page, credential)
  check(karmaTotal(durableKarma) === 2, 'final karma total is not post + comment')
  const targets = karmaTargets(durableKarma)
  check(targets.has(`post:${postId}`), 'post karma ledger event is absent')
  check(targets.has(`comment:${commentId}`), 'comment karma ledger event is absent')
  matrix.push('reload durability -> vote, reaction, karma ledger')

  await page.getByLabel('보드 카르마 열기').click()
  await page.getByTestId('karma-agent-filter').fill(author)
  await page.getByTestId('karma-filter-apply').click()
  await page.getByText(author, { exact: true }).first().waitFor({ timeout: timeoutMs })
  await page.getByText(`post:${postId}`, { exact: true }).waitFor()
  await page.getByText(`comment:${commentId}`, { exact: true }).waitFor()
  await page.screenshot({ path: karmaScreenshot, fullPage: true })
  matrix.push('Karma panel -> exact recipient and target rows')

  await Promise.all(httpErrorCaptures)
  const boardHttpErrors = httpErrors.filter(error =>
    error.url.includes('/api/v1/board') || error.url.includes('/api/v1/tools/masc_board_'),
  )
  const actionableBrowserErrors = browserErrors.filter(message =>
    !message.startsWith('Failed to load resource:'),
  )
  check(boardHttpErrors.length === 0, `Board HTTP errors: ${JSON.stringify(boardHttpErrors)}`)
  check(actionableBrowserErrors.length === 0, `browser errors: ${actionableBrowserErrors.join(' | ')}`)
} catch (error) {
  testError = error
} finally {
  let cleanupError = null
  if (page && credential && !postId) {
    try {
      const candidates = await api(
        page,
        credential,
        '/api/v1/board?limit=150',
        { actor: observerActor },
      )
      const orphan = candidates.json?.posts?.find(candidate => candidate.title === title)
      if (orphan) {
        postId = orphan.id
        author = orphan.author
      }
    } catch (error) {
      cleanupError = error
    }
  }
  if (page && credential && postId) {
    try {
      const adminCredential = { token: adminToken, actor: 'dashboard-admin' }
      const deleted = await api(page, adminCredential, '/api/v1/dashboard/board/delete', {
        method: 'POST',
        body: { post_id: postId },
      })
      check(deleted.ok && deleted.json?.ok === true, `delete failed: ${JSON.stringify(deleted)}`)
      const deletedDetail = await api(page, credential, `/api/v1/board/${postId}`)
      check(deletedDetail.status === 404, `deleted post still reads with HTTP ${deletedDetail.status}`)
      const deletedKarma = await karma(page, credential)
      check(karmaTotal(deletedKarma) === 0, 'deleted fixture left a karma total')
      check((deletedKarma.events ?? []).length === 0, 'deleted fixture left karma ledger events')
      matrix.push('cleanup -> post/comment/vote/reaction/karma removed')
    } catch (error) {
      cleanupError = error
    }
  }
  await browser.close()
  if (testError && cleanupError) {
    throw new AggregateError([testError, cleanupError], 'Board matrix and cleanup both failed')
  }
  if (testError) throw testError
  if (cleanupError) throw cleanupError
}

process.stdout.write(`${JSON.stringify({
  ok: true,
  run_id: runId,
  requested_actor: requestedActor,
  observer_actor: observerActor,
  author,
  voter: credential.actor,
  post_id: postId,
  comment_id: commentId,
  matrix,
  interaction_screenshot: interactionScreenshot,
  karma_screenshot: karmaScreenshot,
}, null, 2)}\n`)
