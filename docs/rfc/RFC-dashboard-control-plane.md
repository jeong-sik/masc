# RFC: Dashboard Control Plane — 관찰에서 제어로

**Status**: Draft
**Date**: 2026-03-29
**Author**: Vincent + Claude
**Scope**: `dashboard/src/` (프론트엔드 전용, 백엔드 변경 없음)

---

## 1. 문제 정의

MASC 대시보드는 324개 MCP 도구 중 24개(7.4%)만 UI로 제공한다.
현재 대시보드는 **관찰 전용(Observatory)** 이고, **제어(Control)** 가 거의 없다.

운영자가 가장 기본적으로 해야 하는 행위들이 대시보드에서 불가능하다:

| 행위 | MCP 도구 | 대시보드 UI |
|------|----------|:-----------:|
| 키퍼 생성 | `keeper_up`, `keeper_create_from_persona` | 없음 |
| 키퍼 종료 | `keeper_down` | 없음 |
| 페르소나 조회 | `persona_list` | 없음 |
| 태스크 생성/클레임 | `add_task`, `claim_next` | 읽기만 |
| 룸 일시정지/재개 | `pause`, `resume`, `interrupt` | 없음 |
| 핸드오버 관리 | `handover_create/claim/list` | 없음 |
| 나머지 ~300개 도구 | 각각 존재 | 없음 |

## 2. 설계 원칙

1. **프론트엔드 전용** — OCaml 백엔드 변경 없음. 기존 MCP-over-HTTP 경로(`callMcpTool`)로 충분.
2. **기존 패턴 준수** — Preact + htm + signals + Tailwind. 새 라이브러리 추가 없음.
3. **제네릭 먼저, 전용 나중에** — JSON Schema 기반 범용 도구 실행기를 먼저 만들고, 자주 쓰는 것만 전용 UI로 승격.
4. **점진적 배포** — Phase별로 독립 PR. 기존 UI 깨뜨리지 않음.

## 3. 기술 스택 (기존 환경, 변경 없음)

| 항목 | 현재 | 비고 |
|------|------|------|
| Framework | Preact 10.25.4 + htm 3.1.1 | JSX 아님, template literal |
| State | @preact/signals 2.0.2 | 자동 구독, fine-grained |
| CSS | Tailwind v4.2.2 + CSS variables | FF14 navy/gold 테마 |
| Build | Vite 6.1.0 + pnpm 10.31.0 | `../assets/dashboard` 출력 |
| TypeScript | 5.7.3 strict mode | `noUncheckedIndexedAccess` |
| Test | Vitest 4.1.0 + testing-library/preact | happy-dom |
| API | MCP-over-HTTP (`/mcp` POST) | Session 기반, SSE 응답 |

### 라이브러리 추가 검토 결과: 없음

| 후보 | 검토 | 결론 |
|------|------|------|
| `@rjsf/core` (React JSON Schema Form) | React 의존, 42KB+, Preact 호환성 미보장 | 불채택 |
| `ajv` (JSON Schema validator) | 런타임 유효성 검증용 | 불채택 — required 필드 체크만 하면 충분. 자체 구현 ~20줄 |
| Select/Dropdown 라이브러리 | Headless UI 등 | 불채택 — native `<select>` + Tailwind으로 충분 |

**근거**: MCP 도구가 사용하는 JSON Schema 서브셋이 제한적이다 (string, integer, boolean, enum, array of strings, object). 범용 라이브러리의 기능 1%만 쓰게 되므로 자체 구현이 번들 크기와 유지보수 모두에서 유리.

## 4. 아키텍처

### 4.1 데이터 흐름

