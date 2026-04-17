# Dashboard CSS Architecture

## Overview

The MASC Dashboard CSS has been refactored from a single 2199-line `global.css` file into a modular architecture using Tailwind v4's `@theme` and `@utility` directives.

## File Structure

### Foundation Files (Load Order)

1. **tokens.css** (51 lines)
   - Tailwind v4 `@theme` design tokens
   - Colors, typography scale, spacing, radii
   - Used by Tailwind's utility classes

2. **variables.css** (156 lines)
   - CSS custom properties (`:root`)
   - Legacy variable names for backward compatibility
   - Opacity variants, color utilities, z-index layers

3. **base.css** (40 lines)
   - Base HTML element styles
   - `html`, `body`, `#app` foundations
   - Global typography (links)

4. **keyframes.css** (114 lines)
   - All `@keyframes` animation definitions
   - Avatar animations, state transitions, component effects

5. **global.css** (1844 lines)
   - Reusable `@utility` blocks
   - Component-specific styles
   - Raw CSS for pseudo-elements and state selectors

### Component-Specific Files

- `ui.css` - Base UI components
- `agent-monitor.css` - Agent monitoring views
- `board.css` - Board/posts interface
- `chat.css` - Chat interface
- `command-swarm.css` - Command swarm UI
- `dashboard.css` - Dashboard layouts
- `governance.css` - Governance interfaces
- `governance-agent.css` - Agent governance
- `governance-keeper.css` - Keeper governance
- `ops.css` - Operations tab
- `roster.css` - Roster views
- `tools.css` - Tool interfaces

## Import Order (main.ts)

```typescript
// Foundation styles (load first)
import './styles/tokens.css'
import './styles/variables.css'
import './styles/base.css'
import './styles/keyframes.css'

// Global utilities and layout
import './styles/global.css'

// Component-specific styles (alphabetically)
import './styles/[component].css'
```

## Design Patterns

### @utility Directive

Reusable utility classes are defined using Tailwind v4's `@utility` directive:

```css
@utility card {
  background: var(--card);
  border: 1px solid var(--card-border);
  border-radius: 12px;
  padding: 14px;
  &:hover { border-color: var(--border-slate-22); }
}
```

### Raw CSS Selectors

Some patterns require raw CSS and cannot be converted to utilities:

1. **Pseudo-elements** - `::before`, `::after`, `::marker`
2. **Attribute selectors** - `[open]`, `[data-*]`
3. **Complex compound selectors** - `.parent > .child`, `.class.modifier`
4. **Descendant selectors** - `.parent .child`

These are intentionally kept as raw CSS in their respective section files.

## Benefits

1. **Modularity** - Logical separation of concerns
2. **Maintainability** - Easier to locate and update specific styles
3. **Performance** - Better tree-shaking and caching
4. **Standards** - Uses Tailwind v4 best practices
5. **Documentation** - Clear section headers and comments

## Line Count Comparison

- **Before**: 2199 lines (single file)
- **After**:
  - Foundation: 361 lines (4 files)
  - Global: 1844 lines
  - Components: 832 lines (13 files)
  - **Total**: 3037 lines

The increase reflects better organization with headers, comments, and logical separation.

## Related

- Issue #3915 - CSS refactoring
- Issue #3912 - Duplicate CSS removal (predecessor)
- Tailwind v4 documentation: https://tailwindcss.com/docs/v4-beta
