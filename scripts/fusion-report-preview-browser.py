"""Render the regenerated stdio fixture; requires Playwright and Chromium."""
import hashlib
import json
from pathlib import Path

from playwright.sync_api import sync_playwright


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


repo = Path(__file__).resolve().parents[1]
directory = repo / "docs/evidence/fusion-report-20260930"
composition = directory / "composition.json"
preview = repo / "docs/design/fusion-report-preview.html"
capture = json.loads(composition.read_text())
report = next(row for row in capture["report_output"]["rows"] if row["lane_id"] == "fusion/report")
context = next(row for row in capture["report_output"]["rows"] if row["id"] in report["related_ids"])
lineage = {"producer": context["fields"]["producer"],
           "upstream_rows": context["fields"]["upstream_rows"],
           "upstream_output_evidence": context["evidence"]}
checks = []
with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    try:
        for name, width, height, filename in (
                ("desktop", 1440, 1100, "preview.png"),
                ("mobile", 390, 844, "preview-mobile.png")):
            page = browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
            page.goto(preview.as_uri())
            body_matches = page.locator("#report-body").text_content() == report["fields"]["body"]
            delivery_matches = page.locator("#delivery-state").text_content() == report["fields"]["delivery_label"]
            page.locator("details summary").click()
            expanded = page.locator("details").evaluate("element => element.open")
            lineage_matches = json.loads(page.locator("#report-lineage").text_content()) == lineage
            overflow = page.evaluate("document.documentElement.scrollWidth > window.innerWidth")
            if not body_matches or not delivery_matches or not expanded or not lineage_matches or overflow:
                raise RuntimeError(f"{name} preview does not match its current worker output")
            screenshot = directory / filename
            page.screenshot(path=str(screenshot), full_page=True)
            page.close()
            checks.append({"viewport": name, "width": width, "height": height,
                           "horizontal_overflow": overflow, "lineage_expanded": expanded,
                           "lineage_matches_worker": lineage_matches,
                           "body_matches_worker": body_matches, "delivery_matches_worker": delivery_matches,
                           "screenshot": filename, "sha256": sha256(screenshot)})
    finally:
        browser.close()
receipt = {"provenance": "Headless Chromium rendered final MCP stdio fixture output; not native host or production",
           "preview_sha256": sha256(preview), "composition_sha256": sha256(composition), "checks": checks}
(directory / "preview-checks.json").write_text(json.dumps(receipt, indent=2) + "\n")
print("Two browser viewports match regenerated worker body, delivery label and exact lineage")
