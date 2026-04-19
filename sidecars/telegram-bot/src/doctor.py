"""Telegram Sidecar Doctor — 기동 전 건강 점검.

사용법::

    python -m src doctor           # 사람용 출력
    python -m src doctor --json    # 자동화용 JSON
    python -m src doctor --fix     # 가능한 auto-fix 수행 후 재점검

체크 목록은 ``run_doctor`` 의 ``register`` 호출이 SSOT.
"""

from __future__ import annotations

import importlib.metadata
import os
import re
import sys
from pathlib import Path
from typing import TYPE_CHECKING

_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

# httpx is required for the doctor itself. pydantic_settings and
# python-telegram-bot are NOT imported at module top so the doctor can
# still run and report them as missing instead of crashing.
import httpx  # noqa: E402

from gate_shared import AutoFix, Check, Doctor, Severity  # noqa: E402
from gate_shared.doctor import (  # noqa: E402
    NETWORK_TIMEOUT_SEC,
    check_dependencies_installed,
)

if TYPE_CHECKING:
    from .config import BotConfig

# Telegram 봇 토큰은 `<digits>:<base64url-ish>` 규약. BotFather 가 발급하는 포맷.
_TG_TOKEN_RE = re.compile(r"^\d{6,}:[A-Za-z0-9_-]{30,}$")

_REQUIRED_PACKAGES = (
    "python-telegram-bot",
    "pydantic",
    "pydantic-settings",
    "httpx",
    "httpx-sse",
)


def _config_or_none() -> BotConfig | None:
    try:
        from pydantic import ValidationError  # noqa: PLC0415

        from .config import get_config  # noqa: PLC0415
    except ImportError:
        return None
    try:
        return get_config()
    except (ValidationError, OSError):
        return None


async def run_doctor() -> Doctor:
    doc = Doctor("Telegram Sidecar Doctor")
    doc.register(check_python_version)
    doc.register(check_dependencies_installed(_REQUIRED_PACKAGES))
    doc.register(check_telegram_lib_version)
    doc.register(check_bot_token)
    doc.register(check_env_gate_url)
    doc.register(check_env_api_token)
    doc.register(check_admin_user_ids)
    doc.register(check_default_keeper_exists)
    doc.register(check_gate_reachable)
    doc.register(check_telegram_api_reachable)
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


async def check_telegram_lib_version() -> Check:
    for pkg in ("python-telegram-bot", "telegram"):
        try:
            ver = importlib.metadata.version(pkg)
            return Check(name=f"{pkg} installed", severity=Severity.ok, detail=ver, message="")
        except importlib.metadata.PackageNotFoundError:
            continue
    return Check(
        name="python-telegram-bot installed",
        severity=Severity.error,
        message="python-telegram-bot 미설치.",
        hint="pip install -r requirements.txt",
    )


def _mask(raw: str) -> str:
    return raw[:4] + "…" + raw[-4:] if len(raw) > 10 else "(too short)"


# --- tokens ------------------------------------------------------------------


async def check_bot_token() -> Check:
    raw = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    if not raw:
        return Check(
            name="TELEGRAM_BOT_TOKEN",
            severity=Severity.error,
            message="Telegram Bot Token 이 설정되지 않았습니다.",
            hint="Telegram @BotFather 에서 /newbot 또는 /token 으로 발급",
        )
    if not _TG_TOKEN_RE.match(raw):
        return Check(
            name="TELEGRAM_BOT_TOKEN",
            severity=Severity.warn,
            detail=_mask(raw),
            message="토큰 형식이 '<digits>:<alphanumeric>' 규약과 다릅니다.",
            hint="BotFather 가 발급한 원본 토큰을 그대로 복사했는지 확인",
        )
    return Check(name="TELEGRAM_BOT_TOKEN", severity=Severity.ok, detail=_mask(raw), message="")


# --- gate + env --------------------------------------------------------------


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


async def check_admin_user_ids() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="TELEGRAM_ADMIN_USER_IDS",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    ids = cfg.admin_ids()
    raw = cfg.admin_user_ids.strip()
    if not raw:
        return Check(
            name="TELEGRAM_ADMIN_USER_IDS",
            severity=Severity.warn,
            message="admin 이 비어 있어 바인딩 명령 권한이 누구에게나 열립니다.",
            hint="Telegram 에서 @userinfobot 으로 본인 user ID 확인 후 쉼표로 구분해 기록",
        )
    # 파싱 손실 감지 — CSV 에 숫자 아닌 토큰이 섞인 경우
    tokens = [t.strip() for t in raw.split(",") if t.strip()]
    parsed_count = len(ids)
    if parsed_count < len(tokens):
        return Check(
            name="TELEGRAM_ADMIN_USER_IDS",
            severity=Severity.warn,
            detail=f"{parsed_count}/{len(tokens)} parsed",
            message="일부 항목이 숫자가 아니라 무시되었습니다.",
            hint="Telegram user ID 는 양의 정수. 공백과 쉼표 이외의 문자를 제거",
        )
    return Check(
        name="TELEGRAM_ADMIN_USER_IDS",
        severity=Severity.ok,
        detail=f"{parsed_count} admin(s)",
        message="",
    )


async def _gate_get(path: str) -> tuple[str, httpx.Response | str]:
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


async def check_telegram_api_reachable() -> Check:
    """Telegram 은 자체 API 로 토큰 유효성을 getMe 로 확인할 수 있다."""

    raw = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    if not raw or not _TG_TOKEN_RE.match(raw):
        return Check(
            name="Telegram API getMe",
            severity=Severity.skip,
            message="토큰이 없거나 형식 오류로 API 호출 생략",
        )
    url = f"https://api.telegram.org/bot{raw}/getMe"
    try:
        async with httpx.AsyncClient(timeout=NETWORK_TIMEOUT_SEC) as client:
            res = await client.get(url)
    except httpx.HTTPError as exc:
        return Check(
            name="Telegram API getMe",
            severity=Severity.warn,
            detail="api.telegram.org",
            message=f"연결 실패: {exc}",
            hint="네트워크 / 방화벽 / VPN 상태 확인",
        )
    if res.status_code == 401:
        return Check(
            name="Telegram API getMe",
            severity=Severity.error,
            detail="401",
            message="Telegram 이 토큰을 거절했습니다. 만료/재발급/오타 의심.",
            hint="BotFather /revoke 후 새 토큰 발급",
        )
    if res.status_code >= 400:
        return Check(
            name="Telegram API getMe",
            severity=Severity.warn,
            detail=str(res.status_code),
            message="Telegram API 가 비정상 응답을 반환했습니다.",
        )
    try:
        body = res.json()
    except ValueError:
        return Check(
            name="Telegram API getMe",
            severity=Severity.warn,
            message="getMe 응답을 파싱할 수 없습니다.",
        )
    if not isinstance(body, dict) or not body.get("ok"):
        return Check(
            name="Telegram API getMe",
            severity=Severity.warn,
            message="getMe ok=false",
            detail=str(body),
        )
    result = body.get("result") if isinstance(body, dict) else None
    username = result.get("username") if isinstance(result, dict) else None
    return Check(
        name="Telegram API getMe",
        severity=Severity.ok,
        detail=f"@{username}" if username else "ok",
        message="",
    )


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
            detail=str(res.status_code),
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
            message=f"TELEGRAM_DEFAULT_KEEPER='{cfg.default_keeper}' 가 서버에 등록돼 있지 않습니다.",
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
