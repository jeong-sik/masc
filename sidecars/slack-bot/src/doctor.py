"""Slack Sidecar Doctor — 기동 전 건강 점검.

사용법::

    python -m src doctor           # 사람용 출력
    python -m src doctor --json    # 자동화용 JSON
    python -m src doctor --fix     # 가능한 auto-fix 수행 후 재점검

체크 목록은 ``run_doctor`` 의 ``register`` 호출이 SSOT.
"""

from __future__ import annotations

import importlib.metadata
import os
import sys
from pathlib import Path
from typing import TYPE_CHECKING

_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

# httpx is required for the doctor itself. pydantic_settings / slack_bolt
# are NOT imported at module top so the doctor can still run and report
# them as missing instead of crashing before any check executes.
import httpx  # noqa: E402

from gate_shared import AutoFix, Check, Doctor, Severity  # noqa: E402
from gate_shared.doctor import (  # noqa: E402
    NETWORK_TIMEOUT_SEC,
    check_dependencies_installed,
)

if TYPE_CHECKING:
    from .config import BotConfig


_REQUIRED_PACKAGES = (
    "slack-bolt",
    "slack-sdk",
    "pydantic",
    "pydantic-settings",
    "httpx",
    "httpx-sse",
)


async def run_doctor() -> Doctor:
    doc = Doctor("Slack Sidecar Doctor")
    doc.register(check_python_version)
    doc.register(check_dependencies_installed(_REQUIRED_PACKAGES))
    doc.register(check_slack_bolt_version)
    doc.register(check_bot_token)
    doc.register(check_app_token)
    doc.register(check_env_gate_url)
    doc.register(check_env_api_token)
    doc.register(check_default_keeper_exists)
    doc.register(check_gate_reachable)
    doc.register(check_binding_paths_writable)
    doc.register(check_legacy_binding_path)
    return doc


# --- runtime -----------------------------------------------------------------


async def check_python_version() -> Check:
    major, minor = sys.version_info[:2]
    ver = f"{major}.{minor}.{sys.version_info[2]}"
    if (major, minor) < (3, 11):
        return Check(
            name="python >= 3.11",
            severity=Severity.error,
            detail=ver,
            message="Python 3.11 이상을 요구합니다.",
            hint="uv venv --python 3.11 또는 pyenv 로 3.11 활성화",
        )
    return Check(name="python >= 3.11", severity=Severity.ok, detail=ver, message="")


async def check_slack_bolt_version() -> Check:
    try:
        ver = importlib.metadata.version("slack-bolt")
    except importlib.metadata.PackageNotFoundError:
        return Check(
            name="slack-bolt installed",
            severity=Severity.error,
            message="slack-bolt 미설치.",
            hint="pip install -r requirements.txt",
        )
    return Check(name="slack-bolt installed", severity=Severity.ok, detail=ver, message="")


def _config_or_none() -> BotConfig | None:
    """Lazy config load — survives missing pydantic_settings."""

    try:
        from pydantic import ValidationError  # noqa: PLC0415

        from .config import get_config  # noqa: PLC0415
    except ImportError:
        return None
    try:
        return get_config()
    except (ValidationError, OSError):
        return None


def _mask(raw: str) -> str:
    return raw[:4] + "…" + raw[-4:] if len(raw) > 10 else "(too short)"


# --- tokens ------------------------------------------------------------------


async def check_bot_token() -> Check:
    raw = os.getenv("SLACK_BOT_TOKEN", "").strip()
    if not raw:
        return Check(
            name="SLACK_BOT_TOKEN",
            severity=Severity.error,
            message="Slack Bot Token 이 설정되지 않았습니다.",
            hint="Slack App → Install App → Bot User OAuth Token 복사 (xoxb- 로 시작)",
        )
    if not raw.startswith("xoxb-"):
        return Check(
            name="SLACK_BOT_TOKEN",
            severity=Severity.warn,
            detail=_mask(raw),
            message="토큰이 xoxb- 로 시작하지 않습니다. Bot Token 이 맞는지 확인하세요.",
        )
    return Check(name="SLACK_BOT_TOKEN", severity=Severity.ok, detail=_mask(raw), message="")


