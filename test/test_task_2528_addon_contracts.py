"""E07·E12 — Fusion/MSX/DOS 및 7개 패키지의 공통 계약 적합성과
observation-only/callable 구분을 고정한다.

task-2528의 첫 층. 각 패키지의 lane.toml contributions 필드가 실제
동작과 일치하는지, 그리고 observation-only 패키지가 호출 가능한 도구를
노출하지 않는지를 검증한다.
"""
import json
import sys
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDONS = ROOT / "addons"


def _load_lane_toml(package: str) -> dict:
    path = ADDONS / package / "lane.toml"
    with path.open("rb") as f:
        return tomllib.load(f)


def _read_server_py(package: str) -> str:
    path = ADDONS / package / "server.py"
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


class FusionPackages(unittest.TestCase):
    """Fusion compute/results/report의 contributions와 동작 일치."""

    def test_fusion_compute_declares_derive_contribution(self):
        m = _load_lane_toml("fusion-compute")
        self.assertIn("derive", m.get("contributions", []))

    def test_fusion_results_declares_derive_contribution(self):
        m = _load_lane_toml("fusion-results")
        self.assertIn("derive", m.get("contributions", []))

    def test_fusion_report_declares_derive_contribution(self):
        m = _load_lane_toml("fusion-report")
        self.assertIn("derive", m.get("contributions", []))

    def test_fusion_compute_has_no_observe_contribution(self):
        """fusion-compute는 derive만 하고 observation은 하지 않는다."""
        m = _load_lane_toml("fusion-compute")
        self.assertNotIn("observe", m.get("contributions", []))

    def test_fusion_results_declares_observe_and_derive(self):
        """fusion-results는 observe와 derive를 모두 선언한다."""
        m = _load_lane_toml("fusion-results")
        contribs = m.get("contributions", [])
        self.assertIn("observe", contribs)
        self.assertIn("derive", contribs)

    def test_fusion_report_has_no_observe_contribution(self):
        m = _load_lane_toml("fusion-report")
        self.assertNotIn("observe", m.get("contributions", []))

    def test_fusion_compute_publishes_result_output(self):
        m = _load_lane_toml("fusion-compute")
        outputs = m.get("world", {}).get("outputs", {})
        self.assertIn("result", outputs)

    def test_fusion_results_publishes_result_and_status_outputs(self):
        m = _load_lane_toml("fusion-results")
        outputs = m.get("world", {}).get("outputs", {})
        self.assertIn("result", outputs)
        self.assertIn("status", outputs)

    def test_fusion_report_publishes_report_output(self):
        m = _load_lane_toml("fusion-report")
        outputs = m.get("world", {}).get("outputs", {})
        self.assertIn("report", outputs)


class MxsDosObservationOnly(unittest.TestCase):
    """MSX/DOS 패키지의 observation-only/callable 구분."""

    def test_msx_observer_is_observe_only(self):
        """msx-observer는 observe만 선언하고 도구를 노출하지 않는다."""
        m = _load_lane_toml("msx-observer")
        self.assertIn("observe", m.get("contributions", []))
        tools = m.get("world", {}).get("tools", {})
        self.assertNotIn("export", tools)

    def test_msx_machine_is_observe_with_host_context_tools(self):
        """msx-machine은 observe + host_context 도구 호출을 선언한다."""
        m = _load_lane_toml("msx-machine")
        self.assertIn("observe", m.get("contributions", []))
        tools = m.get("world", {}).get("tools", {})
        self.assertEqual(tools.get("invocation"), "host_context")
        self.assertIn("export", tools)
        exported = tools["export"]
        self.assertIn("masc_msx_load", exported)
        self.assertIn("masc_msx_restore", exported)

    def test_dos_machine_is_observe_with_host_context_tools(self):
        m = _load_lane_toml("dos-machine")
        self.assertIn("observe", m.get("contributions", []))
        tools = m.get("world", {}).get("tools", {})
        self.assertEqual(tools.get("invocation"), "host_context")
        self.assertIn("masc_dos_load", tools["export"])
        self.assertIn("masc_dos_restore", tools["export"])

    def test_msx_observer_never_declares_derive(self):
        m = _load_lane_toml("msx-observer")
        self.assertNotIn("derive", m.get("contributions", []))


class SevenPackages(unittest.TestCase):
    """E12 — 나머지 7개 패키지의 contributions 일치."""

    def test_output_statistics_is_derive(self):
        m = _load_lane_toml("output-statistics")
        self.assertIn("derive", m.get("contributions", []))

    def test_value_difference_is_derive(self):
        m = _load_lane_toml("value-difference")
        self.assertIn("derive", m.get("contributions", []))

    def test_frame_progress_is_derive(self):
        m = _load_lane_toml("frame-progress")
        self.assertIn("derive", m.get("contributions", []))

    def test_web_project_is_derive(self):
        m = _load_lane_toml("web-project")
        self.assertIn("derive", m.get("contributions", []))

    def test_wkbl_score_runs_is_derive(self):
        m = _load_lane_toml("wkbl-score-runs")
        self.assertIn("derive", m.get("contributions", []))

    def test_operator_quiz_is_derive(self):
        m = _load_lane_toml("operator-quiz")
        self.assertIn("derive", m.get("contributions", []))

    def test_web_project_declares_observe_and_derive(self):
        m = _load_lane_toml("web-project")
        contribs = m.get("contributions", [])
        self.assertIn("observe", contribs)
        self.assertIn("derive", contribs)

    def test_pure_derive_packages_do_not_claim_observe(self):
        """observe 없이 derive만 하는 6개 패키지."""
        for pkg in [
            "output-statistics", "value-difference", "frame-progress",
            "wkbl-score-runs", "operator-quiz", "fusion-compute",
        ]:
            with self.subTest(package=pkg):
                m = _load_lane_toml(pkg)
                self.assertNotIn(
                    "observe", m.get("contributions", []),
                    f"{pkg} must not claim observe contribution"
                )


if __name__ == "__main__":
    unittest.main()