```
                  ┌─────────────────────────────┐
                  │  MCP Server (OCaml)          │
                  │  ┌───────────────────────┐   │
                  │  │ tools/list → schemas  │   │
                  │  │ tools/call → execute  │   │
                  │  └───────────────────────┘   │
                  └──────────┬──────────────────┘
                             │ MCP-over-HTTP
                             │ POST /mcp
                  ┌──────────▼──────────────────┐
                  │  Dashboard Frontend          │
                  │                              │
                  │  api/mcp.ts                  │
                  │  ├─ listMcpTools() ──NEW     │
                  │  └─ callMcpTool()  ──기존    │
                  │          │                   │
                  │  signals (tool-executor-     │
                  │          state.ts)           │
                  │          │                   │
                  │  SchemaForm → execute        │
                  └─────────────────────────────┘
```

### 4.2 새로운 MCP 호출: `listMcpTools()`

기존 `callMcpTool()`은 `tools/call` 메서드를 호출한다.
`tools/list` 메서드를 호출하면 `inputSchema`를 포함한 전체 스키마를 받을 수 있다.

```typescript
// api/mcp.ts — 추가
export async function listMcpTools(cursor?: string): Promise<ToolsListResponse> {
  await ensureSession()
  const text = await mcpPost({
    jsonrpc: '2.0',
    method: 'tools/list',
    params: cursor ? { cursor } : {},
    id: Date.now(),
  })
  const parsed = parseMcpHttpResponse(text)
  // tools/list는 result.tools[]와 result.nextCursor를 반환
  return parsed.result as ToolsListResponse
}

interface ToolsListResponse {
  tools: Array<{
    name: string
    description: string
    inputSchema: JsonSchema
    annotations?: Record<string, unknown>
  }>
  nextCursor?: string
}
```

**기존 `/api/v1/dashboard/tools` 엔드포인트와의 관계**:
- `/api/v1/dashboard/tools` — 인벤토리 메타데이터 (tier, surfaces, visibility). `inputSchema` 없음.
- MCP `tools/list` — 전체 스키마 포함 (`inputSchema` 있음). 폼 생성에 필요.
- 두 소스를 name 기준으로 조인하여 사용.

### 4.3 새 파일 구조

```
dashboard/src/
├── api/
│   └── mcp.ts                          # listMcpTools() 추가 (기존 파일)
│
├── components/
│   ├── common/
│   │   ├── select.ts                   # ★ NEW — native <select> wrapper
│   │   ├── checkbox.ts                 # ★ NEW — toggle/checkbox
│   │   └── number-input.ts             # ★ NEW — number input
│   │
│   ├── tool-executor/                  # ★ NEW — 제네릭 도구 실행기
│   │   ├── tool-executor.ts            # 메인 패널 (picker + form + result)
│   │   ├── tool-executor-state.ts      # signals: schemas, selected, result, loading
│   │   ├── tool-picker.ts              # 도구 검색/필터 목록
│   │   ├── schema-form.ts              # JSON Schema → Preact 폼 렌더러
│   │   ├── schema-field.ts             # 개별 필드 렌더 (type별 분기)
│   │   ├── tool-result-display.ts      # 실행 결과 표시 (JSON 뷰어)
│   │   └── tool-executor.test.ts       # 테스트
│   │
│   ├── keeper-spawn/                   # ★ NEW — 키퍼 생성 전용 UI
│   │   ├── keeper-spawn-panel.ts       # 페르소나 선택 → 키퍼 생성 플로우
│   │   ├── persona-browser.ts          # 페르소나 카드 목록
│   │   ├── keeper-spawn-state.ts       # signals
│   │   └── keeper-spawn.test.ts
│   │
│   ├── task-manage/                    # ★ NEW — 태스크 생성/클레임
│   │   ├── task-create-form.ts         # 태스크 생성 폼
│   │   ├── task-actions.ts             # 클레임, 우선순위 변경
│   │   ├── task-manage-state.ts        # signals
│   │   └── task-manage.test.ts
│   │
│   └── flow-control/                   # ★ NEW — 룸 흐름 제어
│       ├── flow-control-panel.ts       # pause/resume/interrupt 버튼
│       ├── flow-control-state.ts       # signals
│       └── flow-control.test.ts
│
├── types/
│   └── json-schema.ts                  # ★ NEW — JSON Schema 타입 정의
│
└── styles/
    └── (기존 CSS 파일에 추가, 새 파일 불필요 — Tailwind으로 충분)
```

