import { render } from 'preact'
import { html } from 'htm/preact'
import { normalizeKeepers } from '../src/keeper-store-normalize'
import { KeeperActivitySummary } from '../src/components/keeper-detail-activity-summary'
import { RawDataDebug } from '../src/components/keeper-detail-debug'
import '../src/styles/ds-theme-tokens.css'
import '../src/styles/primitives.css'
import '../src/styles/global.css'
import '../src/styles/tokens.css'
import '../src/styles/keeper-v2/colors_and_type.css'
import '../src/styles/keeper-v2/v2.css'
import '../src/styles/keeper-v2/surfaces.css'
import './fixture.css'

const raw = { name: 'audit-keeper', status: 'active', phase: 'idle', addressed_message_count: 1, conversation_tail_count: 6 }
const [keeper] = normalizeKeepers([raw])
if (!keeper) throw new Error('fixture keeper rejected')
render(html`<main data-audit-ready="true"><h1>멘션 활동</h1><p>격리 fixture · 실제 Dashboard 정규화와 컴포넌트 · 운영 데이터 아님</p><section><h2>활동 요약</h2><${KeeperActivitySummary} keeper=${keeper}/></section><section><h2>상태 상세</h2><${RawDataDebug} keeper=${keeper}/></section><footer>입력: 이력 6개, 명시적 주소가 있는 사용자 메시지 1개</footer></main>`, document.getElementById('app')!)
