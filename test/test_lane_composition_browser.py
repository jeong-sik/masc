"""Real local HTML interactions; no server, model, install or delivery effects."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tomllib

from playwright.sync_api import sync_playwright, expect


def check_composition_import_races(page, output, checks):
    """Delay real File.text reads while driving the file input and editor UI."""
    page.evaluate("""() => {
        const text = File.prototype.text, pending = new Map();
        File.prototype.text = function () {
            return new Promise((resolve, reject) => {
                pending.set(this.name, {file: this, resolve, reject});
            });
        };
        globalThis.finishCompositionRead = async (name, fail) => {
            const read = pending.get(name);
            if (!read) throw Error('File.text was not called for ' + name);
            pending.delete(name);
            if (fail) read.reject(Error('fixture read failure'));
            else read.resolve(await text.call(read.file));
            // The application's await continuation runs before this resumes.
            await Promise.resolve();
        };
    }""")

    def exported(name):
        with page.expect_download() as saved:
            page.locator("#export").click()
        path = output / ("import-race-" + name + ".json")
        saved.value.save_as(path)
        return json.loads(path.read_text())

    original = exported("original")

    def fixture(name):
        graph = json.loads(json.dumps(original))
        graph["title"] = "Import fixture " + name
        graph["nodes"][0]["name"] = "Source " + name
        graph["nodes"][0].update(snapshot_path="/fixture/" + name + ".json",
                                  snapshot_source_id="source-" + name)
        graph["installation_settings"] = {
            "run_id": "run-" + name, "analysis_id": "analysis-" + name,
            "compute_manifest": "/fixture/fusion-compute/lane.toml",
            "report_manifest": "/fixture/fusion-report/lane.toml", "prompt": "Question " + name}
        for node in graph["nodes"]:
            if "installation" in node:
                node["installation"].update(model_route="fixture." + name,
                                            instructions="Review " + name, max_tokens=512)
        return graph

    a, b = fixture("a"), fixture("b")

    def start(name, graph):
        page.locator("#import-file").set_input_files({
            "name": name, "mimeType": "application/json",
            "buffer": json.dumps(graph, ensure_ascii=False).encode()})

    def finish(name, fail=False):
        page.evaluate("([name, fail]) => finishCompositionRead(name, fail)", [name, fail])

    def unchanged(name, expected, download=False):
        # Use the actual download for the overwrite regression; observe the live
        # editor state elsewhere so Chromium does not throttle burst downloads.
        actual = exported(name) if download else page.evaluate("JSON.parse(JSON.stringify(graph))")
        (output / ("import-race-" + name + ".json")).write_text(
            json.dumps(actual, ensure_ascii=False, indent=2) + "\n")
        assert actual == expected, (f"{name}: expected {expected['title']} / "
                                    f"{expected['installation_settings']['run_id']}, got "
                                    f"{actual['title']} / {actual['installation_settings']['run_id']}")
        expect(page.locator("#graph-title")).to_have_text(expected["title"])
        expect(page.get_by_label("실행 이름", exact=True)).to_have_value(expected["installation_settings"]["run_id"])

    def undo_to_original():
        page.locator("#undo").click()
        unchanged("after-undo", original)
        expect(page.locator("#undo")).to_be_disabled()

    start("a.json", a)
    start("b.json", b)
    finish("b.json")
    unchanged("b-before-a", b)
    status = page.locator("#status").text_content()
    finish("a.json")
    page.screenshot(path=str(output / "import-race-latest-file.png"), full_page=True)
    actual_status = page.locator("#status").text_content()
    unchanged("b-after-a", b, download=True)
    assert actual_status == status
    page.locator("#declaration-preview").click()
    declarations = [tomllib.loads(text) for text in page.locator("#declaration-files pre").all_text_contents()]
    assert len(declarations) == 4
    assert all(item["run_id"] == "run-b" for item in declarations)
    undo_to_original()
    checks.append("deferred A/B imports: B finishes first; late A cannot replace graph/settings/TOMLs or add Undo history")

    start("a.json", a)
    start("b.json", b)
    finish("a.json")
    unchanged("a-while-b-pending", original)
    finish("b.json")
    unchanged("b-after-pending", b)
    undo_to_original()
    checks.append("deferred A/B imports: A finishes first after B selection; only B is applied")

    page.get_by_text("설치 선언에 사용할 공통 설정", exact=True).click()

    def edit_run():
        field = page.get_by_label("실행 이름", exact=True)
        field.fill("edited-run")
        field.press("Tab")

    start("a.json", a)
    field = page.get_by_label("실행 이름", exact=True)
    field.fill("still-typing")
    finish("a.json")
    expect(field).to_have_value("still-typing")
    field.press("Tab")
    expected = json.loads(json.dumps(original))
    expected["installation_settings"]["run_id"] = "still-typing"
    unchanged("typing-before-blur", expected)
    undo_to_original()
    checks.append("typing in an installation setting cancels pending import before blur commits the edit")

    for action in ("edit", "template", "undo"):
        if action == "undo":
            edit_run()
        start("a.json", a)
        if action == "edit":
            edit_run()
        elif action == "template":
            page.locator("#template").select_option("empty")
            page.locator("#load-template").click()
        else:
            page.locator("#undo").click()
        expected = page.evaluate("JSON.parse(JSON.stringify(graph))")
        status = page.locator("#status").text_content()
        finish("a.json")
        expect(page.locator("#status")).to_have_text(status)
        unchanged("late-file-after-" + action, expected)
        if action != "undo":
            undo_to_original()
        else:
            assert expected == original
            expect(page.locator("#undo")).to_be_disabled()
        checks.append("deferred import cannot overwrite subsequent " + action + " or change its Undo history")

    for fail in (False, True):
        start("stale-invalid.json", {})
        start("b.json", b)
        finish("b.json")
        status = page.locator("#status").text_content()
        finish("stale-invalid.json", fail=fail)
        expect(page.locator("#status")).to_have_text(status)
        expect(page.locator("#status")).not_to_have_class("status error")
        unchanged("stale-error-" + str(fail), b)
        undo_to_original()
    for fail in (False, True):
        start("a.json", a)
        start("current-invalid.json", {})
        finish("current-invalid.json", fail=fail)
        expect(page.locator("#status")).to_contain_text("불러오기 실패")
        status = page.locator("#status").text_content()
        finish("a.json")
        expect(page.locator("#status")).to_have_text(status)
        unchanged("failed-newest-import-" + str(fail), original)
        expect(page.locator("#undo")).to_be_disabled()
    checks.append("stale validation/read errors stay silent; failed newest import preserves graph and cancels older read")
    start("a.json", a)
    page.locator(".node[data-kind=source]").click()
    finish("a.json")
    unchanged("node-selection-during-read", a)
    undo_to_original()
    checks.append("inspecting a node without editing still allows the current import to finish")
    # Remove the File.text fixture and reset editor history for the other checks.
    page.reload()


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
             root / "addons/fusion-report/server.py",
             Path(__file__).resolve()]
    summary = {"scope": "real Chromium local HTML and Python package MCP stdio fixtures; no MASC server or live provider execution",
               "source_sha256": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in files},
               "masc_server_execution": False, "package_stdio_fixture": False,
               "live_provider": False, "broadcast": False,
               "checks": [], "status": "running"}
    errors = []
    try:
        with sync_playwright() as driver:
            browser = driver.chromium.launch(headless=True, executable_path=args.browser_executable)
            summary["browser"] = browser.version
            try:
                context = browser.new_context(viewport={"width": 1600, "height": 1100}, accept_downloads=True)
                context.route("**/*", lambda route: route.continue_() if route.request.url.startswith(("file:", "blob:", "data:")) else route.abort())
                page = context.new_page()
                page.set_default_timeout(10000)
                page.on("pageerror", lambda error: errors.append(str(error)))
                page.goto(files[0].as_uri())
                check_composition_import_races(page, output, summary["checks"])
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
                untrusted = '<img src=x onerror="globalThis.reportInjected=true">'
                computed = computation_output(role="judge", text="Retained Judge comparison\n" + untrusted)
                fields = computed["rows"][0]["fields"]
                fields["computation"]["analysis_id"] = "browser-analysis"
                computed["rows"][0]["subject_id"] = "browser-analysis"
                fields["input_complete"] = False
                fields["input_coverage"][0].update(complete=False, detail="Panel B evidence is missing")
                supplied = upstream(computed, installation_id="judge", instance_id="fixture-judge", sequence=7)
                supplied["observations"][0]["producer"]["run_id"] = "browser-fixture"
                report = call("fusion-report", [supplied])
                summary["package_stdio_fixture"] = True
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
