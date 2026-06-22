// Demo page for keeper-v2 chat rich blocks.
// Loaded by public/keeper-blocks-demo.html. Renders a narrow ChatTranscript
// containing all four new block styles so the design can be reviewed/snapshot.

import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { ChatTranscript } from '../components/chat/primitives'
import type { KeeperConversationEntry } from '../types'

const assistantEntry: KeeperConversationEntry = {
  id: 'demo-1',
  role: 'assistant',
  source: 'direct_assistant',
  label: 'masc-improver',
  text: '요약 리포트를 fd-leak-fix.md 로 남겨두었습니다. PR 을 올릴까요?',
  rawText: '요약 리포트를 fd-leak-fix.md 로 남겨두었습니다. PR 을 올릴까요?',
  timestamp: '2026-06-22T01:00:00.000Z',
  delivery: 'delivered',
  streamState: null,
  details: null,
  error: null,
  blocks: [
    {
      t: 'chart',
      title: 'open_fds — drain 횟수에 따른 추이',
      series: [
        { label: '패치 전 (누수)', values: [42, 58, 72, 87] },
        { label: '패치 후 (안정)', values: [41, 42, 41, 41] },
      ],
      labels: ['1', '2', '3', '4'],
      xLabel: 'drain 횟수',
    },
    {
      t: 'artifact',
      kind: 'md',
      name: 'fd-leak-fix.md',
      size: '1.2 KB',
      note: 'PATCH',
      data: 'data:text/markdown;base64,IyBmbGVhayBmaXg=',
      mimeType: 'text/markdown',
    },
    {
      t: 'p',
      html: '참고로 같은 누수 패턴이 upstream 에도 보고돼 있어요 — Eio Switch 수명 관련 이슈입니다.',
    },
    {
      t: 'issue',
      repo: 'ocaml-multicore/eio',
      number: 388,
      title: 'Resource leak when forking into a parent Switch',
      status: 'open',
      url: 'https://github.com/ocaml-multicore/eio/issues/388',
      meta: 'github.com · Issue #388',
    },
    {
      t: 'suggestions',
      items: [
        { icon: '▸', label: 'PR #7763 열기', action: 'open-pr' },
        { icon: '✦', label: 'open_fds 패널 추가', action: 'add-panel' },
        { icon: '▸', label: 'compact 라이터에도 적용', action: 'apply-compact' },
      ],
    },
  ],
}

const userEntry: KeeperConversationEntry = {
  id: 'demo-2',
  role: 'user',
  source: 'direct_user',
  label: '사용자',
  text: '리포트 확인했어요. PR 을 올려주세요.',
  rawText: '리포트 확인했어요. PR 을 올려주세요.',
  timestamp: '2026-06-22T01:01:00.000Z',
  delivery: 'delivered',
  streamState: null,
  details: null,
  error: null,
}

function Demo() {
  return html`
    <div
      class="min-h-screen py-8"
      style="background: var(--bg-deep);"
      data-keeper-chat-layout="workspace"
    >
      <div class="mx-auto max-w-[700px] px-4">
        <h1
          class="mb-6 text-center font-mono text-xs uppercase tracking-[0.2em]"
          style="color: var(--text-dim);"
        >
          Keeper Chat Blocks Demo
        </h1>
        <div
          class="kw-chat rounded-[var(--r-2)] border p-4"
          style="background: var(--bg-panel); border-color: var(--border-main);"
        >
          <${ChatTranscript}
            entries=${[assistantEntry, userEntry]}
            emptyText="No messages"
            variant="default"
            size="primary"
            showMetadata=${false}
          />
        </div>
      </div>
    </div>
  `
}

const root = document.getElementById('app')
if (root) {
  render(html`<${Demo} />`, root)
}
