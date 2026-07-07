import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'

const css = readFileSync(resolve(__dirname, 'keeper-workspace.css'), 'utf-8')
const chatCss = readFileSync(resolve(__dirname, 'chat.css'), 'utf-8')
const copilotCss = readFileSync(resolve(__dirname, 'copilot-dock.css'), 'utf-8')
const turnInspectorCss = readFileSync(resolve(__dirname, 'keeper-turn-inspector.css'), 'utf-8')
const configCss = readFileSync(resolve(__dirname, 'keeper-v2/keeper-config.css'), 'utf-8')
const keeperV2CraftCss = readFileSync(resolve(__dirname, 'keeper-v2/craft.css'), 'utf-8')
const opsClusterCss = readFileSync(resolve(__dirname, 'keeper-v2/ops-cluster.css'), 'utf-8')
const appSource = readFileSync(resolve(__dirname, '../app.ts'), 'utf-8')
const chatPrimitivesSource = readFileSync(resolve(__dirname, '../components/chat/primitives.ts'), 'utf-8')
const copilotDockSource = readFileSync(resolve(__dirname, '../components/copilot-dock.ts'), 'utf-8')
const keeperTurnInspectorSource = readFileSync(resolve(__dirname, '../components/keeper-turn-inspector.ts'), 'utf-8')
const keeperSharedSource = readFileSync(resolve(__dirname, '../components/keeper-shared.ts'), 'utf-8')
const keeperWorkspaceChatSource = readFileSync(
  resolve(__dirname, '../components/keeper-workspace/keeper-workspace-chat.ts'),
  'utf-8',
)
const keeperWorkspaceRosterSource = readFileSync(
  resolve(__dirname, '../components/keeper-workspace/keeper-workspace-roster.ts'),
  'utf-8',
)
const keeperWorkspaceRailSource = readFileSync(
  resolve(__dirname, '../components/keeper-workspace/keeper-workspace-rail.ts'),
  'utf-8',
)
const keeperDetailPageSource = readFileSync(resolve(__dirname, '../components/keeper-detail-page.ts'), 'utf-8')
const keeperDetailBodySource = readFileSync(resolve(__dirname, '../components/keeper-detail-body.ts'), 'utf-8')
const keeperDetailShellSource = readFileSync(resolve(__dirname, '../components/keeper-detail-shell.ts'), 'utf-8')
const keeperConfigPanelSource = readFileSync(resolve(__dirname, '../components/keeper-config-panel.ts'), 'utf-8')
const htmlSource = readFileSync(resolve(__dirname, '../../index.html'), 'utf-8')
const implementationSources = [
  css,
  chatCss,
  copilotCss,
  turnInspectorCss,
  configCss,
  appSource,
  chatPrimitivesSource,
  copilotDockSource,
  keeperTurnInspectorSource,
  keeperSharedSource,
  keeperWorkspaceChatSource,
  keeperWorkspaceRosterSource,
  keeperWorkspaceRailSource,
  keeperDetailPageSource,
  keeperDetailBodySource,
  keeperDetailShellSource,
  keeperConfigPanelSource,
  htmlSource,
].join('\n')

const SHELL_MOBILE_CHROME_BREAKPOINT = '900px'
const SHELL_TABLET_EDGE_BREAKPOINT = '1120px'
const KEEPER_MOBILE_PANE_BREAKPOINT = '860px'
const PHONE_NARROW_BREAKPOINT = '420px'

function baseRuleDeclsIn(source: string, selector: string): Record<string, string> {
  const declarations: Record<string, string> = {}

  parse(source).walkRules((rule) => {
    if (rule.parent?.type === 'atrule') return
    if (!rule.selectors.includes(selector)) return
    rule.walkDecls((decl) => {
      declarations[decl.prop] = decl.value.trim()
    })
  })

  return declarations
}

const baseRuleDecls = (selector: string) => baseRuleDeclsIn(css, selector)
const baseTurnInspectorRuleDecls = (selector: string) => baseRuleDeclsIn(turnInspectorCss, selector)

function mediaRuleDeclsIn(source: string, selector: string, maxWidth: string): Record<string, string> {
  const declarations: Record<string, string> = {}

  parse(source).walkAtRules('media', (atRule) => {
    if (!atRule.params.includes(`max-width: ${maxWidth}`)) return
    atRule.walkRules((rule) => {
      if (!rule.selectors.includes(selector)) return
      rule.walkDecls((decl) => {
        declarations[decl.prop] = decl.value.trim()
      })
    })
  })

  return declarations
}

