// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { CONNECTOR_SETUP_GUIDES } from "./connector-setup-guides"

describe("CONNECTOR_SETUP_GUIDES", () => {
  it("has expected keys", () => {
    expect(Object.keys(CONNECTOR_SETUP_GUIDES).sort()).toEqual([
      "discord",
      "imessage",
      "sandbox_hardened",
      "slack",
      "telegram",
    ])
  })

  it.each([
    ["discord", "Discord 봇 등록"],
    ["imessage", "iMessage 권한 (macOS only)"],
    ["slack", "Slack App + Socket Mode"],
    ["telegram", "Telegram BotFather"],
    ["sandbox_hardened", "Keeper Docker Sandbox 프리플라이트"],
  ])("%s has a title", (key, expectedTitle) => {
    expect(CONNECTOR_SETUP_GUIDES[key].title).toBe(expectedTitle)
  })

  it.each(Object.keys(CONNECTOR_SETUP_GUIDES))("%s has intro and steps", (key) => {
    const guide = CONNECTOR_SETUP_GUIDES[key]
    expect(guide.intro.length).toBeGreaterThan(0)
    expect(guide.steps.length).toBeGreaterThan(0)
    guide.steps.forEach((step) => {
      expect(step.text.length).toBeGreaterThan(0)
    })
  })

  it.each(Object.keys(CONNECTOR_SETUP_GUIDES))("%s has references", (key) => {
    const guide = CONNECTOR_SETUP_GUIDES[key]
    expect(guide.references.length).toBeGreaterThan(0)
    guide.references.forEach((ref) => {
      expect(ref.href).toMatch(/^https?:\/\//)
      expect(ref.label.length).toBeGreaterThan(0)
    })
  })

  it("discord steps include a link", () => {
    const linkedSteps = CONNECTOR_SETUP_GUIDES.discord.steps.filter((s) => s.link)
    expect(linkedSteps.length).toBeGreaterThanOrEqual(1)
    expect(linkedSteps[0].link!.href).toMatch(/^https/)
  })
})
