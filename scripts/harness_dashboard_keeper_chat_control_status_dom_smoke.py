import os

from playwright.sync_api import Page, sync_playwright


FIXTURE_URL = os.environ["FIXTURE_URL"]
DESKTOP_SCREENSHOT = os.environ["DESKTOP_SCREENSHOT"]
MOBILE_SCREENSHOT = os.environ["MOBILE_SCREENSHOT"]
FIXTURE_SELECTOR = (
    '[data-control-status-fixture-status="ok"]'
    '[data-fake-assistant-prose-count="0"]'
    '[data-control-status-count="1"]'
)
STATUS_SELECTOR = '[data-chat-control-status="external_effect_pending"]'


def verify(page: Page, screenshot: str) -> None:
    page.goto(FIXTURE_URL, wait_until="networkidle", timeout=20_000)
    page.wait_for_selector(FIXTURE_SELECTOR, timeout=15_000)
    status = page.locator(STATUS_SELECTOR)
    if status.count() != 1:
        raise RuntimeError(f"expected one control status, got {status.count()}")

    body_text = page.locator("body").inner_text()
    forbidden = (
        "No textual reply was produced",
        "Tools invoked:",
        "External effect is awaiting Gate approval",
    )
    for text in forbidden:
        if text in body_text:
            raise RuntimeError(f"internal fallback prose leaked into fixture: {text}")

    if "승인 대기" not in status.inner_text():
        raise RuntimeError("typed status did not render the user-facing label")
    if (
        page.locator('[data-chat-entry-id="assistant-gate-wait"].chat-bubble').count()
        != 0
    ):
        raise RuntimeError("control state rendered as an assistant speech bubble")

    status.get_by_role("button", name="승인 화면 열기").click()
    page.wait_for_function(
        "() => location.hash.includes('command') && location.hash.includes('view=gate')",
        timeout=5_000,
    )
    page.screenshot(path=screenshot, full_page=True)


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    errors: list[str] = []

    desktop_context = browser.new_context(viewport={"width": 1440, "height": 900})
    desktop = desktop_context.new_page()
    desktop.on(
        "console",
        lambda message: (
            errors.append(message.text) if message.type == "error" else None
        ),
    )
    desktop.on("pageerror", lambda error: errors.append(str(error)))
    verify(desktop, DESKTOP_SCREENSHOT)
    desktop_context.close()

    mobile_context = browser.new_context(viewport={"width": 390, "height": 844})
    mobile = mobile_context.new_page()
    mobile.on(
        "console",
        lambda message: (
            errors.append(message.text) if message.type == "error" else None
        ),
    )
    mobile.on("pageerror", lambda error: errors.append(str(error)))
    verify(mobile, MOBILE_SCREENSHOT)
    mobile_context.close()

    browser.close()
    if errors:
        raise RuntimeError("browser errors: " + " | ".join(errors))
