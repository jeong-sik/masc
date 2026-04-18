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

import json
import sys
from collections.abc import Awaitable, Callable, Iterable, Sequence
from dataclasses import dataclass, field
from enum import Enum
from typing import Final

__all__ = [
    "AutoFix",
    "Check",
    "CheckFn",
    "Doctor",
    "Severity",
    "render_pretty",
    "render_json",
]


class Severity(str, Enum):
    """체크 심각도.

    - ``ok``: 정상. 추가 조치 불필요.
    - ``info``: 참고용 정보. 동작에는 영향 없음.
    - ``warn``: 일부 기능이 비활성화되거나 권장 설정이 빠짐.
    - ``error``: 실행 자체가 불가능. 반드시 조치 필요.
    - ``skip``: 사전 조건이 충족되지 않아 검사를 건너뜀.
    """

    ok = "ok"
    info = "info"
    warn = "warn"
    error = "error"
    skip = "skip"


@dataclass(frozen=True, slots=True)
class AutoFix:
    """자동 치유 힌트.

    ``command`` 는 복사해서 실행할 수 있는 쉘 예시.
    ``callback`` 는 ``doctor --fix`` 시 실제로 호출되는 함수.
    둘 중 하나만 채우면 되며, 양쪽 모두 제공 시 ``callback`` 가 우선한다.
    """

    description: str
    command: str | None = None
    callback: Callable[[], Awaitable[None]] | None = None


@dataclass(frozen=True, slots=True)
class Check:
    """단일 진단 결과.

    ``detail`` 에는 사용자가 바로 참고할 수 있는 수치/경로를 담는다.
    예: 파일 크기, URL, PID, 버전.
    """

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
    """관례: 0 = 건강, 1 = 조치 필요, 2 = 실행 불가.

    - error 가 하나라도 있으면 2
    - warn 이 있고 error 는 없으면 1
    - 나머지는 0
    """

    counts = _tally(checks)
    if counts[Severity.error] > 0:
        return 2
    if counts[Severity.warn] > 0:
        return 1
    return 0


class Doctor:
    """체크 등록 → 실행 → 렌더링 오케스트레이터.

    사용 예::

        doctor = Doctor("Discord Sidecar Doctor")
        doctor.register(check_env)
        doctor.register(check_gate_reachable)
        checks = await doctor.run()
        print(render_pretty(doctor.title, checks))
    """

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
        """모든 체크를 순차 실행한다.

        체크 내부 예외는 ``Severity.error`` 로 승격된다.
        하나의 체크가 실패해도 나머지는 계속 실행된다.
        """

        results: list[Check] = []
        for fn in self._checks:
            try:
                results.append(await fn())
            except Exception as exc:  # 진단 도구 자체는 멈추면 안 된다.
                results.append(
                    Check(
                        name=getattr(fn, "__name__", "unknown_check"),
                        severity=Severity.error,
                        message=f"check raised: {exc.__class__.__name__}: {exc}",
                    )
                )
        return results

    async def run_auto_fixes(self, checks: Sequence[Check]) -> list[Check]:
        """auto_fix callback 이 있는 체크만 재실행용으로 처리한다.

        실제 호출 결과는 '후속 체크 1회 더 돌리기' 로 검증해야 정확하다.
        여기서는 callback 만 실행하고, 다시 ``run()`` 한 결과를 돌려준다.
        """

        for c in checks:
            if c.auto_fix is None or c.auto_fix.callback is None:
                continue
            if c.severity not in (Severity.warn, Severity.error):
                continue
            await c.auto_fix.callback()
        return await self.run()
