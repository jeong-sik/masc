import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { v7 as uuidV7 } from 'uuid'
import { decodeHTML } from 'entities'
import { artifactDiscussionRequest, matchArtifactDiscussionReceipt, sendArtifactDiscussion, type ArtifactDiscussionCommand, type ArtifactDiscussionRequest, type ArtifactThread } from '../../api/artifact-discussion'
import { fetchArtifactDraft } from '../../api/artifact-drafts'
import { sameDraftTarget } from '../../api/artifact-draft-live'
import { discussionLocals, discardDiscussionLocal, retainDiscussionLocal, type DiscussionInput, type DiscussionLocalRecord } from '../../lib/artifact-discussion-local'
import { draftBytes, type ArtifactLiveSession, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { escapeArtifactHtmlText } from '../../lib/artifact-html-text'
import { resolveSharedSelection, restoreSharedDocument, type SharedSelection } from '../../lib/artifact-shared-document'

type Composer = { id: string; actor: string; input: DiscussionInput; record: DiscussionLocalRecord | null; recoveredFrom: readonly DiscussionLocalRecord[] }
const meaningful = (input: DiscussionInput) => input.body !== '' || (input.kind === 'comment' && (input.proposing || input.proposal !== ''))
function commandOf(input: DiscussionInput): ArtifactDiscussionCommand {
  return input.kind === 'reply' ? { kind: 'reply', thread_id: input.threadId, body: input.body }
    : { kind: 'comment', position: input.source.position, quote: input.source.quote, body: input.body,
      proposal: input.proposing ? (input.source.mode === 'html_text' ? escapeArtifactHtmlText(input.proposal) : input.proposal) : null }
}
const requestOf = (record: DiscussionLocalRecord): ArtifactDiscussionRequest => record.value.kind === 'request' ? record.value.request
  : { id: record.value.input.operationId, command: commandOf(record.value.input) }
function sourceStatus(session: ArtifactLiveSession, thread: ArtifactThread) {
  const range = resolveSharedSelection(session.doc, { anchor: [...thread.position.anchor], head: [...thread.position.head] })
  return !range ? 'missing' : session.content.slice(Math.min(range.anchor,range.head),Math.max(range.anchor,range.head)) === thread.quote ? 'matching' : 'changed'
}

export function ArtifactDiscussionPanel({ session, state, onPending, onReveal }: {
  session: ArtifactLiveSession; state: ArtifactLiveState; onPending: (pending: boolean) => void; onReveal: (position: SharedSelection) => void;
}) {
  const [composer, setComposer] = useState<Composer | null>(null), composerRef = useRef<Composer | null>(null)
  const [records, setRecords] = useState(() => discussionLocals(session.workspace, state.view.draft.target.artifact_id))
  const recordsRef = useRef(records)
  const [busy, setBusy] = useState<ReadonlySet<string>>(new Set()), busyRef = useRef(new Map<string, AbortController>())
  const [notice, setNotice] = useState<{ text: string; error: boolean } | null>(null)
  const active = useRef(true)
  const transferred = useRef(new Map<string, readonly DiscussionLocalRecord[]>())
  const target = state.view.draft.target
  const actor = state.peers.find(peer => peer.session_id === state.sessionId)?.actor ?? null
  const connected = state.connection === 'connected' && session.current
  const visible = () => active.current && session.current
  const canUseConnection = () => visible() && session.snapshot.connection === 'connected' && actor !== null
    && session.snapshot.peers.find(peer=>peer.session_id===session.snapshot.sessionId)?.actor === actor
  const tell = (text: string, error = false) => { if (visible()) setNotice({ text, error }) }
  const reportPending = () => onPending(Boolean(composerRef.current && meaningful(composerRef.current.input))
    || busyRef.current.size > 0 || recordsRef.current.length > 0)
  const refresh = () => {
    const current = discussionLocals(session.workspace, target.artifact_id)
    recordsRef.current = current; reportPending()
    if (visible()) setRecords(current)
  }
  const updateComposer = (next: Composer | null) => { composerRef.current = next; reportPending(); if (visible()) setComposer(next) }
  useLayoutEffect(() => { reportPending() }, [])
  const discard = (copies: readonly DiscussionLocalRecord[]) => { copies.forEach(discardDiscussionLocal); refresh() }
  const preserve = (next: Composer) => {
    if (meaningful(next.input)) {
      next = { ...next, record: retainDiscussionLocal(next.id, session.workspace, target, next.actor, { kind: 'input', input: next.input }) }
      if (next.record?.persisted) next.recoveredFrom.forEach(discardDiscussionLocal)
    } else { discard([...(next.record ? [next.record] : []), ...next.recoveredFrom]); next = { ...next, record: null } }
    updateComposer(next); refresh()
  }
  const edit = (change: (input: DiscussionInput) => DiscussionInput) => {
    const current = composerRef.current
    if (current) preserve({ ...current, input: change(current.input) })
  }
  useEffect(() => {
    const storage = () => refresh()
    const abortFlights = () => {
      const flights = [...busyRef.current.values()]
      busyRef.current.clear()
      reportPending()
      flights.forEach(flight => flight.abort())
    }
    const pagehide = () => { abortFlights(); if (active.current) setBusy(new Set()) }
    window.addEventListener('storage',storage)
    window.addEventListener('pagehide',pagehide)
    return () => { active.current = false; abortFlights(); window.removeEventListener('storage',storage); window.removeEventListener('pagehide',pagehide); onPending(false) }
  }, [])
  const begin = (input: DiscussionInput) => {
    if (!canUseConnection() || !actor) return
    updateComposer({ id: crypto.randomUUID(), actor, input, record: null, recoveredFrom: [] })
    tell('입력은 이 브라우저에 보관합니다. 내용을 확인한 뒤 보내 주세요.')
  }
  const comment = () => {
    try { begin({ kind: 'comment', operationId: uuidV7(), source: session.captureSource(), body: '', proposing: false, proposal: '' }) }
    catch (error) { tell(error instanceof Error ? error.message : '문장을 선택하지 못했습니다.', true) }
  }
  const finish = (record: DiscussionLocalRecord, view: typeof state.view) => {
    const receipt = matchArtifactDiscussionReceipt(view, record.target, record.actor, requestOf(record))
    if (!receipt) return false
    if (!session.acceptServerView(view)) return false
    discardDiscussionLocal(record)
    transferred.current.get(record.id)?.forEach(discardDiscussionLocal); transferred.current.delete(record.id); refresh()
    tell('요청 처리 기록을 확인했습니다. 현재 댓글과 원고를 표시합니다.')
    return true
  }
  const run = async (record: DiscussionLocalRecord, send: boolean) => {
    if (record.value.kind !== 'request' || !canUseConnection() || !sameDraftTarget(record.target,target) || busyRef.current.has(record.id)) return
    if (send && actor !== record.actor) { tell('처음 요청을 보낸 편집자로 다시 연결해 주세요. 복구 내용은 다운로드할 수 있습니다.',true); return }
    if (send && session.snapshot.pending && ['comment','accept'].includes(record.value.request.command.kind)) { tell('공유 원고가 저장된 뒤 보내 주세요.',true); return }
    const currentAttempt = session.captureCurrent()
    const flight = new AbortController()
    busyRef.current.set(record.id, flight); reportPending(); setBusy(new Set(busyRef.current.keys()))
    try {
      const view = send ? await sendArtifactDiscussion(record.target,record.value.request,record.workspace,flight.signal)
        : await fetchArtifactDraft(record.target.artifact_id,record.workspace,flight.signal)
      if (!currentAttempt()) return
      if (!finish(record,view)) {
        session.acceptServerView(view)
        tell(send ? '응답에서 처리 기록을 확인하지 못했습니다. 같은 요청을 보존했습니다.' : '아직 이 요청의 처리 기록이 없습니다. 같은 요청으로 다시 보낼 수 있습니다.',true)
      }
    } catch (error) {
      if (currentAttempt()) tell(`${error instanceof Error ? error.message : '전송 결과를 확인하지 못했습니다.'} 요청을 보존했으니 결과를 확인해 주세요.`,true)
    }
    finally {
      if (busyRef.current.get(record.id) === flight) {
        busyRef.current.delete(record.id)
        reportPending()
        if (active.current) setBusy(new Set(busyRef.current.keys()))
        if (visible()) refresh()
      }
    }
  }
  const submit = () => {
    const current = composerRef.current
    if (!current || !canUseConnection() || actor !== current.actor || !current.input.body.trim()) return
    const request = { id: current.input.operationId, command: commandOf(current.input) }
    if (session.snapshot.pending && request.command.kind === 'comment') { tell('공유 원고가 저장된 뒤 보내 주세요.',true); return }
    const record = retainDiscussionLocal(current.id,session.workspace,target,current.actor,{kind:'request',request})
    transferred.current.set(record.id,current.recoveredFrom)
    if (record.persisted) current.recoveredFrom.forEach(discardDiscussionLocal)
    updateComposer(null); refresh(); void run(record,true)
  }
  const act = (command: ArtifactDiscussionCommand) => {
    if (!canUseConnection() || !actor) return
    const record = retainDiscussionLocal(crypto.randomUUID(),session.workspace,target,actor,{kind:'request',request:artifactDiscussionRequest(command)})
    refresh(); void run(record,true)
  }
  const recover = async (record: DiscussionLocalRecord) => {
    if (record.value.kind !== 'input' || !canUseConnection() || actor !== record.actor || !sameDraftTarget(record.target,target) || busyRef.current.has(record.id)) return
    const currentAttempt = session.captureCurrent()
    const flight = new AbortController()
    busyRef.current.set(record.id, flight); reportPending(); setBusy(new Set(busyRef.current.keys()))
    try {
      const view = await fetchArtifactDraft(record.target.artifact_id,record.workspace,flight.signal)
      if (!currentAttempt()) return
      if (finish(record,view)) return
      if (!sameDraftTarget(view.draft.target,record.target)) throw new Error('공유 원고의 세대가 바뀌었습니다. 복구 내용을 다운로드해 주세요.')
      if (!session.acceptServerView(view)) return
      const input = record.value.input
      if (input.kind === 'comment') {
        const checked=restoreSharedDocument(draftBytes(input.source.state));checked.destroy()
      }
      const next: Composer = { id: crypto.randomUUID(), actor: record.actor, input, record: null, recoveredFrom: [record] }
      preserve(next)
      if (input.kind === 'comment') session.recover(draftBytes(input.source.state))
      tell('선택 시점의 원고와 입력을 복구했습니다. 확인한 뒤 보내 주세요.')
    } catch (error) {
      if (currentAttempt()) tell(error instanceof Error ? error.message : '입력을 복구하지 못했습니다.',true)
    }
    finally {
      if (busyRef.current.get(record.id) === flight) {
        busyRef.current.delete(record.id)
        reportPending()
        if (active.current) setBusy(new Set(busyRef.current.keys()))
      }
    }
  }
  const download = (record: DiscussionLocalRecord) => {
    const url=URL.createObjectURL(new Blob([JSON.stringify(record,null,2)],{type:'application/json;charset=utf-8'}))
    const anchor=document.createElement('a');anchor.href=url;anchor.download=`artifact-discussion-${record.id}.json`;anchor.click();URL.revokeObjectURL(url)
  }
  const ready = connected && actor !== null
  return html`<section aria-label="문장 댓글과 변경 제안" class="space-y-4 rounded border p-4">
    <div class="flex items-center justify-between gap-4"><h3 class="m-0">댓글과 변경 제안</h3>
      <button type="button" disabled=${!ready} onClick=${comment}>선택한 원문에 댓글</button></div>
    <p class="text-xs">문장을 선택한 뒤 댓글을 열어 주세요. 변경 제안은 검토 후 따로 반영합니다.</p>
    ${notice ? html`<p role=${notice.error ? 'alert' : 'status'}>${notice.text}</p>` : null}
    ${composer ? html`<form class="space-y-3 rounded border p-3" aria-label="댓글 작성" onSubmit=${(event:Event)=>{event.preventDefault();submit()}}>
      ${composer.input.kind === 'comment' ? html`<div><strong>선택한 원문</strong><pre class="whitespace-pre-wrap">${composer.input.source.mode === 'html_text' ? decodeHTML(composer.input.source.quote) : composer.input.source.quote}</pre></div>` : html`<p>답글 작성</p>`}
      <label class="block">댓글 내용<textarea aria-label="댓글 내용" class="block min-h-20 w-full border bg-[var(--color-bg-surface)] p-2" value=${composer.input.body}
        onInput=${(event:Event)=>edit(input=>({...input,body:(event.target as HTMLTextAreaElement).value}))} /></label>
      ${composer.input.kind === 'comment' ? html`<label class="block"><input type="checkbox" checked=${composer.input.proposing}
        onChange=${(event:Event)=>edit(input=>input.kind==='comment'?{...input,proposing:(event.target as HTMLInputElement).checked}:input)} /> 변경 제안 추가</label>
        ${composer.input.proposing ? html`<label class="block">${composer.input.source.mode==='html_text'?'제안할 문장':'제안할 원문'}
          <textarea aria-label="변경 제안 내용" class="block min-h-20 w-full border bg-[var(--color-bg-surface)] p-2" value=${composer.input.proposal}
            onInput=${(event:Event)=>edit(input=>input.kind==='comment'?{...input,proposal:(event.target as HTMLTextAreaElement).value}:input)} /></label><p class="text-xs">제안 내용을 비우면 선택한 부분의 삭제를 제안합니다.</p>` : null}` : null}
      ${composer.record && !composer.record.persisted ? html`<p role="alert">브라우저에 복구 내용을 저장하지 못했습니다. 탭을 닫기 전에 내용을 복사하거나 다운로드해 주세요.</p><button type="button" onClick=${()=>download(composer.record!)}>작성 내용 다운로드</button>` : null}
      <div class="flex gap-4"><button type="submit" disabled=${!ready || actor!==composer.actor || !composer.input.body.trim() || (state.pending&&composer.input.kind==='comment')}>댓글 보내기</button>
        <button type="button" onClick=${()=>{const current=composerRef.current;if(current&&meaningful(current.input)&&!window.confirm('작성 중인 댓글을 지울까요?'))return;if(current)discard([...(current.record?[current.record]:[]),...current.recoveredFrom]);updateComposer(null)}}>작성 취소</button></div>
    </form>` : null}
    ${records.filter(record=>record.revision!==composer?.record?.revision).map(record=>{
      const command=requestOf(record).command
      return html`<details key=${record.revision} class="rounded border p-3">
      <summary>${record.value.kind==='request'?'확인할 전송':'복구할 입력'} · ${new Date(record.at).toLocaleString()}</summary>
      <pre class="whitespace-pre-wrap">${record.value.kind==='input'?record.value.input.body:record.value.request.command.kind==='comment'||record.value.request.command.kind==='reply'?record.value.request.command.body:'댓글 처리 요청'}</pre>
      ${command.kind==='comment'&&command.proposal!==null&&command.proposal!==undefined?html`<p>변경 제안</p><pre class="whitespace-pre-wrap">${command.proposal}</pre>`:null}
      ${!record.persisted?html`<p role="alert">이 복구 내용은 현재 탭에만 남아 있습니다. 닫기 전에 다운로드해 주세요.</p>`:null}
      ${!sameDraftTarget(record.target,target)?html`<p>다른 세대의 원고입니다. 다운로드할 수만 있습니다.</p>`:null}
      <div class="flex flex-wrap gap-4"><button type="button" onClick=${()=>download(record)}>복구 내용 다운로드</button>
        ${record.value.kind==='input'?html`<p class="text-xs">복구하면 선택 시점의 미전송 원고를 합칩니다. 입력은 확인 후 보내 주세요.</p><button type="button" disabled=${!ready||actor!==record.actor||!sameDraftTarget(record.target,target)||busy.has(record.id)} onClick=${()=>{void recover(record)}}>원고와 댓글 입력 복구</button>`
        :html`<button type="button" disabled=${!ready||!sameDraftTarget(record.target,target)||busy.has(record.id)} onClick=${()=>{void run(record,false)}}>전송 결과 확인</button>
          <button type="button" disabled=${!ready||actor!==record.actor||!sameDraftTarget(record.target,target)||busy.has(record.id)} onClick=${()=>{void run(record,true)}}>같은 요청 다시 보내기</button>`}
        <button type="button" disabled=${busy.has(record.id)} onClick=${()=>{if(window.confirm('이 브라우저의 복구본을 지울까요?'))discard([record])}}>복구본 지우기</button>
      </div></details>`})}
    ${state.view.threads.length===0?html`<p>아직 댓글이 없습니다.</p>`:null}
    ${state.view.threads.map(thread=>{
      const status=sourceStatus(session,thread)
      const position=thread.decision.kind==='applied'?thread.decision.event.applied:thread.position
      return html`<article key=${thread.id} aria-label="댓글 묶음" class="space-y-3 rounded border p-3">
        <blockquote class="m-0 whitespace-pre-wrap border-l-2 pl-3">${thread.quote}</blockquote>
        ${status==='changed'?html`<p class="text-xs">댓글을 남긴 뒤 원문이 바뀌었습니다.</p>`:status==='missing'?html`<p class="text-xs">현재 원고에서 원문 위치를 찾지 못했습니다.</p>`:null}
        ${position?html`<button type="button" onClick=${()=>onReveal({anchor:[...position.anchor],head:[...position.head]})}>${thread.decision.kind==='applied'?'반영한 원문 보기':'원문 위치 보기'}</button>`:null}
        ${thread.messages.map(message=>html`<div key=${message.id}><p class="m-0 text-xs">${message.actor} · <time dateTime=${message.at}>${new Date(message.at).toLocaleString()}</time></p><p class="m-0 whitespace-pre-wrap">${message.body}</p></div>`)}
        ${thread.proposal!==null?html`<section aria-label="변경 제안"><strong>제안할 원문</strong><pre class="whitespace-pre-wrap">${thread.proposal===''?'선택한 부분 삭제':thread.proposal}</pre>
          ${thread.decision.kind==='pending'?html`<div class="flex gap-4"><button type="button" disabled=${!ready||state.pending||status!=='matching'} onClick=${()=>act({kind:'accept',thread_id:thread.id})}>제안 반영</button><button type="button" disabled=${!ready} onClick=${()=>act({kind:'reject',thread_id:thread.id})}>제안 거절</button></div>`
            :html`<p>${thread.decision.kind==='applied'?'반영됨':'거절됨'} · ${thread.decision.event.actor} · ${new Date(thread.decision.event.at).toLocaleString()}</p>`}</section>`:null}
        <div class="flex gap-4"><button type="button" disabled=${!ready} onClick=${()=>begin({kind:'reply',operationId:uuidV7(),threadId:thread.id,body:''})}>답글</button>
          <button type="button" disabled=${!ready} onClick=${()=>act({kind:thread.resolved?'reopen':'resolve',thread_id:thread.id})}>${thread.resolved?'대화 다시 열기':'대화 해결'}</button></div>
      </article>`
    })}
  </section>`
}
