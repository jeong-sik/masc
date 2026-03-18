// TRPG views — Screen tabs and view layouts

import { html } from 'htm/preact'
import { Card } from '../common/card'
import type { TrpgState, TrpgActor } from '../../types'
import { type TrpgScreen, setTrpgScreen } from './helpers'
import { ActorCard, StoryLog, AsciiMap, TimelinePanel, RoundHistory } from './sub-components'
import { ControlBox, ActorSpawnPanel, JoinGatePanel, ContributionLedger, NextAction, RoundRunInsight, ControlSafetyPanel } from './controls'

export function TrpgScreenTabs({ active }: { active: TrpgScreen }) {
  const tabs: Array<{ id: TrpgScreen; label: string; desc: string }> = [
    { id: 'overview', label: 'Overview', desc: '관전 요약' },
    { id: 'timeline', label: 'Timeline', desc: '이벤트 흐름' },
    { id: 'control', label: 'Control', desc: '운영/개입' },
  ]

  return html`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${tabs.map(tab => html`
        <button
          class="trpg-screen-tab ${active === tab.id ? 'active' : ''}"
          role="tab"
          aria-selected=${active === tab.id}
          onClick=${() => setTrpgScreen(tab.id)}
        >
          <span class="trpg-screen-tab-label">${tab.label}</span>
          <span class="trpg-screen-tab-desc">${tab.desc}</span>
        </button>
      `)}
    </div>
  `
}

export function OverviewView({ state }: { state: TrpgState }) {
  const party = state.party ?? []
  const events = state.story_log ?? []

  return html`
    <div class="trpg-layout">
      <div>
        <${Card} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${Card} title=${`최근 스토리 (${Math.min(events.length, 20)})`} style="margin-top:16px;">
          <${StoryLog} events=${events.slice(-20)} />
        <//>

        ${state.map
          ? html`
            <${Card} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${AsciiMap} mapStr=${state.map} />
            <//>
          `
          : null}
      </div>

      <div class="trpg-sidebar">
        <${Card} title="현재 라운드" semanticId="lab.trpg">
          <${NextAction} state=${state} />
        <//>

        <${Card} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${ContributionLedger} state=${state} />
        <//>

        <${Card} title=${`파티 (${party.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${party.map((a: TrpgActor) => html`<${ActorCard} key=${a.id ?? a.name} actor=${a} />`)}
            ${party.length === 0
              ? html`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`
              : null}
          </div>
        <//>

        ${state.history && state.history.length > 0
          ? html`
            <${Card} title=${`히스토리 (${state.history.length})`} style="margin-top:16px;">
              <${RoundHistory} state=${state} />
            <//>
          `
          : null}
      </div>
    </div>
  `
}

export function TimelineView({ state }: { state: TrpgState }) {
  const events = state.story_log ?? []

  return html`
    <div class="trpg-layout">
      <div>
        <${Card} title=${`이벤트 타임라인 (${events.length})`}>
          <${TimelinePanel} events=${events} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${Card} title="최근 라운드 결과" semanticId="lab.trpg">
          <${RoundRunInsight} />
        <//>

        <${Card} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${NextAction} state=${state} />
        <//>
      </div>
    </div>
  `
}

export function ControlView({ state, nowMs }: { state: TrpgState; nowMs: number }) {
  const party = state.party ?? []

  return html`
    <div>
      <${ControlSafetyPanel} state=${state} nowMs=${nowMs} />
      <div class="trpg-layout">
        <div>
          <${Card} title="조작 패널" semanticId="lab.trpg">
            <${ControlBox} state=${state} nowMs=${nowMs} />
          <//>

          <${Card} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${ActorSpawnPanel} state=${state} />
          <//>

          <${Card} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${JoinGatePanel} state=${state} nowMs=${nowMs} />
          <//>

          <${Card} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${RoundRunInsight} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${Card} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${ContributionLedger} state=${state} />
          <//>

          <${Card} title=${`파티 (${party.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${party.map((a: TrpgActor) => html`<${ActorCard} key=${a.id ?? a.name} actor=${a} />`)}
              ${party.length === 0
                ? html`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`
                : null}
            </div>
          <//>

          ${state.history && state.history.length > 0
            ? html`
              <${Card} title=${`히스토리 (${state.history.length})`} style="margin-top:16px;">
                <${RoundHistory} state=${state} />
              <//>
            `
            : null}
        </div>
      </div>
    </div>
  `
}
