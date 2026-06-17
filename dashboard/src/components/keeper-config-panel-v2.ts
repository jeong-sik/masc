// MASC Dashboard — Keeper config panel v2 (organisms-5 port)
// Local-state-only config drawer. No backend wiring.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { ComponentChildren, JSX } from 'preact'
import { ActionButton } from './common/button'

type CSSProperties = JSX.CSSProperties

interface KeeperIdentity {
  id?: string
  ns?: string
  model?: string
  runtime?: string
}

interface KeeperBase {
  persona?: string
  instructions?: string
  traits?: string[]
}

interface InheritRow {
  tag: string
  txt: string
}

export interface KeeperConfigPanelProps {
  keeper?: KeeperIdentity
  base?: KeeperBase
  inherit?: InheritRow[]
  models?: string[]
  runtimes?: string[]
  permissions?: Record<string, boolean>
  asOverlay?: boolean
  onClose?: () => void
  onPromptsLink?: () => void
  style?: CSSProperties
}

function Section({ title, children }: { title: string; children: ComponentChildren }) {
  return html`
    <div class="kcp-section">
      <h4 class="kcp-section-title">${title}</h4>
      ${children}
    </div>
  `
}

function KvRows({ rows = [] }: { rows?: { k: string; v?: string }[] }) {
  return html`
    <div class="kcp-codectx">
      ${rows.map((r, i) => html`
        <div key=${i} class="kcp-cc-row">
          <span class="kcp-cc-k">${r.k}</span>
          <span class="kcp-cc-v mono">${r.v ?? ''}</span>
        </div>
      `)}
    </div>
  `
}

function InheritRows({ rows = [], note }: { rows?: InheritRow[]; note?: ComponentChildren }) {
  return html`
    <div class="kcp-inherit">
      ${rows.map((r, i) => html`
        <div key=${i} class="kcp-inh-row">
          <span class="kcp-inh-tag">${r.tag}</span>
          <span class="kcp-inh-txt mono">${r.txt}</span>
        </div>
      `)}
      ${note ? html`<div class="kcp-inh-note">${note}</div>` : null}
    </div>
  `
}

function TraitPill({ children }: { children: ComponentChildren }) {
  return html`<span class="kcp-trait">${children}</span>`
}

function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return html`
    <button
      type="button"
      class=${`kcp-toggle ${on ? 'on' : ''}`}
      role="switch"
      aria-checked=${on}
      data-testid="kcp-toggle"
      onClick=${() => onChange(!on)}
    >
      <span class="kcp-toggle-knob"></span>
    </button>
  `
}

function Segmented({
  options,
  value,
  onChange,
}: {
  options: string[]
  value: string
  onChange: (v: string) => void
}) {
  return html`
    <div class="kcp-seg" data-testid="kcp-seg">
      ${options.map(o => html`
        <button
          type="button"
          key=${o}
          class=${`kcp-seg-b ${value === o ? 'on' : ''}`}
          data-active=${value === o ? 'true' : 'false'}
          onClick=${() => onChange(o)}
        >
          ${o}
        </button>
      `)}
    </div>
  `
}

const DEFAULT_MODELS = ['claude-haiku-4', 'claude-sonnet-4', 'claude-opus-4']
const DEFAULT_RUNTIMES = ['oas·seoul-1', 'oas·tokyo-2', 'local·docker']
const DEFAULT_PERMISSIONS = {
  '읽기': true,
  '쓰기': true,
  'git': false,
  '외부 호출': false,
}

export function KeeperConfigPanel({
  keeper = {},
  base = {},
  inherit = [],
  models = DEFAULT_MODELS,
  runtimes = DEFAULT_RUNTIMES,
  permissions = DEFAULT_PERMISSIONS,
  asOverlay = false,
  onClose,
  onPromptsLink,
  style,
}: KeeperConfigPanelProps) {
  const [persona, setPersona] = useState(base.persona ?? '')
  const [instr, setInstr] = useState(base.instructions ?? '')
  const [model, setModel] = useState(keeper.model ?? models[1] ?? '')
  const [rt, setRt] = useState(keeper.runtime ?? runtimes[0] ?? '')
  const [perm, setPerm] = useState(permissions)

  const drawer = html`
    <div
      class="kcp-drawer"
      onClick=${(e: Event) => e.stopPropagation()}
      style=${asOverlay ? style : { position: 'static', width: '100%', height: '100%', boxShadow: 'none', borderRadius: 0, ...style }}
      data-testid="keeper-config-panel"
    >
      <div class="kcp-hd">
        <h3 class="kcp-hd-title">keeper 설정</h3>
        <span class="kcp-hd-id mono">${keeper.id}</span>
        ${onClose
          ? html`
            <button
              type="button"
              class="kcp-close"
              data-testid="kcp-close"
              onClick=${onClose}
              title="닫기 (Esc)"
            >
              ✕
            </button>
          `
          : null}
      </div>

      <div class="kcp-body">
        <${Section} title="정체성 · 배정">
          <div class="kcp-note">
            아래는 배정·파생된 사실 — 여기서 바꾸지 않습니다. worktree는 keeper가 basepath 아래에 자동 생성·관리합니다.
          </div>
          <${KvRows} rows=${[
            { k: 'namespace', v: keeper.ns },
            { k: 'repo · branch', v: `masc-mcp · keeper/${keeper.id}` },
          ]} />
        <//>

        <${Section} title="상속 — 공유 베이스 (read-only)">
          <${InheritRows}
            rows=${inherit}
            note=${html`
              <span>전 keeper 공유 · </span>
              <button type="button" class="kcp-link" onClick=${onPromptsLink}>
                operator 설정 · Keeper 기본 · 프롬프트 →
              </button>
            `}
          />
        <//>

        <${Section} title="③ 성격 (persona) — 이 keeper">
          <textarea
            class="kcp-textarea"
            rows=${2}
            value=${persona}
            data-testid="kcp-persona"
            onInput=${(e: Event) => setPersona((e.target as HTMLTextAreaElement).value)}
          />
          <div class="kcp-traits">
            ${(base.traits ?? []).map((t, i) => html`<${TraitPill} key=${i}>${t}<//>`)}
          </div>
        <//>

        <${Section} title="④ 지침 (instructions) — 이 keeper">
          <textarea
            class="kcp-textarea"
            rows=${5}
            value=${instr}
            data-testid="kcp-instructions"
            onInput=${(e: Event) => setInstr((e.target as HTMLTextAreaElement).value)}
          />
        <//>

        <${Section} title="모델">
          <${Segmented} options=${models} value=${model} onChange=${setModel} />
        <//>

        <${Section} title="기본 런타임">
          <${Segmented} options=${runtimes} value=${rt} onChange=${setRt} />
        <//>

        <${Section} title="도구 권한">
          ${Object.keys(perm).map(k => html`
            <div key=${k} class="kcp-perm-row">
              <span class="kcp-perm-label">${k}</span>
              <${Toggle}
                on=${perm[k] ?? false}
                onChange=${(v: boolean) => setPerm(p => ({ ...p, [k]: v }))}
              />
            </div>
          `)}
        <//>

        <${ActionButton} variant="primary" block testId="kcp-save">
          저장 · 재시작 없이 적용
        <//>
      </div>
    </div>
  `

  if (asOverlay) {
    return html`
      <div class="kcp-overlay" onClick=${onClose} data-testid="kcp-overlay">
        ${drawer}
      </div>
    `
  }

  return drawer
}