const mediaRuleDecls = (selector: string, maxWidth: string) => mediaRuleDeclsIn(css, selector, maxWidth)
const mobileRuleDecls = (selector: string) => mediaRuleDecls(selector, KEEPER_MOBILE_PANE_BREAKPOINT)
const copilotRuleDecls = (selector: string, maxWidth: string) => mediaRuleDeclsIn(copilotCss, selector, maxWidth)
const opsClusterBaseRuleDecls = (selector: string) => baseRuleDeclsIn(opsClusterCss, selector)
const opsClusterRuleDecls = (selector: string, maxWidth: string) => mediaRuleDeclsIn(opsClusterCss, selector, maxWidth)
const keeperV2CraftMobileRuleDecls = (selector: string) =>
  mediaRuleDeclsIn(keeperV2CraftCss, selector, KEEPER_MOBILE_PANE_BREAKPOINT)
const shellMobileTurnInspectorRuleDecls = (selector: string) =>
  mediaRuleDeclsIn(turnInspectorCss, selector, SHELL_MOBILE_CHROME_BREAKPOINT)

describe('keeper workspace v2 (26) mobile contract', () => {
  it('keeps the phone viewport compatible with safe-area layout', () => {
    expect(htmlSource).toContain('name="viewport"')
    expect(htmlSource).toContain('width=device-width, initial-scale=1, viewport-fit=cover')
  })

  it('exposes the mobile keeper reading-mode state from the app shell', () => {
    expect(appSource).toContain("import { keeperMobilePane } from './components/keeper-detail-state'")
    expect(appSource).toContain("const mobileKeeperReadingMode = mobileKeeperPane === 'chat'")
    expect(appSource).toContain('data-reading=${mobileKeeperReadingMode ?')
  })

  it('routes the conversation width tweak to the keeper workspace CSS variable', () => {
    expect(appSource).toContain("'--kw-thread-w': `${tweaksThreadW.value}px`")
    expect(baseRuleDecls('.kw-thread-inner')['max-width']).toBe('var(--kw-thread-w, 980px)')
    expect(baseRuleDecls('.kw-composer-inner')['max-width']).toBe('var(--kw-thread-w, 980px)')
  })

  it('suppresses mobile shell chrome in keeper chat reading mode', () => {
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .v2-mobile-bottom-bar', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .v2-nav.is-mnav', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .v2-health-strip', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] > .v2-shell-panel', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-keeper-detail-mode="true"] .v2-top-ops', SHELL_MOBILE_CHROME_BREAKPOINT)
        .display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-keeper-detail-mode="true"] .v2-top > .v2-shell-panel', SHELL_MOBILE_CHROME_BREAKPOINT)
        .display,
    ).toBe('none')
    expect(
      mediaRuleDecls(
        '.v2-app[data-keeper-detail-mode="true"] .v2-top > [data-testid="tweaks-panel-toggle"]',
        SHELL_MOBILE_CHROME_BREAKPOINT,
      ).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .dashboard-status-tray', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .dashboard-focus-mode-toggle', SHELL_MOBILE_CHROME_BREAKPOINT)
        .display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .topbar-copilot', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
    expect(
      mediaRuleDecls('.v2-app[data-reading="true"] .kw-chat-actions', SHELL_MOBILE_CHROME_BREAKPOINT).display,
    ).toBe('none')
  })

  it('keeps the mobile topbar copilot button compact like the v2 phone shell', () => {
    expect(copilotDockSource).toContain('topbar-copilot')
    expect(copilotDockSource).toContain('class="spark"')
    expect(copilotDockSource).toContain('<span>Chat</span>')
    expect(copilotDockSource).toContain('<kbd>⌘J</kbd>')
    expect(copilotRuleDecls('.topbar-copilot kbd', SHELL_MOBILE_CHROME_BREAKPOINT).display).toBe('none')
    expect(copilotRuleDecls('.topbar-copilot span:not(.spark)', PHONE_NARROW_BREAKPOINT).display).toBe('none')
  })

  it('keeps remounted operational topbar chrome out of mobile and keeper tablet edges', () => {
    expect(opsClusterBaseRuleDecls('.v2-top-ops > .emergency-stop-control')['white-space']).toBe('nowrap')
    expect(opsClusterBaseRuleDecls('.v2-top-ops > .emergency-stop-control')['min-height']).toBe('28px')
    expect(opsClusterBaseRuleDecls('.v2-top-ops > .emergency-stop-control > span')['white-space'])
      .toBe('nowrap')

    expect(opsClusterRuleDecls('.v2-app[data-mobile="1"] .v2-top-ops', SHELL_MOBILE_CHROME_BREAKPOINT).display)
      .toBe('none')
    expect(
      opsClusterRuleDecls('.v2-app[data-mobile="1"] .v2-top > .v2-shell-panel', SHELL_MOBILE_CHROME_BREAKPOINT)
        .display,
    ).toBe('none')
    expect(
      opsClusterRuleDecls(
        '.v2-app[data-mobile="1"] .v2-top > [data-testid="tweaks-panel-toggle"]',
        SHELL_MOBILE_CHROME_BREAKPOINT,
      ).display,
    ).toBe('none')
    expect(
      opsClusterRuleDecls(
        '.v2-app[data-keeper-detail-mode="true"] .v2-top-ops',
        SHELL_TABLET_EDGE_BREAKPOINT,
      ).display,
    ).toBe('none')
    expect(
      opsClusterRuleDecls(
        '.v2-app[data-keeper-detail-mode="true"] .v2-top > .v2-shell-panel',
        SHELL_TABLET_EDGE_BREAKPOINT,
      ).display,
    ).toBe('none')
    expect(
      opsClusterRuleDecls(
        '.v2-app[data-keeper-detail-mode="true"] .v2-top > [data-testid="tweaks-panel-toggle"]',
        SHELL_TABLET_EDGE_BREAKPOINT,
      ).display,
    ).toBe('none')
  })

  it('uses dynamic viewport height for the focused keeper mobile surface and context drawer', () => {
    const appDecls = mobileRuleDecls('.v2-app[data-keeper-detail-mode="true"]')
    expect(appDecls.height).toBe('100dvh')
    expect(appDecls['min-height']).toBe('100dvh')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer').height).toBe('100dvh')
  })

  it('keeps safe-area padding on the mobile keeper chat shell', () => {
    expect(mobileRuleDecls('[data-keeper-detail-mode="true"] .v2-shell-stage').padding).toContain(
      'env(safe-area-inset-bottom, 0px)',
    )
    expect(mobileRuleDecls('.kw-chat-head').padding).toContain('max(9px, env(safe-area-inset-top, 0px))')
    expect(mobileRuleDecls('.kw-chat-head').padding).toContain('max(12px, env(safe-area-inset-right, 0px))')
    expect(mobileRuleDecls('.kw-chat-head').gap).toBe('10px')
    expect(mobileRuleDecls('.kw-chat-head').padding).toContain('max(12px, env(safe-area-inset-left, 0px))')
    expect(mobileRuleDecls('.kw-chat-name')['font-size']).toBe('17px')
    expect(mobileRuleDecls('.kw-thread-inner .chat-transcript').gap).toBe('18px')
    expect(mobileRuleDecls('.kw-thread-inner .chat-transcript')['padding-top']).toBe('16px')
    expect(mobileRuleDecls('.kw-composer-wrap')['padding-bottom']).toBe(
      'max(14px, env(safe-area-inset-bottom, 0px))',
    )
    expect(mobileRuleDecls('.kw-composer-inner')['padding-left']).toBe(
      'max(12px, env(safe-area-inset-left, 0px))',
    )
    expect(mobileRuleDecls('.kw-composer-inner')['padding-right']).toBe(
      'max(12px, env(safe-area-inset-right, 0px))',
    )
    expect(mobileRuleDecls('.kw-composer-inner .composer textarea')['font-size']).toBe('var(--fs-16)')
  })

  it('uses full-width mobile chat columns instead of desktop reading-width insets', () => {
    expect(mobileRuleDecls('.kw-chat-body > [data-keeper-chat-layout="workspace"]').width).toBe('100%')
    expect(mobileRuleDecls('.kw-chat-body > [data-keeper-chat-layout="workspace"]')['max-width']).toBe('100%')
    expect(mobileRuleDecls('.kw-chat-body > [data-keeper-chat-layout="workspace"]')['min-width']).toBe('0')

    expect(mobileRuleDecls('.v2-app[data-keeper-detail-mode="true"] .kw-rail-toggle').display).toBe('none')
    expect(mobileRuleDecls('.v2-app[data-keeper-detail-mode="true"] .kw-pane-resizer').display).toBe('none')

    expect(mobileRuleDecls('.kw-chat-toolbar').padding).toContain('max(12px, env(safe-area-inset-right, 0px))')
    expect(mobileRuleDecls('.kw-chat-toolbar').padding).toContain('max(12px, env(safe-area-inset-left, 0px))')
    expect(mobileRuleDecls('.kw-chat-toolbar').gap).toBe('8px')
    expect(mobileRuleDecls('.kw-chat-toolbar [name="keeper_chat_search"]').flex).toBe('1 1 180px')
    expect(mobileRuleDecls('.kw-chat-toolbar [name="keeper_chat_search"]')['max-width']).toBe('none')

    expect(mobileRuleDecls('[data-keeper-chat-layout="workspace"] .kw-thread-inner').width).toBe('100%')
    expect(mobileRuleDecls('[data-keeper-chat-layout="workspace"] .kw-thread-inner')['max-width']).toBe('none')
    expect(mobileRuleDecls('[data-keeper-chat-layout="workspace"] .kw-composer-inner').width).toBe('100%')
    expect(mobileRuleDecls('[data-keeper-chat-layout="workspace"] .kw-composer-inner')['max-width']).toBe('none')
    expect(mobileRuleDecls('[data-keeper-chat-layout="workspace"] .composer-inner').width).toBe('100%')
    expect(mobileRuleDecls('[data-keeper-chat-layout="workspace"] .composer-box').width).toBe('100%')
  })

  it('overrides the last-loaded v2 craft density gutters for mobile keeper chat', () => {
    const scope = '.v2-app[data-keeper-detail-mode="true"] [data-keeper-chat-layout="workspace"]'

    expect(keeperV2CraftMobileRuleDecls(`${scope} .chat-transcript`).padding).toContain(
      'max(16px, env(safe-area-inset-left, 0px))',
    )
    expect(keeperV2CraftMobileRuleDecls(`${scope} .chat-turn-bundle`).width).toBe('100%')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .chat-turn-bundle`)['max-width']).toBe('100%')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .chat-bubble`).width).toBe('100%')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .chat-bubble`)['max-width']).toBe('100%')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .chat-bubble`).padding).toBe('14px 15px')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .kw-composer-wrap`).padding).toContain(
      'max(12px, env(safe-area-inset-left, 0px))',
    )
    expect(keeperV2CraftMobileRuleDecls(`${scope} .kw-composer-inner`).padding).toBe('0')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .composer.primary`).padding).toBe('0')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .composer-inner`).padding).toBe('0')
    expect(keeperV2CraftMobileRuleDecls(`${scope} .composer-box`).width).toBe('100%')
  })

  it('keeps mobile conversation bubbles at the v2 reading scale', () => {
    expect(mobileRuleDecls('.kw-thread-inner .chat-turn-bundle').width).toBe('100%')
    expect(mobileRuleDecls('.kw-thread-inner .chat-turn-bundle')['max-width']).toBe('100%')
    expect(mobileRuleDecls('.kw-thread-inner .chat-bubble').width).toBe('100%')
    expect(mobileRuleDecls('.kw-thread-inner .chat-bubble')['max-width']).toBe('100%')
    expect(mobileRuleDecls('.kw-thread-inner .chat-bubble')['font-size']).toBe('16.5px')
    expect(mobileRuleDecls('.kw-thread-inner .chat-bubble')['line-height']).toBe('1.68')
    expect(mobileRuleDecls('.kw-thread-inner .chat-bubble').padding).toBe('14px 15px')
    expect(mobileRuleDecls('.kw-thread-inner .chat-bubble code')['font-size']).toBe('13.5px')
  })

  it('keeps composer slash commands wired to real workspace actions', () => {
    expect(chatPrimitivesSource).toContain('export interface ChatComposerCommand')
    expect(chatPrimitivesSource).toContain('class="slashmenu"')
    expect(chatCss).toContain('.slashmenu')
    expect(keeperSharedSource).toContain('composerCommands?: ChatComposerCommand[]')
    expect(keeperSharedSource).toContain('commands=${composerCommands}')
    expect(keeperWorkspaceChatSource).toContain('...lifecycleCommands(keeper)')
    expect(keeperWorkspaceChatSource).toContain('runKeeperAction(keeper.name, key)')
    expect(keeperWorkspaceChatSource).toContain('composerCommands=${composerCommands}')
    expect(mobileRuleDecls('.kw-composer-inner .slashmenu')['max-height']).toBe('min(46vh, 320px)')
    expect(mobileRuleDecls('.kw-composer-inner .slashmenu')['left']).toContain('env(safe-area-inset-left, 0px)')
  })

  it('keeps the turn inspector drawer phone-fullscreen from the runtime inspector', () => {
    expect(keeperTurnInspectorSource).toContain('data-testid="turn-detail-drawer"')
    expect(keeperTurnInspectorSource).toContain('class="kti-overlay"')
    expect(keeperTurnInspectorSource).toContain('class="kti-drawer"')
    expect(baseTurnInspectorRuleDecls('.kti-head h3').flex).toBe('none')
    expect(baseTurnInspectorRuleDecls('.kti-head .tid').overflow).toBe('hidden')
    expect(baseTurnInspectorRuleDecls('.kti-head .tid')['text-overflow']).toBe('ellipsis')
    expect(baseTurnInspectorRuleDecls('.kti-close').width).toBe('26px')
    expect(baseTurnInspectorRuleDecls('.kti-close').height).toBe('26px')
    expect(baseTurnInspectorRuleDecls('.kti-stat').padding).toBe('11px 14px')
    expect(baseTurnInspectorRuleDecls('.kti-stat .k')['font-size']).toBe('8.5px')
    expect(baseTurnInspectorRuleDecls('.kti-stat .v')['margin-top']).toBe('5px')
    expect(baseTurnInspectorRuleDecls('.kti-stat .v small')['font-size']).toBe('var(--fs-10)')
    expect(baseTurnInspectorRuleDecls('.kti-sub').padding).toBe('0 var(--sp-4) 12px')
    expect(baseTurnInspectorRuleDecls('.kti-chip')['font-size']).toBe('10.5px')
    expect(baseTurnInspectorRuleDecls('.kti-chip').padding).toBe('3px 9px')
    expect(baseTurnInspectorRuleDecls('.kti-chip .sub-k').margin).toBe('0')
    expect(baseTurnInspectorRuleDecls('.kti-chip .sub-k')['text-transform']).toBeUndefined()
    expect(baseTurnInspectorRuleDecls('.kti-tok').padding).toBe('13px var(--sp-4)')
    expect(baseTurnInspectorRuleDecls('.kti-tok-top .lbl')['font-size']).toBe('9.5px')
    expect(baseTurnInspectorRuleDecls('.kti-tok-top .ctxpct')['font-size']).toBe('var(--fs-11)')
    expect(baseTurnInspectorRuleDecls('.kti-tok-legend').gap).toBe('18px')
    expect(baseTurnInspectorRuleDecls('.kti-tok-legend')['margin-top']).toBe('9px')
    expect(baseTurnInspectorRuleDecls('.kti-tok-legend')['font-size']).toBe('11.5px')
    expect(baseTurnInspectorRuleDecls('.kti-tok-legend b')['font-weight']).toBe('600')
    expect(baseTurnInspectorRuleDecls('.kti-wf-row').gap).toBe('12px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-lbl')['font-size']).toBe('12.5px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-lbl').color).toBe('var(--color-fg-primary)')
    expect(baseTurnInspectorRuleDecls('.kti-wf-lbl .nm.mono')['font-size']).toBe('11.5px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-dur')['font-size']).toBe('var(--fs-11)')
    expect(baseTurnInspectorRuleDecls('.kti-wf-foot')['margin-top']).toBe('12px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-foot')['padding-top']).toBe('11px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-foot')['font-size']).toBe('11.5px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-foot b')['font-weight']).toBe('600')
    expect(baseTurnInspectorRuleDecls('.kti-wf-legend').gap).toBe('14px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-legend span').gap).toBe('5px')
    expect(baseTurnInspectorRuleDecls('.kti-wf-legend span')['font-size']).toBe('10.5px')
    expect(baseTurnInspectorRuleDecls('.kti-copy').gap).toBe('5px')
    expect(baseTurnInspectorRuleDecls('.kti-copy')['font-size']).toBe('var(--fs-10)')
    expect(baseTurnInspectorRuleDecls('.kti-copy').padding).toBe('3px 9px')
    expect(baseTurnInspectorRuleDecls('.kti-code-h .cap')['font-size']).toBe('9.5px')
    expect(baseTurnInspectorRuleDecls('.kti-code-h .sz')['font-size']).toBe('9.5px')
    expect(baseTurnInspectorRuleDecls('.kti-code pre')['font-size']).toBe('11.5px')
    expect(baseTurnInspectorRuleDecls('.kti-code pre')['line-height']).toBe('1.62')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h').gap).toBe('9px')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h').padding).toBe('9px 12px')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h .seq')['font-size']).toBe('9.5px')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h .tnm')['font-size']).toBe('12.5px')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h .pill')['font-size']).toBe('var(--fs-9)')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h .pill').padding).toBe('2px 7px')
    expect(baseTurnInspectorRuleDecls('.kti-tool-h .lat')['font-size']).toBe('var(--fs-11)')
    expect(baseTurnInspectorRuleDecls('.kti-msg-h').padding).toBe('7px 11px')
    expect(baseTurnInspectorRuleDecls('.kti-msg-role')['font-size']).toBe('9.5px')
    expect(baseTurnInspectorRuleDecls('.kti-msg-h .who')['font-size']).toBe('10.5px')
    expect(baseTurnInspectorRuleDecls('.kti-msg-h .seq')['font-size']).toBe('9.5px')
    expect(baseTurnInspectorRuleDecls('.kti-msg-b')['font-size']).toBe('12.5px')
    expect(baseTurnInspectorRuleDecls('.kti-msg-b')['line-height']).toBe('1.62')
    expect(baseTurnInspectorRuleDecls('.kti-msg-b').color).toBe('var(--color-fg-primary)')
    expect(baseTurnInspectorRuleDecls('.kti-msg-b.mono')['font-size']).toBe('11.5px')
    expect(baseTurnInspectorRuleDecls('.kti-ctx-h .t')['font-size']).toBe('var(--fs-10)')
    expect(baseTurnInspectorRuleDecls('.kti-ctx-h .tok')['font-size']).toBe('var(--fs-10)')
    expect(baseTurnInspectorRuleDecls('.kti-ctx-card pre').padding).toBe('11px 13px')
    expect(baseTurnInspectorRuleDecls('.kti-ctx-card pre')['font-size']).toBe('11.5px')
    expect(baseTurnInspectorRuleDecls('.kti-ctx-card pre')['line-height']).toBe('1.62')
    expect(baseTurnInspectorRuleDecls('.kti-params').gap).toBe('7px')
    expect(baseTurnInspectorRuleDecls('.kti-param')['font-size']).toBe('var(--fs-11)')
    expect(baseTurnInspectorRuleDecls('.kti-param').padding).toBe('4px 11px')
    expect(baseTurnInspectorRuleDecls('.kti-param b')['font-weight']).toBe('600')
    expect(baseTurnInspectorRuleDecls('.kti-sec-h').gap).toBe('10px')
    expect(baseTurnInspectorRuleDecls('.kti-sec-h').margin).toBe('0 0 9px')
    expect(baseTurnInspectorRuleDecls('.kti-sec-h .n')['font-size']).toBe('var(--fs-10)')
    expect(shellMobileTurnInspectorRuleDecls('.kti-drawer').width).toBe('100vw')
    expect(shellMobileTurnInspectorRuleDecls('.kti-drawer')['max-width']).toBe('100vw')
    expect(shellMobileTurnInspectorRuleDecls('.kti-drawer').height).toBe('100dvh')
    expect(shellMobileTurnInspectorRuleDecls('.kti-drawer')['border-left']).toBe('0')
    expect(shellMobileTurnInspectorRuleDecls('.kti-head')['padding-top']).toContain(
      'env(safe-area-inset-top, 0px)',
    )
    expect(shellMobileTurnInspectorRuleDecls('.kti-head')['padding-left']).toContain(
      'env(safe-area-inset-left, 0px)',
    )
    expect(shellMobileTurnInspectorRuleDecls('.kti-head')['padding-right']).toContain(
      'env(safe-area-inset-right, 0px)',
    )
    expect(shellMobileTurnInspectorRuleDecls('.kti-sub')['padding-left']).toContain(
      'env(safe-area-inset-left, 0px)',
    )
    expect(shellMobileTurnInspectorRuleDecls('.kti-sub')['padding-right']).toContain(
      'env(safe-area-inset-right, 0px)',
    )
    expect(shellMobileTurnInspectorRuleDecls('.kti-tok')['padding-left']).toContain(
      'env(safe-area-inset-left, 0px)',
    )
    expect(shellMobileTurnInspectorRuleDecls('.kti-tok')['padding-right']).toContain(
      'env(safe-area-inset-right, 0px)',
    )
  })

  it('keeps the voice composer presentation backed by the shared voice hook', () => {
    expect(chatPrimitivesSource).toContain('const voice = useVoiceInput({')
    expect(chatPrimitivesSource).toContain('voice.state === \'recording\' || voice.state === \'transcribing\'')
    expect(chatPrimitivesSource).toContain('class=${`rec-bar ${voice.state === \'transcribing\' ? \'transcribing\' : \'\'}`}')
    expect(chatPrimitivesSource).toContain('VOICE_WAVE_BARS')
    expect(chatPrimitivesSource).toContain('onClick=${voice.stop}')
    expect(chatCss).toContain('.rec-bar.transcribing')
    expect(chatCss).toContain('.rec-bar.transcribing .rec-lbl')
    expect(chatCss).toContain('.rec-btn.stop:hover:not(:disabled)')
    expect(chatCss).toContain('@keyframes recwave')
  })

  it('keeps fleet roster pressure and tone indicators backed by live keeper fields', () => {
    expect(keeperWorkspaceRosterSource).toContain('data-tone=${tone}')
    expect(keeperWorkspaceRosterSource).toContain('keeper.context_ratio')
    expect(keeperWorkspaceRosterSource).toContain('keeper.latest_tool_names')
    expect(keeperWorkspaceRosterSource).toContain('keeper.recent_tool_names')
    expect(keeperWorkspaceRosterSource).toContain('keeper.latest_tool_call_count')
    expect(keeperWorkspaceRosterSource).toContain('class="kw-kp-context"')
    expect(keeperWorkspaceRosterSource).toContain('class="kw-kp-tool"')
    expect(keeperWorkspaceRosterSource).toContain('const ROSTER_ROW_ESTIMATED_HEIGHT = 92')
    expect(keeperWorkspaceRosterSource).toContain('estimatedItemHeight=${ROSTER_ROW_ESTIMATED_HEIGHT}')
    expect(css).toContain('.kw-kp-row::before')
    expect(css).toContain('.kw-kp-context-bar')
    expect(css).toContain('.kw-kp-context-val.hot')
    expect(css).toContain('.kw-kp-tool-v')
    expect(mobileRuleDecls('.kw-kp-menu')['max-height']).toBe('min(70dvh, 420px)')
    expect(mobileRuleDecls('.kw-kp-menu')['max-width']).toContain('env(safe-area-inset-right, 0px)')
  })

  it('hides the roster ⋮ action until hover/focus on desktop, keeps it for touch', () => {
    // v2 mock (.kp-more) is opacity:0 at rest and reveals on row hover/focus, so
    // the card reads as identity + status. The 860px block restores it for touch
    // where hover is unavailable.
    expect(baseRuleDecls('.kw-kp-more').opacity).toBe('0')
    expect(baseRuleDecls('.kw-kp-row:hover .kw-kp-more').opacity).toBe('1')
    expect(mobileRuleDecls('.kw-kp-more').opacity).toBe('1')
  })

  it('keeps the mobile context drawer close to the v2 rail without prototype-local state', () => {
    expect(keeperWorkspaceRailSource).toContain('keeper.context_ratio')
    expect(keeperWorkspaceRailSource).toContain('tasks.value.filter')
    expect(keeperWorkspaceRailSource).toContain('callMcpTool(\'masc_keeper_compact\'')
    expect(mobileRuleDecls('.kw-mobile-rail-overlay').background).toBe('rgb(4 5 8 / 0.60)')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer').width).toBe('min(330px, 88vw)')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer')['max-width']).toContain('env(safe-area-inset-left, 0px)')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer')['box-shadow']).toBe('-8px 0 30px rgb(0 0 0 / 0.50)')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer .kw-rail-scroll').gap).toBe('12px')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer .kw-card').padding).toBe('11px 12px')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer .kw-sec h4')['font-size']).toBe('var(--fs-11)')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer .kw-vital').padding).toBe('9px 11px')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer .kw-tasktag').padding).toBe('8px 10px')
    expect(mobileRuleDecls('.kw-mobile-rail-drawer .kw-detail-btn')['min-height']).toBe('44px')
  })

  it('keeps keeper detail and config surfaces phone-fullscreen without replacing runtime owners', () => {
    expect(keeperDetailPageSource).toContain('kw-detail-content')
    expect(keeperDetailPageSource).toContain('kw-detail-full-head')
    expect(keeperDetailPageSource).toContain("await import('./keeper-config-panel')")
    expect(keeperDetailPageSource).toContain('<${LazyKeeperConfigPanel} key=${keeperName} keeperName=${keeperName} onClose=${onClose} />')
    expect(keeperDetailPageSource).toContain('panel now owns the full .kcf-overlay modal shell')
    expect(keeperDetailBodySource).toContain('kw-detail-body')
    expect(keeperDetailShellSource).toContain('kw-detail-section-rail')
    expect(keeperDetailShellSource).toContain('kw-detail-section-tab')

    expect(keeperConfigPanelSource).toContain('class="kcf-overlay"')
    expect(keeperConfigPanelSource).toContain('class="kcf v2-monitoring-surface"')
    expect(keeperConfigPanelSource).toContain('class="kcf-tabs"')
    expect(keeperConfigPanelSource).toContain('class="kcf-main v2-monitoring-panel"')
    expect(keeperConfigPanelSource).toContain('class="kcf-foot v2-monitoring-toolbar"')
    expect(keeperConfigPanelSource).toContain('class="set-row"')
    expect(keeperConfigPanelSource).toContain('class=${`set-toggle ${on ? \'on\' : \'\'}`}')
    expect(keeperConfigPanelSource).not.toContain('kw-config-fact')
    expect(keeperConfigPanelSource).not.toContain('kw-config-set-row')
    expect(css).not.toContain('.kw-config-scroll .kw-config-fact')
    expect(configCss).toContain('.kcf-overlay')
    expect(configCss).toContain('.kcf-top')
    expect(configCss).toContain('.kcf-tabs')
    expect(configCss).toContain('.kcf-main')
    expect(configCss).toContain('.kcf-facts')
    expect(configCss).toContain('.set-row')
    expect(configCss).toContain('.set-toggle')

    expect(mobileRuleDecls('.kw-grid[data-detail="open"] .kw-detail').height).toBe('100%')
    expect(mobileRuleDecls('.kw-grid[data-detail="open"] .kw-detail-scroll').background).toBe('var(--color-bg-page)')
    expect(mobileRuleDecls('.kw-detail-content')['max-width']).toBe('none')
    expect(mobileRuleDecls('.kw-detail-full-head').position).toBe('sticky')
    expect(mobileRuleDecls('.kw-detail-body').display).toBe('grid')
    expect(mobileRuleDecls('.kw-detail-body')['grid-template-columns']).toBe('56px minmax(0, 1fr)')
    expect(mobileRuleDecls('.kw-detail-section-rail').height).toContain('100dvh')
    expect(mobileRuleDecls('.kw-detail-section-tabs')['flex-direction']).toBe('column')
    expect(mobileRuleDecls('.kw-detail-section-tab').display).toBe('inline-flex')
    expect(mobileRuleDecls('.kw-detail-section-tab')['align-items']).toBe('center')
    expect(mobileRuleDecls('.kw-detail-section-tab').width).toBe('100%')
  })

  it('does not introduce local path defaults or frontend env access for visual parity', () => {
    expect(implementationSources).not.toContain('/Users/dancer/me')
    expect(implementationSources).not.toContain('/Users/dancer/Downloads')
    expect(implementationSources).not.toContain('default_base')
    expect(implementationSources).not.toContain('process.env')
    expect(implementationSources).not.toContain('import.meta.env')
  })
})
