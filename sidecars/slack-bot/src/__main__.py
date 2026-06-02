"""Entry point: python -m src.

기본은 봇 기동. ``diagnostics`` subcommand 로 건강 점검만 실행.

    python -m src                # 봇 기동
    python -m src diagnostics         # 점검
    python -m src diagnostics --json  # 점검 결과 JSON
    python -m src diagnostics --fix   # 가능한 auto-fix 후 재점검
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

from gate_shared import (  # noqa: E402
    FixOutcome,
    exit_code_for,
    render_fix_outcomes,
    render_json,
    render_pretty,
)


def _run_diagnostics(argv: list[str]) -> int:
    # Lazy import — diagnostics must still run when runtime deps are missing.
    from .diagnostics import run_diagnostics  # noqa: PLC0415

    as_json = "--json" in argv
    auto_fix = "--fix" in argv

    async def run() -> int:
        diagnostics = await run_diagnostics()
        checks = await diagnostics.run()
        outcomes: list[FixOutcome] = []
        if auto_fix:
            checks, outcomes = await diagnostics.run_auto_fixes(checks)
        if as_json:
            sys.stdout.write(render_json(diagnostics.title, checks))
        else:
            fix_block = render_fix_outcomes(outcomes)
            if fix_block:
                sys.stdout.write(fix_block + "\n")
            sys.stdout.write(render_pretty(diagnostics.title, checks))
        sys.stdout.write("\n")
        return exit_code_for(checks)

    return asyncio.run(run())


if len(sys.argv) > 1 and sys.argv[1] == "diagnostics":
    raise SystemExit(_run_diagnostics(sys.argv[2:]))

from .bot import main  # noqa: E402

main()