**총 신규 파일: ~20개** (테스트 포함)
**기존 파일 수정: ~5개** (api/mcp.ts, navigation.ts, 각 surface의 라우팅)

## 5. 상세 설계

### 5.1 Phase 1: JSON Schema 폼 렌더러 + 제네릭 도구 실행기

가장 높은 레버리지. 이것 하나로 324개 도구 전부 접근 가능.

#### 5.1.1 JSON Schema 타입 정의

```typescript
// types/json-schema.ts
export interface JsonSchema {
  type: 'object' | 'string' | 'integer' | 'number' | 'boolean' | 'array'
  properties?: Record<string, JsonSchemaProperty>
  required?: string[]
  description?: string
}

export interface JsonSchemaProperty {
  type: 'string' | 'integer' | 'number' | 'boolean' | 'array' | 'object'
  description?: string
  enum?: string[]
  default?: unknown
  items?: JsonSchemaProperty
  properties?: Record<string, JsonSchemaProperty>
  required?: string[]
}
```

#### 5.1.2 SchemaField — 타입별 필드 렌더링

JSON Schema property type → UI 컴포넌트 매핑:

| JSON Schema type | `enum` 여부 | UI 컴포넌트 | 비고 |
|-----------------|:-----------:|------------|------|
| `string` | 없음 | `TextInput` | 기존 컴포넌트 |
| `string` | 있음 | `Select` (NEW) | native `<select>` |
| `string` (긴 텍스트) | — | `TextArea` | description에 "body"/"content" 포함 시 |
| `integer` / `number` | — | `NumberInput` (NEW) | `<input type="number">` |
| `boolean` | — | `Checkbox` (NEW) | styled checkbox |
| `array` (items: string) | — | `TextArea` | 줄바꿈으로 분리, 제출 시 배열로 변환 |
| `object` (nested) | — | 재귀 `SchemaForm` | 접히는 섹션 |

