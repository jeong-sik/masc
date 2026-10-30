#!/usr/bin/env python3
"""Which `Public_read` routes answer without a credential under strict auth (A4d back half).

  public_read_open_in_strict.py <run-dir>/strict

`<run-dir>/strict` is the output of scripts/auth-route-baseline/run.sh with
MASC_HTTP_AUTH_STRICT=true MASC_AUTH_STRICT=strict. A `Public_read` route that answers 401 or 403
to a request with no credential is closed under strict auth. The others are open, and
`Server_auth.is_public_read_path` is what opens them. `/api/v1/published-artifacts/` opens only
for a well-formed artifact id, which the probe's `/probe-a1` is not, so it shows as closed here.
"""

import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
routes = json.loads((run / "routes.json").read_text(encoding="utf-8"))["routes"]
rows = json.loads((run / "results.json").read_text(encoding="utf-8"))["rows"]
kind_of = {(m, r["path"], r["kind"]): r["access"]["kind"] for r in routes for m in r["methods"]}
public_read = [r for r in rows if kind_of.get((r["method"], r["route_path"], r["kind"])) == "public_read"]
closed = [r for r in public_read if r["http1_none"] in (401, 403)]
opened = [r for r in public_read if r["http1_none"] not in (401, 403)]
print(f"public_read rows: {len(public_read)}; closed without a credential: {len(closed)}; open: {len(opened)}")
for r in sorted(opened, key=lambda r: (r["route_path"], r["method"])):
    print(f"  {r['method']:4} {r['route_path']:42} {r['kind']:6} status {r['http1_none']}")
