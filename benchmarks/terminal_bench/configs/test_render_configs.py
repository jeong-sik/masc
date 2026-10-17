"""Reasoning request policy in the runtime TOML shipped to benchmark trials."""
from pathlib import Path
import tempfile
import tomllib
import unittest

from render_configs import render_arm


class RenderReasoningPolicy(unittest.TestCase):
    def render(self, runtime_id, *, arm="e", effort="high", fallbacks=()):
        with tempfile.TemporaryDirectory() as root:
            rendered = render_arm(arm, runtime_id, effort, Path(root),
                                  fallback_runtime_ids=fallbacks)
            return tomllib.loads((rendered / "runtime.toml").read_text())

    def assert_uncontrolled(self, model):
        self.assertTrue(model["reasoning-uncontrolled"])
        self.assertNotIn("thinking-support", model)
        self.assertNotIn("reasoning-effort", model)
        self.assertEqual(model["capabilities"]["thinking-control-format"], "none")

    def test_uncontrolled_models_do_not_request_a_thinking_toggle(self):
        for alias in ("qwen3-coder-next", "deepseek-v4-pro"):
            with self.subTest(model=alias):
                config = self.render("ollama_cloud." + alias)
                self.assertEqual(config["runtime"]["default"], "ollama_cloud." + alias)
                self.assert_uncontrolled(config["models"][alias])

    def test_model_specific_effort_keeps_its_explicit_enable(self):
        config = self.render("ollama_cloud.deepseek-v4.1-flash")
        model = config["models"]["deepseek-v4.1-flash"]
        self.assertEqual(model["reasoning-effort"], "low")
        self.assertTrue(model["thinking-support"])
        self.assertNotIn("reasoning-uncontrolled", model)
        self.assertEqual(model["capabilities"]["thinking-control-format"], "reasoning-effort")

    def test_controlled_provider_keeps_the_requested_effort(self):
        config = self.render("anthropic.claude-fable-5-1")
        model = config["models"]["claude-fable-5-1"]
        self.assertEqual(model["reasoning-effort"], "high")
        self.assertTrue(model["thinking-support"])
        self.assertNotIn("reasoning-uncontrolled", model)

    def test_candidate_lane_preserves_each_models_reasoning_policy(self):
        candidates = ["ollama_cloud.qwen3-coder-next", "ollama_cloud.deepseek-v4.1-flash"]
        config = self.render(candidates[0], arm="l", fallbacks=tuple(candidates[1:]))
        self.assertEqual(config["runtime"]["lanes"]["bench"]["candidates"], candidates)
        self.assert_uncontrolled(config["models"]["qwen3-coder-next"])
        controlled = config["models"]["deepseek-v4.1-flash"]
        self.assertEqual(controlled["reasoning-effort"], "low")
        self.assertTrue(controlled["thinking-support"])
        self.assertNotIn("reasoning-uncontrolled", controlled)

    def test_kimi_vision_routes_to_the_same_selected_model(self):
        config = self.render("kimi_coding.kimi-for-coding")
        self.assertEqual(config["runtime"]["media_failover"], ["kimi_coding.kimi-for-coding"])
        caps = config["models"]["kimi-for-coding"]["capabilities"]
        self.assertTrue(caps["supports-image-input"])
        self.assertTrue(caps["supports-multimodal-inputs"])

    def test_undeclared_model_does_not_gain_vision_from_provider(self):
        config = self.render("kimi_coding.unknown-model")
        self.assertEqual(config["runtime"]["media_failover"], [])
        self.assertNotIn("supports-image-input", config["models"]["unknown-model"]["capabilities"])


if __name__ == "__main__":
    unittest.main()