```typescript
// components/tool-executor/schema-field.ts
import { html } from 'htm/preact'
import { TextInput, TextArea } from '../common/input'
import { Select } from '../common/select'
import { NumberInput } from '../common/number-input'
import { Checkbox } from '../common/checkbox'
import type { JsonSchemaProperty } from '../../types/json-schema'

interface SchemaFieldProps {
  name: string
  schema: JsonSchemaProperty
  value: unknown
  required: boolean
  onChange: (name: string, value: unknown) => void
}

export function SchemaField({ name, schema, value, required, onChange }: SchemaFieldProps) {
  const label = schema.description ?? name
  const requiredMark = required
    ? html`<span class="text-[var(--bad)] ml-0.5">*</span>`
    : null

  // string + enum → Select
  if (schema.type === 'string' && schema.enum) {
    return html`
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-[var(--text-muted)]">${name}${requiredMark}</label>
        <${Select}
          value=${value ?? ''}
          options=${schema.enum}
          placeholder=${label}
          onInput=${(v: string) => onChange(name, v)}
        />
      </div>
    `
  }

  // string → TextInput or TextArea
  if (schema.type === 'string') {
    const isLong = /body|content|description|message|text|reason/i.test(name)
    const Component = isLong ? TextArea : TextInput
    return html`
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-[var(--text-muted)]">${name}${requiredMark}</label>
        <${Component}
          value=${value ?? schema.default ?? ''}
          placeholder=${label}
          onInput=${(e: Event) => onChange(name, (e.target as HTMLInputElement).value)}
        />
      </div>
    `
  }

  // integer / number → NumberInput
  if (schema.type === 'integer' || schema.type === 'number') {
    return html`
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-[var(--text-muted)]">${name}${requiredMark}</label>
        <${NumberInput}
          value=${value ?? schema.default ?? ''}
          placeholder=${label}
          step=${schema.type === 'integer' ? 1 : 'any'}
          onInput=${(v: number) => onChange(name, v)}
        />
      </div>
    `
  }

  // boolean → Checkbox
  if (schema.type === 'boolean') {
    return html`
      <div class="flex items-center gap-2">
        <${Checkbox}
          checked=${value ?? schema.default ?? false}
          onChange=${(v: boolean) => onChange(name, v)}
        />
        <label class="text-[11px] text-[var(--text-body)]">${name}${requiredMark}</label>
        ${schema.description
          ? html`<span class="text-[10px] text-[var(--text-muted)]">— ${schema.description}</span>`
          : null}
      </div>
    `
  }

  // array of strings → TextArea (newline-separated)
  if (schema.type === 'array' && schema.items?.type === 'string') {
    const strValue = Array.isArray(value) ? (value as string[]).join('\n') : ''
    return html`
      <div class="flex flex-col gap-1">
        <label class="text-[11px] text-[var(--text-muted)]">${name}${requiredMark}
          <span class="text-[10px]"> (줄바꿈으로 구분)</span>
        </label>
        <${TextArea}
          value=${strValue}
          placeholder=${label}
          rows=${3}
          onInput=${(e: Event) => {
            const lines = (e.target as HTMLTextAreaElement).value
              .split('\n')
              .filter(Boolean)
            onChange(name, lines)
          }}
        />
      </div>
    `
  }

  // fallback: raw JSON editor
  return html`
    <div class="flex flex-col gap-1">
      <label class="text-[11px] text-[var(--text-muted)]">${name}${requiredMark}
        <span class="text-[10px]"> (JSON)</span>
      </label>
      <${TextArea}
        value=${typeof value === 'string' ? value : JSON.stringify(value ?? '', null, 2)}
        placeholder=${label}
        rows=${4}
        onInput=${(e: Event) => {
          try {
            onChange(name, JSON.parse((e.target as HTMLTextAreaElement).value))
          } catch { /* 사용자가 입력 중일 수 있음 */ }
        }}
      />
    </div>
  `
}
```

#### 5.1.3 SchemaForm — 폼 전체 렌더러

```typescript
// components/tool-executor/schema-form.ts
import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { JsonSchema } from '../../types/json-schema'
import { SchemaField } from './schema-field'

interface SchemaFormProps {
  schema: JsonSchema
  values: Record<string, unknown>
  onChange: (values: Record<string, unknown>) => void
}

export function SchemaForm({ schema, values, onChange }: SchemaFormProps) {
  if (!schema.properties) {
    return html`<p class="text-[var(--text-muted)] text-[12px]">이 도구는 파라미터가 없습니다.</p>`
  }

  const required = new Set(schema.required ?? [])
  const entries = Object.entries(schema.properties)

  // required 필드를 먼저, optional은 나중에
  const sorted = [
    ...entries.filter(([k]) => required.has(k)),
    ...entries.filter(([k]) => !required.has(k)),
  ]

  const handleFieldChange = (name: string, value: unknown) => {
    onChange({ ...values, [name]: value })
  }

  return html`
    <div class="flex flex-col gap-3">
      ${sorted.map(([name, prop]) => html`
        <${SchemaField}
          key=${name}
          name=${name}
          schema=${prop}
          value=${values[name]}
          required=${required.has(name)}
          onChange=${handleFieldChange}
        />
      `)}
    </div>
  `
}
```

#### 5.1.4 ToolExecutor — 메인 패널

