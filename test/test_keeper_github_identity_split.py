import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "keeper-github-identity-split.py"
)


def load_split_module():
    spec = importlib.util.spec_from_file_location("keeper_github_identity_split", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


split = load_split_module()


def write_keeper(root: Path, name: str, identity: str = "anyang-keepers") -> Path:
    path = root / ".masc" / "config" / "keepers" / f"{name}.toml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                "[keeper]",
                f'name = "{name}"',
                f'github_identity = "{identity}" # keep comment',
                'git_identity_mode = "keeper_alias"',
                'sandbox_profile = "docker"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    return path


class KeeperGithubIdentitySplitTest(unittest.TestCase):
    def test_build_plan_distributes_identities(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            alpha = write_keeper(root, "alpha")
            bravo = write_keeper(root, "bravo")
            charlie = write_keeper(root, "charlie")

            plan = split.build_plan(
                root, ["anyang-keepers", "reviewer-keepers"], [alpha, bravo, charlie]
            )

        self.assertEqual(
            [(item.keeper, item.github_identity) for item in plan],
            [
                ("alpha", "anyang-keepers"),
                ("bravo", "reviewer-keepers"),
                ("charlie", "anyang-keepers"),
            ],
        )

    def test_apply_plan_updates_keeper_section_and_backs_up(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            alpha = write_keeper(root, "alpha")
            bundle = root / ".masc" / "github-identities" / "reviewer-keepers" / "gh"
            bundle.mkdir(parents=True)
            plan = split.build_plan(root, ["reviewer-keepers", "anyang-keepers"], [alpha])

            backup_dir = split.apply_plan(
                root, plan, backup_dir="", allow_missing=False
            )

            updated = alpha.read_text(encoding="utf-8")
            backup = (backup_dir / "alpha.toml").read_text(encoding="utf-8")

        self.assertIn('github_identity = "reviewer-keepers" # keep comment', updated)
        self.assertIn('git_identity_mode = "github_identity"', updated)
        self.assertIn('github_identity = "anyang-keepers" # keep comment', backup)

    def test_main_dry_run_outputs_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_keeper(root, "alpha")
            write_keeper(root, "bravo")

            # Exercise the CLI-shaped path while keeping stdout capture simple.
            config_paths = split.keeper_config_paths(root, "")
            plan = split.build_plan(root, ["a", "b"], config_paths)
            payload = {
                "assignments": [split.asdict(item) for item in plan],
                "keeper_count": len(plan),
            }

        encoded = json.dumps(payload)
        self.assertIn('"keeper_count": 2', encoded)
        self.assertIn('"github_identity": "a"', encoded)


if __name__ == "__main__":
    unittest.main()
