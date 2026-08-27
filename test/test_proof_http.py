import importlib.util
from pathlib import Path
import sys
import unittest
from urllib.request import Request


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "harness" / "workload" / "proof_http.py"


def load_module():
    spec = importlib.util.spec_from_file_location("proof_http", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


proof_http = load_module()


class ProofHttpTest(unittest.TestCase):
    def test_exact_origin_receives_bearer(self):
        headers = proof_http.scoped_bearer_headers(
            base_url="https://masc.example",
            request_url="https://masc.example:443/api/v1/dashboard/tools",
            headers={"Accept": "application/json"},
            token="secret",
        )
        self.assertEqual(headers["Authorization"], "Bearer secret")

    def test_foreign_origin_never_receives_bearer(self):
        headers = proof_http.scoped_bearer_headers(
            base_url="https://masc.example",
            request_url="https://assets.example/image.png",
            headers={"Authorization": "Bearer inherited", "Accept": "image/png"},
            token="secret",
        )
        self.assertNotIn("Authorization", headers)

    def test_redirect_is_rejected_before_second_request(self):
        handler = proof_http.RejectRedirects()
        request = Request("https://masc.example/original")
        with self.assertRaises(proof_http.RedirectRejected):
            handler.redirect_request(
                request,
                None,
                302,
                "Found",
                {},
                "https://foreign.example/redirected",
            )


if __name__ == "__main__":
    unittest.main()