async def check_app_token() -> Check:
    raw = os.getenv("SLACK_APP_TOKEN", "").strip()
    if not raw:
        return Check(
            name="SLACK_APP_TOKEN",
            severity=Severity.error,
            message="Socket Mode 에 필요한 App-Level Token 이 없습니다.",
            hint="Slack App → Basic Info → App-Level Tokens → Generate (scope: connections:write, xapp- 로 시작)",
        )
    if not raw.startswith("xapp-"):
        return Check(
            name="SLACK_APP_TOKEN",
            severity=Severity.warn,
            detail=_mask(raw),
            message="토큰이 xapp- 로 시작하지 않습니다. App-Level Token 이 맞는지 확인하세요.",
        )
    return Check(name="SLACK_APP_TOKEN", severity=Severity.ok, detail=_mask(raw), message="")


# --- gate --------------------------------------------------------------------


async def check_env_gate_url() -> Check:
    raw = os.getenv("GATE_BASE_URL", "").strip() or "http://localhost:8935"
    return Check(name="GATE_BASE_URL", severity=Severity.ok, detail=raw, message="")


async def check_env_api_token() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="GATE_API_TOKEN policy",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    if cfg.gate_api_token:
        return Check(name="GATE_API_TOKEN policy", severity=Severity.ok, detail="token set", message="")
    if cfg._gate_is_loopback():
        return Check(
            name="GATE_API_TOKEN policy",
            severity=Severity.info,
            detail="loopback gate",
            message="loopback 대상이므로 토큰 없이 통신이 허용됩니다.",
        )
    return Check(
        name="GATE_API_TOKEN policy",
        severity=Severity.error,
        message="비-loopback gate 에 접근하려면 GATE_API_TOKEN 이 필요합니다.",
        hint="MASC 서버의 gate_api_token 과 동일한 값을 설정",
    )


async def _gate_get(path: str) -> tuple[str, httpx.Response | str]:
    """Returns (url, response_or_error_string)."""

    cfg = _config_or_none()
    if cfg is None:
        return ("", "config load failed")
    base = cfg.gate_base_url.rstrip("/")
    url = f"{base}{path}"
    headers = {"Authorization": f"Bearer {cfg.gate_api_token}"} if cfg.gate_api_token else {}
    try:
        async with httpx.AsyncClient(timeout=NETWORK_TIMEOUT_SEC) as client:
            return (url, await client.get(url, headers=headers))
    except httpx.ConnectError as exc:
        return (url, f"connect failed: {exc}")
    except httpx.HTTPError as exc:
        return (url, f"http error: {exc}")


async def check_gate_reachable() -> Check:
    url, res = await _gate_get("/api/v1/gate/health")
    if isinstance(res, str):
        return Check(
            name="gate reachable",
            severity=Severity.error if "connect" in res else Severity.warn,
            detail=url or "(no config)",
            message=res,
            hint="MASC 서버 기동 여부 확인 (./start-masc-mcp.sh)",
        )
    if res.status_code >= 500:
        return Check(
            name="gate reachable",
            severity=Severity.error,
            detail=f"{url} → {res.status_code}",
            message="서버는 응답하지만 내부 오류 상태.",
        )
    if res.status_code >= 400:
        return Check(
            name="gate reachable",
            severity=Severity.warn,
            detail=f"{url} → {res.status_code}",
            message="인증 또는 경로 문제일 수 있음.",
        )
    return Check(name="gate reachable", severity=Severity.ok, detail=f"{url} → {res.status_code}", message="")


