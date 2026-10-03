"""Real local HTML interactions; no server, model, install or delivery effects."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tomllib

from playwright.sync_api import sync_playwright, expect


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--browser-executable")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    files = [root / "docs/design/lane-addons-composer.html",
             root / "docs/design/lane-composition-export.js",
             root / "addons/fusion-report/server.py"]
    summary = {"scope": "real Chromium local HTML and Python package MCP stdio fixtures; no MASC server or live provider execution",
               "source_sha256": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in files},
               "masc_server_execution": False, "package_stdio_fixture": True,
               "live_provider": False, "broadcast": False,
               "checks": [], "status": "running"}
    errors = []
    try:
        with sync_playwright() as driver:
            browser = driver.chromium.launch(headless=True, executable_path=args.browser_executable)
            try:
                context = browser.new_context(viewport={"width": 1600, "height": 1100}, accept_downloads=True)
                context.route("**/*", lambda route: route.continue_() if route.request.url.startswith(("file:", "blob:", "data:")) else route.abort())
                page = context.new_page()
                page.set_default_timeout(10000)
                page.on("pageerror", lambda error: errors.append(str(error)))
                page.goto(files[0].as_uri())
                expect(page.locator(".node[data-kind=panel]")).to_have_count(2)
                expect(page.locator(".layer")).to_have_count(6)
                page.get_by_role("button", name="설치 TOML 미리보기", exact=True).click()
                expect(page.locator("#status")).to_contain_text("입력하세요")
                summary["checks"].append("incomplete declarations rejected visibly")
                page.get_by_text("설치 선언에 사용할 공통 설정", exact=True).click()

                def fill(label, value):
                    field = page.get_by_label(label, exact=True)
                    field.fill(value)
                    field.press("Tab")

                settings = {"실행 이름": "browser-fixture", "분석 이름": "browser-analysis",
                            "계산 패키지 manifest 절대 경로": "/fixture/fusion-compute/lane.toml",
                            "보고서 패키지 manifest 절대 경로": "/fixture/fusion-report/lane.toml",
                            "공통 질문": "Compare the supplied evidence."}
                for label, value in settings.items():
                    fill(label, value)
                page.locator(".node[data-kind=source]").click()
                fill("서버 자료 파일 절대 경로", "/fixture/input.json")
                fill("자료 JSON의 source_id", "retained-original")
                for index, name in enumerate(("panel-a", "panel-b", "judge", "report")):
                    selector = ".node[data-kind=panel]" if index < 2 else ".node[data-kind=" + name + "]"
                    node = page.locator(selector).nth(index if index < 2 else 0)
                    node.click()
                    fill("설치 이름", name)
                    if name != "report":
                        fill("선언된 모델 경로", "fixture." + name)
                        fill("검토 지시", "Preserve original evidence for " + name)
                        fill("출력 토큰 한도", "512")

                def preview():
                    page.get_by_role("button", name="설치 TOML 미리보기", exact=True).click()
                    expect(page.locator("#declaration-files pre")).to_have_count(4)
                    return page.locator("#declaration-files pre").all_text_contents()

                declarations = preview()
                parsed = [tomllib.loads(text) for text in declarations]
                assert [item["id"] for item in parsed] == ["panel-a", "panel-b", "judge", "report"]
                assert [item["binding"]["sources"][0]["source_id"] for item in parsed[:2]] == ["retained-original"] * 2
                assert parsed[2]["binding"]["sources"][1]["installation_id"] == "panel-b"
                assert parsed[3]["binding"]["sources"][0]["installation_id"] == "judge"
                with page.expect_download() as saved:
                    page.get_by_role("button", name="이 TOML 저장", exact=True).first.click()
                saved.value.save_as(output / "panel-a.toml")
                assert (output / "panel-a.toml").read_text() == declarations[0]
                summary["checks"].append("four named-port TOMLs rendered and real download matched")
                fill("공통 질문", "Different question")
                expect(page.locator("#declarations")).to_be_hidden()
                page.get_by_role("button", name="되돌리기", exact=True).click()
                expect(page.get_by_label("공통 질문", exact=True)).to_have_value(settings["공통 질문"])
                assert preview() == declarations
                summary["checks"].append("settings edit invalidates preview; actual Undo restores identical TOML")
                with page.expect_download() as saved:
                    page.get_by_role("button", name="조립안 JSON 저장", exact=True).click()
                saved.value.save_as(output / "composition.json")
                fill("실행 이름", "stale-run")
                page.locator("#import-file").set_input_files(output / "composition.json")
                expect(page.get_by_label("실행 이름", exact=True)).to_have_value("browser-fixture")
                assert preview() == declarations
                summary["checks"].append("actual saved JSON import replaces stale settings and preserves all TOMLs")
                # Render a real package-produced report over fixture inputs,
                # rather than constructing a fake DOM result for this check.
                sys.path.insert(0, str(root / "addons/tests"))
                from test_fusion_report import call, computation_output, upstream, reports, contexts
                computed = computation_output(role="judge")
                fields = computed["rows"][0]["fields"]
                fields["computation"]["analysis_id"] = "browser-analysis"
                computed["rows"][0]["subject_id"] = "browser-analysis"
                untrusted = '<img src=x onerror="globalThis.reportInjected=true">'
                fields["computation"]["text"] = "Retained Judge comparison\n" + untrusted
                fields["sampling_response"]["content"]["text"] = fields["computation"]["text"]
                fields["input_complete"] = False
                fields["input_coverage"][0].update(complete=False, detail="Panel B evidence is missing")
                supplied = upstream(computed, installation_id="judge", instance_id="fixture-judge", sequence=7)
                supplied["observations"][0]["producer"]["run_id"] = "browser-fixture"
                report = call("fusion-report", [supplied])
                assert not report["isError"]
                report_path = output / "received-report.json"
                report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
                page.locator("#reports-file").set_input_files(report_path)
                expect(page.locator("#received-reports")).to_contain_text("Retained Judge comparison")
                expect(page.locator("#received-reports")).to_contain_text("Panel B evidence is missing")
                expect(page.locator("#received-reports")).to_contain_text("기록상 입력 불완전")
                expect(page.locator("#received-reports")).to_contain_text("선언된 입력이 일치하는 블록: 근거가 이어진 보고서")
                expect(page.locator("#received-reports img")).to_have_count(0)
                assert page.evaluate("globalThis.reportInjected === undefined")
                expected_body = reports(report["structuredContent"])[0]["fields"]["body"]
                expect(page.locator(".received-answer")).to_have_text(fields["computation"]["text"])
                expect(page.locator(".received-answer")).to_be_visible()
                expect(page.locator(".received-report-body")).to_be_hidden()
                page.get_by_text("입력 경로와 전체 보존 기록", exact=True).click()
                expect(page.locator(".received-report-body")).to_be_visible()
                expect(page.locator(".received-report-body")).to_have_text(expected_body)
                page.locator("#received-reports").screenshot(path=str(output / "received-report-desktop.png"))
                reordered = json.loads(json.dumps(report))
                reordered["structuredContent"]["rows"].reverse()
                context_path = output / "context-order.json"
                context_path.write_text(json.dumps(reordered, ensure_ascii=False) + "\n")
                page.locator("#reports-file").set_input_files(context_path)
                expect(page.locator(".received-answer")).to_have_text(fields["computation"]["text"])
                reordered["structuredContent"]["rows"] = reports(reordered["structuredContent"])
                context_path.write_text(json.dumps(reordered, ensure_ascii=False) + "\n")
                page.locator("#reports-file").set_input_files(context_path)
                expect(page.locator("#status")).to_contain_text("이전 파일의 보고서는 유지됩니다")
                expect(page.locator(".received-answer")).to_have_text(fields["computation"]["text"])
                ambiguous = json.loads(json.dumps(report))
                raw = contexts(ambiguous["structuredContent"])[0]["fields"]["raw_computed_rows"]
                raw.append(json.loads(json.dumps(raw[0])))
                context_path.write_text(json.dumps(ambiguous, ensure_ascii=False) + "\n")
                page.locator("#reports-file").set_input_files(context_path)
                expect(page.locator(".received-answer")).to_have_count(0)
                expect(page.locator(".received-report-body")).to_be_visible()
                summary["checks"].append("report/context row order independent; missing context rejected without replacing report; ambiguous retained reply leaves full body visible")
                conflicting = json.loads(json.dumps(report))
                contexts(conflicting["structuredContent"])[0]["fields"]["raw_computed_rows"][0]["fields"]["sampling_response"]["content"]["text"] = "Another retained response"
                conflicting_path = output / "conflicting-response.json"
                conflicting_path.write_text(json.dumps(conflicting, ensure_ascii=False) + "\n")
                page.locator("#reports-file").set_input_files(conflicting_path)
                expect(page.locator(".received-answer")).to_have_count(0)
                expect(page.locator(".received-report-body")).to_be_visible()
                expect(page.locator(".received-report-body")).to_have_text(expected_body)
                missing_model = json.loads(json.dumps(report))
                missing_fields = contexts(missing_model["structuredContent"])[0]["fields"]["raw_computed_rows"][0]["fields"]
                missing_fields["computation"]["model"] = ""
                missing_fields["sampling_response"]["model"] = ""
                conflicting_path.write_text(json.dumps(missing_model, ensure_ascii=False) + "\n")
                page.locator("#reports-file").set_input_files(conflicting_path)
                expect(page.locator(".received-answer")).to_have_count(0)
                expect(page.locator(".received-report-body")).to_be_visible()
                missing_stop = json.loads(json.dumps(report))
                missing_fields = contexts(missing_stop["structuredContent"])[0]["fields"]["raw_computed_rows"][0]["fields"]
                del missing_fields["computation"]["stop_reason"]
                del missing_fields["sampling_response"]["stopReason"]
                conflicting_path.write_text(json.dumps(missing_stop, ensure_ascii=False) + "\n")
                page.locator("#reports-file").set_input_files(conflicting_path)
                expect(page.locator(".received-answer")).to_have_count(0)
                expect(page.locator(".received-report-body")).to_be_visible()
                page.locator("#reports-file").set_input_files(report_path)
                expect(page.locator(".received-answer")).to_be_visible()
                summary["checks"].append("answer first with explicit full-record expansion; inconsistent retained response falls back to unchanged visible report")
                fill("실행 이름", "another-run")
                expect(page.locator("#received-reports")).to_contain_text("현재 조립안과 연결 미확인")
                page.get_by_role("button", name="되돌리기", exact=True).click()
                expect(page.locator("#received-reports")).to_contain_text("선언된 입력이 일치하는 블록")
                bad = output / "invalid-report.json"
                bad.write_text(json.dumps({"rows": []}) + "\n")
                page.locator("#reports-file").set_input_files(bad)
                expect(page.locator("#status")).to_contain_text("이전 파일의 보고서는 유지됩니다")
                expect(page.locator("#report-file-name")).to_contain_text("received-report.json")
                page.get_by_role("button", name="보고서 닫기", exact=True).click()
                expect(page.locator(".received-report-body")).to_have_count(0)
                page.locator("#reports-file").set_input_files(report_path)
                expect(page.locator(".received-report-body")).to_have_text(expected_body)
                summary["checks"].append("actual MCP fixture report imported; text/gaps preserved safely; declared run match invalidates on edit and restores on Undo; invalid import preserves previous file; close clears report")
                # Native ownership and delivery metadata below are synthetic
                # fixtures, not an execution of the MASC Evidence operation.
                owned = json.loads(json.dumps(report))
                owned_row = reports(owned["structuredContent"])[0]
                owned_row["id"] = "report-worker/1/" + owned_row["id"]
                owned_row["lane_id"] = "report-worker/fusion/report"
                owned_context = contexts(owned["structuredContent"])[0]
                owned_context["id"] = "report-worker/1/" + owned_context["id"]
                owned_context["lane_id"] = "report-worker/fusion/report-context"
                owned_row["related_ids"] = [owned_context["id"]]
                owned_path = output / "owned-report-fixture.json"
                owned_path.write_text(json.dumps(owned, ensure_ascii=False) + "\n")
                receipt = {"instance_id": "report-worker", "row_ids": [owned_row["id"]], "row_count": 1,
                           "evidence": {"uri": "lane-evidence:" + "a" * 64, "sha256": "a" * 64},
                           "delivery": {"destination": "broadcast", "status": "committed", "receipt": {"id": "fixture-message"}}}
                receipt_path = output / "sharing-receipt-fixture.json"
                receipt_path.write_text(json.dumps(receipt) + "\n")
                page.locator("#sharing-file").set_input_files(receipt_path)
                expect(page.locator(".sharing-match")).to_contain_text("열린 보고서와 선택 좌표 미확인")
                expect(page.locator(".report-sharing")).to_have_count(0)
                page.locator("#reports-file").set_input_files(owned_path)
                expect(page.locator(".sharing-match")).to_contain_text("열린 보고서와 선택 좌표 일치")
                expect(page.locator(".report-sharing")).to_contain_text("Broadcast · 메시지 저장 · 읽기·활용 미확인")
                page.locator("#received-sharing").screenshot(path=str(output / "sharing-desktop.png"))
                for state in ("accepted", "failed", "outcome_unknown"):
                    receipt["delivery"] = {"destination": "keeper", "keeper_name": "fixture-reader", "status": state}
                    if state != "accepted":
                        receipt["delivery"]["error"] = "Fixture delivery cannot establish reading"
                    receipt_path.write_text(json.dumps(receipt) + "\n")
                    page.locator("#sharing-file").set_input_files(receipt_path)
                    expect(page.locator(".report-sharing")).to_contain_text("Keeper fixture-reader")
                    expect(page.locator(".report-sharing")).to_contain_text({"accepted": "전달 수락", "failed": "전달 실패", "outcome_unknown": "전달 결과 확인 필요"}[state])
                    expect(page.locator(".report-sharing")).to_contain_text("읽기·활용 미확인")
                receipt["row_ids"] = ["report-worker/2/another-result"]
                receipt_path.write_text(json.dumps(receipt) + "\n")
                page.locator("#sharing-file").set_input_files(receipt_path)
                expect(page.locator(".report-sharing")).to_have_count(0)
                expect(page.locator(".sharing-match")).to_contain_text("선택 좌표 미확인")
                receipt_path.write_text(json.dumps({"row_count": 1}) + "\n")
                page.locator("#sharing-file").set_input_files(receipt_path)
                expect(page.locator("#status")).to_contain_text("이전 영수증은 유지됩니다")
                page.get_by_role("button", name="영수증 닫기", exact=True).click()
                expect(page.locator(".sharing-state")).to_have_count(0)
                summary["checks"].append("synthetic native ownership and sharing receipts: exact row/lane selection matching, Broadcast and Keeper states, other selection rejection, invalid import retention and clear; no native delivery executed")
                preview()
                page.locator("#canvas").screenshot(path=str(output / "layers-desktop.png"))
                page.locator("#declarations").screenshot(path=str(output / "declarations-desktop.png"))
                page.set_viewport_size({"width": 390, "height": 844})
                assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
                page.screenshot(path=str(output / "mobile.png"), full_page=True)
                summary["checks"].append("390px document has no horizontal overflow")
                assert not errors, errors
                summary["browser"] = browser.version
                summary["status"] = "passed"
            finally:
                browser.close()
    except Exception as error:
        summary["status"] = "failed"
        summary["error"] = str(error)
        raise
    finally:
        summary["page_errors"] = errors
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