```typescript
// components/tool-executor/tool-executor-state.ts
import { signal, computed } from '@preact/signals'

interface ToolSchema {
  name: string
  description: string
  inputSchema: JsonSchema
  tier?: string
  annotations?: Record<string, unknown>
}

// --- Signals ---
export const allToolSchemas = signal<ToolSchema[]>([])
export const schemasLoading = signal(false)
export const schemasError = signal<string | null>(null)

export const searchQuery = signal('')
export const selectedTool = signal<ToolSchema | null>(null)
export const formValues = signal<Record<string, unknown>>({})

export const executing = signal(false)
export const lastResult = signal<{ success: boolean; text: string; durationMs?: number } | null>(null)
export const executeError = signal<string | null>(null)

// --- Computed ---
export const filteredTools = computed(() => {
  const q = searchQuery.value.toLowerCase()
  if (!q) return allToolSchemas.value
  return allToolSchemas.value.filter(
    t => t.name.toLowerCase().includes(q) || t.description.toLowerCase().includes(q)
  )
})

// --- Actions ---
export function selectTool(tool: ToolSchema) {
  selectedTool.value = tool
  formValues.value = buildDefaults(tool.inputSchema)
  lastResult.value = null
  executeError.value = null
}

function buildDefaults(schema: JsonSchema): Record<string, unknown> {
  const defaults: Record<string, unknown> = {}
  if (!schema.properties) return defaults
  for (const [name, prop] of Object.entries(schema.properties)) {
    if (prop.default !== undefined) {
      defaults[name] = prop.default
    }
  }
  return defaults
}
```

```
// components/tool-executor/tool-executor.ts (개념적 구조)

레이아웃:
┌─────────────────────────────────────────────────┐
│ 🔍 도구 검색 [________________]                   │
├──────────────────┬──────────────────────────────┤
│  도구 목록        │  도구 상세                     │
│  (스크롤)         │  이름 + 설명                   │
│                  │  ─────────                    │
│  ● masc_status   │  파라미터 폼                   │
│    masc_join     │  [SchemaForm]                 │
│    masc_add_task │                              │
│    ...           │  [실행] [초기화]               │
│                  │  ─────────                    │
│                  │  결과                         │
│                  │  [ToolResultDisplay]          │
└──────────────────┴──────────────────────────────┘
```

**핵심 동작**:
1. 마운트 시 `listMcpTools()`로 전체 스키마 로드 → `allToolSchemas` signal
2. 검색/필터 → `filteredTools` computed
3. 도구 선택 → `selectedTool` + `formValues` 초기화 (defaults 적용)
4. 폼 입력 → `formValues` 업데이트
5. 실행 → `callMcpTool(name, values)` → `lastResult` 업데이트
6. 결과 표시 → JSON 뷰어 + 성공/실패 배지

**유효성 검증**:
- 제출 시 `required` 필드 비어있으면 해당 필드 하이라이트 + 제출 차단
- 복잡한 JSON Schema 유효성 검증은 하지 않음 (서버가 거부하면 에러 표시)

#### 5.1.5 ToolResultDisplay

```typescript
// 결과 표시 컴포넌트
// - JSON 응답이면 코드블록으로 표시 (monospace, 접기/펼치기)
// - 텍스트면 그대로 표시
// - 성공/실패 배지 (CountBadge tone=ok/bad)
// - 실행 시간 표시
// - 복사 버튼
```

#### 5.1.6 배치 위치

**Lab → 도구 섹션**에 "도구 실행기" 탭 추가.
기존 "도구 인벤토리"와 나란히 위치.

```typescript
// navigation.ts 수정
// lab의 tools 섹션 내부에서 토글:
// - "인벤토리 보기" (기존)
// - "도구 실행기" (신규) ← ActionButton으로 전환
```

### 5.2 Phase 2: 키퍼 생성 + 페르소나 브라우저

제네릭 실행기로도 되지만, 키퍼 생성은 빈도가 높으므로 전용 UI.

#### 5.2.1 PersonaBrowser

```
┌────────────────────────────────────────────┐
│ 페르소나 목록                                │
├────────────────────────────────────────────┤
│ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│ │  상수     │ │  승지     │ │  재용     │   │
│ │  40대 남자 │ │ Executor │ │ Chairman │   │
│ │  🎬 영화  │ │  ⚡ AI   │ │  💼 경영  │   │
│ │ [키퍼 시작]│ │ [키퍼 시작]│ │ [키퍼 시작]│   │
│ └──────────┘ └──────────┘ └──────────┘   │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐   │
│ │  미선     │ │  보위     │ │  게리     │   │
│ │  Data Ex  │ │  Voice   │ │ Musician │   │
│ │  📊 데이터 │ │  🎙 음성  │ │  🎵 음악  │   │
│ │ [키퍼 시작]│ │ [키퍼 시작]│ │ [키퍼 시작]│   │
│ └──────────┘ └──────────┘ └──────────┘   │
└────────────────────────────────────────────┘
```

