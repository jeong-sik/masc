"""Doctor framework for MASC connector sidecars.

진단(Diagnose) → 보고(Report) → 힌트(Hint) → 자가치유(Fix) 의 네 단계를 표준화한다.
각 커넥터는 ``Check`` 들을 등록하고 ``Doctor.run()`` 으로 실행한다.

외모는 ``flutter doctor`` / ``brew doctor`` / ``rustup check`` 를 참고한다:

    [✓] gate reachable (http://localhost:8935)
    [!] DISCORD_ADMIN_ROLE_ID not set
        ↳ 서버 권한 가드가 열려 있습니다. 역할 ID 를 설정하세요.
          fix: export DISCORD_ADMIN_ROLE_ID=<role_id>
    [✗] binding store path not writable
        ↳ .gate/runtime/discord/bindings.json 을 만들 수 없습니다.
          auto-fix 가능: doctor --fix
"""

from __future__ import annotations

import asyncio
import importlib.metadata
import json
import sys
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass, field
from enum import Enum
from typing import Final

NETWORK_TIMEOUT_SEC: Final[float] = 3.0
"""체크 하나의 HTTP 타임아웃 상한. 체크 1개가 run 전체를 막지 않도록 짧게 둔다."""

__all__ = [
    "AutoFix",
    "Check",
    "CheckFn",
    "Doctor",
    "NETWORK_TIMEOUT_SEC",
    "Severity",
    "check_dependencies_installed",
    "render_pretty",
    "render_json",
]


class Severity(str, Enum):
    ok = "ok"
    info = "info"
    warn = "warn"
    error = "error"
    skip = "skip"

    def needs_action(self) -> bool:
        return self in (Severity.warn, Severity.error)


@dataclass(frozen=True, slots=True)
class AutoFix:
    description: str
    command: str | None = None
    callback: Callable[[], Awaitable[None]] | None = None


@dataclass(frozen=True, slots=True)
class Check:
    name: str
    severity: Severity
    message: str
    detail: str = ""
    hint: str | None = None
    auto_fix: AutoFix | None = None
    tags: tuple[str, ...] = field(default_factory=tuple)


CheckFn = Callable[[], Awaitable[Check]]


_SYMBOL: Final[dict[Severity, str]] = {
    Severity.ok: "[✓]",
    Severity.info: "[i]",
    Severity.warn: "[!]",
    Severity.error: "[✗]",
    Severity.skip: "[·]",
}

# ANSI 는 TTY 일 때만 켠다. json / CI 로그에는 plain text.
_COLOR: Final[dict[Severity, str]] = {
    Severity.ok: "\x1b[32m",
    Severity.info: "\x1b[36m",
    Severity.warn: "\x1b[33m",
    Severity.error: "\x1b[31m",
    Severity.skip: "\x1b[90m",
}
_RESET: Final[str] = "\x1b[0m"


def _colorize(text: str, sev: Severity, *, use_color: bool) -> str:
    if not use_color:
        return text
    return f"{_COLOR[sev]}{text}{_RESET}"


def render_pretty(
    title: str,
    checks: Sequence[Check],
    *,
    use_color: bool | None = None,
) -> str:
    """사람이 읽기 좋은 출력 ( ``flutter doctor`` 풍)."""

    if use_color is None:
        use_color = sys.stdout.isatty()

    lines: list[str] = []
    lines.append(f"# {title}")
    lines.append("")
    for c in checks:
        sym = _colorize(_SYMBOL[c.severity], c.severity, use_color=use_color)
        head = f"{sym} {c.name}"
        if c.detail:
            head += f"  ({c.detail})"
        lines.append(head)
        if c.severity == Severity.ok:
            continue
        if c.message:
            lines.append(f"    ↳ {c.message}")
        if c.hint:
            lines.append(f"      hint: {c.hint}")
        if c.auto_fix is not None:
            lines.append(f"      fix: {c.auto_fix.description}")
            if c.auto_fix.command:
                lines.append(f"        $ {c.auto_fix.command}")
            if c.auto_fix.callback is not None:
                lines.append("        auto-fix 가능: doctor --fix")
    lines.append("")
    counts = _tally(checks)
    summary = ", ".join(
        f"{counts[s]} {s.value}" for s in Severity if counts[s] > 0
    )
    lines.append(f"summary: {summary or '0 checks'}")
    return "\n".join(lines)