async def check_default_keeper_exists() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(name="default_keeper exists", severity=Severity.skip, message="config 로드 실패로 건너뜀")
    url, res = await _gate_get("/api/v1/gate/keepers")
    if isinstance(res, str):
        return Check(
            name="default_keeper exists",
            severity=Severity.warn,
            detail=url or "(no config)",
            message=f"keepers 목록 조회 실패: {res}",
        )
    if res.status_code >= 400:
        return Check(
            name="default_keeper exists",
            severity=Severity.warn,
            detail=f"{res.status_code}",
            message="keepers 엔드포인트 오류 응답. 토큰/권한 확인.",
        )
    try:
        body = res.json()
    except ValueError:
        return Check(
            name="default_keeper exists",
            severity=Severity.warn,
            message="keepers 응답 파싱 실패",
        )
    names = _extract_keeper_names(body)
    if cfg.default_keeper not in names:
        return Check(
            name="default_keeper exists",
            severity=Severity.error,
            detail=cfg.default_keeper,
            message=f"SLACK_DEFAULT_KEEPER='{cfg.default_keeper}' 가 서버에 등록돼 있지 않습니다.",
            hint="config/keepers/*.toml 또는 runtime 등록 확인",
        )
    return Check(
        name="default_keeper exists",
        severity=Severity.ok,
        detail=f"{cfg.default_keeper} (of {len(names)} registered)",
        message="",
    )


def _extract_keeper_names(body: object) -> list[str]:
    if isinstance(body, list):
        names: list[str] = []
        for item in body:  # type: ignore[assignment]
            if isinstance(item, dict) and "name" in item:
                name = item.get("name")  # type: ignore[assignment]
                if isinstance(name, str):
                    names.append(name)
            elif isinstance(item, str):
                names.append(item)
        return names
    if isinstance(body, dict):
        items = body.get("keepers")  # type: ignore[assignment]
        if isinstance(items, list):
            return _extract_keeper_names(items)
    return []


# --- filesystem --------------------------------------------------------------


async def check_binding_paths_writable() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(name="binding paths writable", severity=Severity.skip, message="config 로드 실패로 건너뜀")

    def _resolve(raw: str) -> Path:
        p = Path(raw).expanduser()
        if p.is_absolute():
            return p
        base = os.getenv("MASC_BASE_PATH", "").strip()
        return Path(base).expanduser() / p if base else Path.cwd() / p

    candidates = [
        ("binding store", _resolve(cfg.binding_store_path)),
        ("status", _resolve(cfg.status_path)),
    ]
    unwritable: list[str] = []
    auto_fix_targets: list[Path] = []
    for label, path in candidates:
        parent = path.parent
        try:
            parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            unwritable.append(f"{label}: {parent} ({exc.strerror or exc})")
            continue
        if not os.access(parent, os.W_OK):
            unwritable.append(f"{label}: {parent} (permission denied)")
            auto_fix_targets.append(parent)

    if not unwritable:
        return Check(
            name="binding paths writable",
            severity=Severity.ok,
            detail=f"{len(candidates)} paths",
            message="",
        )

    async def _attempt_chmod() -> None:
        for p in auto_fix_targets:
            try:
                p.chmod(0o755)
            except OSError as exc:
                print(f"[doctor] chmod 0755 {p} failed: {exc.strerror or exc}", file=sys.stderr)

    return Check(
        name="binding paths writable",
        severity=Severity.error,
        message="; ".join(unwritable),
        hint="상위 디렉터리 권한을 확인하거나 경로를 명시적으로 설정",
        auto_fix=AutoFix(
            description="접근 권한이 없는 상위 디렉터리에 0755 시도",
            callback=_attempt_chmod if auto_fix_targets else None,
        ),
    )


async def check_legacy_binding_path() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(name="legacy binding path", severity=Severity.skip, message="config 로드 실패로 건너뜀")
    base = os.getenv("MASC_BASE_PATH", "").strip()
    legacy_raw = cfg.legacy_binding_store_path
    p = Path(legacy_raw).expanduser()
    legacy = p if p.is_absolute() else (Path(base).expanduser() / p if base else Path.cwd() / p)
    if legacy.exists():
        return Check(
            name="legacy binding path",
            severity=Severity.warn,
            detail=str(legacy),
            message="pre-v0.9.0 binding store 가 남아 있습니다.",
            hint="봇을 기동하면 다음 save 시 신 포맷으로 이관됩니다.",
        )
    return Check(name="legacy binding path", severity=Severity.ok, detail="none", message="")