**데이터 흐름**:
1. `callMcpTool('masc_persona_list', {})` → 페르소나 목록
2. 카드 렌더링 (이름, 역할, 모드)
3. "키퍼 시작" 클릭 → 확인 다이얼로그 (dry_run 옵션) → `callMcpTool('masc_keeper_create_from_persona', { persona_name, dry_run: false })`
4. 성공 시 toast + 키퍼 목록 갱신

#### 5.2.2 KeeperSpawnPanel

Monitoring → 에이전트 & 키퍼 섹션에 추가.

```
기존 키퍼 목록 상단에:
┌────────────────────────────────────────────┐
│ [+ 키퍼 생성]  [페르소나에서 생성]           │
└────────────────────────────────────────────┘
```

- **"+ 키퍼 생성"** → 확장되어 직접 인자 입력 폼 (SchemaForm 재사용, `masc_keeper_up` 스키마)
- **"페르소나에서 생성"** → PersonaBrowser 오버레이/모달

#### 5.2.3 KeeperDown 추가

기존 `KeeperRuntimeActions`에 "종료" 버튼 추가.
```typescript
// keeper-shared.ts 내 KeeperRuntimeActions에 추가
// variant="danger"인 ActionButton
// 확인 다이얼로그 후 callMcpTool('masc_keeper_down', { name: keeperName })
```

### 5.3 Phase 3: 태스크 관리

Workspace → 작업 게시판 섹션에 추가.

#### 5.3.1 TaskCreateForm

기존 태스크 목록 상단에 "태스크 추가" 버튼.
클릭 시 확장:

```
┌────────────────────────────────────────────┐
│ 새 태스크                                   │
│ 제목: [__________________________________] │
│ 설명: [__________________________________] │
│       [__________________________________] │
│ 우선순위: [보통 ▼]                          │
│ [생성]  [취소]                              │
└────────────────────────────────────────────┘
```

→ `callMcpTool('masc_add_task', { title, description, priority })`

#### 5.3.2 TaskActions

기존 태스크 행에 액션 버튼 추가:
- **클레임** → `callMcpTool('masc_claim_next', { task_id })`
- **우선순위 변경** → `callMcpTool('masc_update_priority', { task_id, priority })`

### 5.4 Phase 4: 흐름 제어

Command → 실시간 개입 섹션에 추가.

```
┌────────────────────────────────────────────┐
│ 흐름 제어                                   │
│                                            │
│ [⏸ 일시정지]  [▶ 재개]  [⚡ 인터럽트]       │
│                                            │
│ 상태: ● 실행 중                             │
│ 마지막 변경: 3분 전                          │
└────────────────────────────────────────────┘
```

- `masc_pause` / `masc_resume` / `masc_interrupt`
- `masc_pause_status`로 현재 상태 표시
- 인터럽트는 `variant="danger"` + 확인 다이얼로그

## 6. 공통 컴포넌트 (신규)

### 6.1 Select

```typescript
// components/common/select.ts
// native <select> + Tailwind 스타일링
// props: value, options (string[] | {value, label}[]), placeholder, onInput, disabled
// 스타일: INPUT_BASE와 동일한 border/bg/focus 패턴
```

### 6.2 NumberInput

```typescript
// components/common/number-input.ts
// <input type="number"> + TextInput과 동일한 스타일
// props: value, placeholder, step, min, max, onInput, disabled
```

### 6.3 Checkbox

```typescript
// components/common/checkbox.ts
// styled checkbox with accent color
// props: checked, onChange, disabled, label
// 스타일: 16x16, rounded, accent border, checkmark
```