def render_json(title: str, checks: Sequence[Check]) -> str:
    payload = {
        "title": title,
        "checks": [
            {
                "name": c.name,
                "severity": c.severity.value,
                "message": c.message,
                "detail": c.detail,
                "hint": c.hint,
                "auto_fix": None
                if c.auto_fix is None
                else {
                    "description": c.auto_fix.description,
                    "command": c.auto_fix.command,
                    "callback_available": c.auto_fix.callback is not None,
                },
                "tags": list(c.tags),
            }
            for c in checks
        ],
        "summary": {s.value: _tally(checks)[s] for s in Severity},
    }
    return json.dumps(payload, ensure_ascii=False, indent=2)


def _tally(checks: Sequence[Check]) -> dict[Severity, int]:
    out: dict[Severity, int] = {s: 0 for s in Severity}
    for c in checks:
        out[c.severity] += 1
    return out


def exit_code_for(checks: Sequence[Check]) -> int:
    counts = _tally(checks)
    if counts[Severity.error] > 0:
        return 2
    if counts[Severity.warn] > 0:
        return 1
    return 0


class Doctor:
    def __init__(self, title: str) -> None:
        self._title = title
        self._checks: list[CheckFn] = []

    @property
    def title(self) -> str:
        return self._title

    def register(self, check: CheckFn) -> None:
        self._checks.append(check)

    def register_many(self, checks: Iterable[CheckFn]) -> None:
        for c in checks:
            self.register(c)

    async def run(self) -> list[Check]:
        # Checks are independent (env reads, disk stat, HTTP to different
        # endpoints). Sequential execution makes a slow gate timeout block
        # every later check; gather collapses the worst case to one timeout.
        return list(await asyncio.gather(*(self._safe_call(fn) for fn in self._checks)))

    @staticmethod
    async def _safe_call(fn: CheckFn) -> Check:
        try:
            return await fn()
        except Exception as exc:  # 진단 도구 자체는 멈추면 안 된다.
            return Check(
                name=getattr(fn, "__name__", "unknown_check"),
                severity=Severity.error,
                message=f"check raised: {exc.__class__.__name__}: {exc}",
            )

    async def run_auto_fixes(self, checks: Sequence[Check]) -> list[Check]:
        for c in checks:
            if c.auto_fix is None or c.auto_fix.callback is None:
                continue
            if not c.severity.needs_action():
                continue
            await c.auto_fix.callback()
        return await self.run()


def check_dependencies_installed(packages: Sequence[str]) -> CheckFn:
    """Return a CheckFn that reports any missing packages by name.

    Uses importlib.metadata (stdlib) so the check itself has zero runtime
    dependencies — critical for diagnosing "nothing is installed yet"
    states where importing the sidecar's own config module would crash.

    Register this first in a Doctor so the operator sees a single clear
    'missing deps' check instead of a raw ImportError traceback.
    """

    async def _check() -> Check:
        missing: list[str] = []
        for pkg in packages:
            try:
                importlib.metadata.version(pkg)
            except importlib.metadata.PackageNotFoundError:
                missing.append(pkg)
        if not missing:
            return Check(
                name="dependencies installed",
                severity=Severity.ok,
                detail=f"{len(packages)} packages",
                message="",
            )
        return Check(
            name="dependencies installed",
            severity=Severity.error,
            detail=", ".join(missing),
            message="필수 패키지가 설치돼 있지 않습니다. 다음 체크들이 연쇄 실패할 수 있습니다.",
            hint="uv sync 또는 pip install -r requirements.txt",
        )

    _check.__name__ = "check_dependencies_installed"
    return _check