## 7. 기존 파일 수정 목록

| 파일 | 변경 내용 | 영향 범위 |
|------|----------|----------|
| `api/mcp.ts` | `listMcpTools()` 함수 추가 | 기존 함수 변경 없음 |
| `config/navigation.ts` | Lab 섹션에 도구 실행기 관련 설명 업데이트 (선택적) | 기존 라우팅 변경 없음 |
| `components/tools/tools-main.ts` | "도구 실행기" 토글 추가 | 기존 인벤토리 뷰 유지 |
| `components/keeper-shared.ts` | KeeperRuntimeActions에 종료 버튼 | 기존 버튼 옆에 추가 |
| `styles/global.css` | select/checkbox 기본 스타일 (Tailwind으로 충분하면 불필요) | 최소 |

## 8. 구현 순서 & PR 전략

| Phase | 내용 | 예상 파일 수 | PR |
|-------|------|:-----------:|:--:|
| **1a** | `Select`, `NumberInput`, `Checkbox` 공통 컴포넌트 | 3+3 (테스트) | PR #1 |
| **1b** | `listMcpTools()` + JSON Schema 타입 + SchemaField/SchemaForm | 5+2 | PR #2 |
| **1c** | ToolExecutor 메인 패널 (Lab 통합) | 4+1 | PR #3 |
| **2** | PersonaBrowser + KeeperSpawnPanel + KeeperDown | 5+2 | PR #4 |
| **3** | TaskCreateForm + TaskActions | 4+1 | PR #5 |
| **4** | FlowControlPanel | 3+1 | PR #6 |

각 PR은 독립적으로 머지 가능. Phase 1c 이후 바로 324개 도구에 접근 가능.

## 9. 테스트 전략

| 레벨 | 대상 | 도구 |
|------|------|------|
| Unit | SchemaField (타입별 렌더링) | vitest + testing-library |
| Unit | SchemaForm (required 검증, defaults) | vitest + testing-library |
| Unit | formValues → args 변환 (빈 optional 제거) | vitest |
| Integration | ToolExecutor (mock callMcpTool) | vitest + testing-library |
| Manual | 실제 MCP 서버에서 도구 실행 | dev server |

**SchemaField 테스트 케이스**:
- string → TextInput 렌더
- string + enum → Select 렌더, 옵션 목록 일치
- boolean → Checkbox 렌더, 토글 동작
- integer → NumberInput 렌더, step=1
- array of strings → TextArea 렌더, 줄바꿈→배열 변환
- required 필드에 `*` 표시

**SchemaForm 테스트 케이스**:
- required 필드 먼저 정렬
- defaults 적용
- onChange 콜백에 올바른 값 전달

## 10. 위험 요소 & 완화

| 위험 | 확률 | 영향 | 완화 |
|------|------|------|------|
| `tools/list`가 inputSchema를 포함하지 않는 변형이 있을 수 있음 | Low | High | Phase 1b에서 먼저 확인. fallback으로 빈 폼 + JSON 직접 입력 |
| 일부 도구의 inputSchema가 복잡한 nested object | Medium | Low | 재귀 렌더링 1단계만 지원, 그 이상은 JSON 편집기 fallback |
| 도구 수가 많아 목록 렌더링 성능 | Low | Low | virtualized list 또는 페이지네이션 (MCP cursor 활용) |
| destructive 도구 실수 실행 | Medium | High | annotations.destructiveHint 확인 → 확인 다이얼로그 강제 |

## 11. 향후 확장 (이 RFC 범위 밖)

- 도구 즐겨찾기 (localStorage)
- 최근 실행 이력 (localStorage)
- 도구 실행 결과를 보드에 공유
- 배치 실행 (여러 도구 순차 실행)
- Operation/Session 시작 전용 위저드

---

## 변경 이력

| 날짜 | 변경 |
|------|------|
| 2026-03-29 | 초안 작성 |
