"""Discord Sidecar Doctor — 실행 전 건강 점검.

사용법::

    python -m src doctor           # 사람용 출력
    python -m src doctor --json    # 자동화용 JSON
    python -m src doctor --fix     # 가능한 부분은 자동 치유

등록된 체크 목록은 ``run_doctor`` 의 ``register`` 호출이 SSOT.
"""

from __future__ import annotations

import importlib.metadata
import json
import os
import sys
from pathlib import Path

_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

import httpx  # noqa: E402
from pydantic import ValidationError  # noqa: E402

from gate_shared import AutoFix, Check, Doctor, Severity  # noqa: E402
from gate_shared.doctor import NETWORK_TIMEOUT_SEC  # noqa: E402

from .config import BotConfig, get_config  # noqa: E402


async def run_doctor() -> Doctor:
    """체크들을 등록한 Doctor 인스턴스를 돌려준다."""

    doc = Doctor("Discord Sidecar Doctor")
    doc.register(check_python_version)
    doc.register(check_discord_py_version)
    doc.register(check_env_token)
    doc.register(check_env_gate_url)
    doc.register(check_env_api_token)
    doc.register(check_admin_role_id)
    doc.register(check_keeper_map_parses)
    doc.register(check_gate_reachable)
    doc.register(check_keeper_map_alignment)
    doc.register(check_binding_paths_writable)
    doc.register(check_legacy_runtime_paths)
    return doc


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------


async def check_python_version() -> Check:
    major, minor = sys.version_info[:2]
    ver = f"{major}.{minor}.{sys.version_info[2]}"
    if (major, minor) < (3, 11):
        return Check(
            name="python >= 3.11",
            severity=Severity.error,
            message=f"Python {ver} is too old; discord.py 2.4 requires 3.11+",
            detail=ver,
            hint="uv venv --python 3.11 하거나 pyenv 로 3.11 활성화",
        )
    return Check(name="python >= 3.11", severity=Severity.ok, detail=ver, message="")


async def check_discord_py_version() -> Check:
    try:
        ver = importlib.metadata.version("discord.py")
    except importlib.metadata.PackageNotFoundError:
        return Check(
            name="discord.py installed",
            severity=Severity.error,
            message="discord.py 가 설치되어 있지 않습니다.",
            hint="uv sync 또는 pip install -e .",
        )
    parts = ver.split(".")
    try:
        major, minor = int(parts[0]), int(parts[1])
    except (IndexError, ValueError):
        return Check(
            name="discord.py installed",
            severity=Severity.info,
            detail=ver,
            message="버전 문자열을 파싱할 수 없어 호환성 판단을 건너뜀",
        )
    if (major, minor) < (2, 4):
        return Check(
            name="discord.py installed",
            severity=Severity.warn,
            detail=ver,
            message="discord.py 2.4 이상을 권장합니다.",
            hint="uv sync --upgrade",
        )
    return Check(
        name="discord.py installed",
        severity=Severity.ok,
        detail=ver,
        message="",
    )


def _config_or_none() -> BotConfig | None:
    try:
        return get_config()
    except (ValidationError, OSError):
        return None


async def check_env_token() -> Check:
    raw = os.getenv("DISCORD_BOT_TOKEN", "").strip()
    if not raw:
        return Check(
            name="DISCORD_BOT_TOKEN",
            severity=Severity.error,
            message="Discord 봇 토큰이 설정되지 않았습니다.",
            hint="Discord Developer Portal → Bot → Reset Token 으로 발급 후 env 에 기록",
            auto_fix=AutoFix(
                description="`.env` 에 DISCORD_BOT_TOKEN=... 추가",
                command='echo "DISCORD_BOT_TOKEN=<token>" >> .env',
            ),
        )
    # Discord 토큰은 보통 59+ 문자. 노출은 피함.
    masked = raw[:4] + "…" + raw[-4:] if len(raw) > 10 else "(too short)"
    if len(raw) < 40:
        return Check(
            name="DISCORD_BOT_TOKEN",
            severity=Severity.warn,
            detail=masked,
            message="토큰 길이가 예상보다 짧습니다. 만료 또는 오타를 의심하세요.",
        )
    return Check(name="DISCORD_BOT_TOKEN", severity=Severity.ok, detail=masked, message="")


async def check_env_gate_url() -> Check:
    raw = os.getenv("GATE_BASE_URL", "").strip() or "http://localhost:8935"
    return Check(
        name="GATE_BASE_URL",
        severity=Severity.ok,
        detail=raw,
        message="",
    )


async def check_env_api_token() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="GATE_API_TOKEN policy",
            severity=Severity.skip,
            message="config 로드 실패로 규칙 검증을 건너뜀",
        )
    if cfg.gate_api_token:
        return Check(
            name="GATE_API_TOKEN policy",
            severity=Severity.ok,
            detail="token set",
            message="",
        )
    if cfg.gate_base_url_is_loopback():
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
        hint="MASC 서버 측 gate_api_token 과 동일한 값을 설정",
    )


async def check_admin_role_id() -> Check:
    raw = os.getenv("DISCORD_ADMIN_ROLE_ID", "").strip()
    if raw:
        return Check(
            name="DISCORD_ADMIN_ROLE_ID",
            severity=Severity.ok,
            detail=raw,
            message="",
        )
    return Check(
        name="DISCORD_ADMIN_ROLE_ID",
        severity=Severity.warn,
        message="admin role 이 비어 있어 Discord 쪽 바인딩 명령 권한이 누구에게나 열립니다.",
        hint="서버에서 역할을 만들고 ID 를 복사해 env 에 기록",
    )


async def check_keeper_map_parses() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="DISCORD_KEEPER_MAP parses",
            severity=Severity.skip,
            message="config 로드 실패로 검증 건너뜀",
        )
    try:
        parsed = cfg.keeper_map()
    except json.JSONDecodeError as exc:
        return Check(
            name="DISCORD_KEEPER_MAP parses",
            severity=Severity.error,
            message=f"JSON 파싱 실패: {exc}",
            hint='형식 예: {"123456789012345678":"keeper_name"}',
        )
    if not parsed:
        return Check(
            name="DISCORD_KEEPER_MAP parses",
            severity=Severity.warn,
            detail="empty map",
            message="채널↔키퍼 바인딩이 비어 있습니다. 대시보드 또는 API 로 추가하세요.",
            hint="POST /api/v1/gate/connector/bind?name=discord",
        )
    return Check(
        name="DISCORD_KEEPER_MAP parses",
        severity=Severity.ok,
        detail=f"{len(parsed)} binding(s)",
        message="",
    )


async def check_gate_reachable() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="gate reachable",
            severity=Severity.skip,
            message="config 로드 실패로 검증 건너뜀",
        )
    url = cfg.gate_health_url()
    try:
        async with httpx.AsyncClient(timeout=NETWORK_TIMEOUT_SEC) as client:
            resp = await client.get(url)
    except httpx.ConnectError as exc:
        return Check(
            name="gate reachable",
            severity=Severity.error,
            detail=url,
            message=f"연결 실패: {exc}",
            hint="MASC 서버가 기동되어 있는지 확인 (./start-masc-mcp.sh)",
        )
    except httpx.HTTPError as exc:
        return Check(
            name="gate reachable",
            severity=Severity.warn,
            detail=url,
            message=f"HTTP 오류: {exc}",
        )
    if resp.status_code >= 500:
        return Check(
            name="gate reachable",
            severity=Severity.error,
            detail=f"{url} → {resp.status_code}",
            message="서버가 응답하지만 내부 오류 상태입니다.",
        )
    if resp.status_code >= 400:
        return Check(
            name="gate reachable",
            severity=Severity.warn,
            detail=f"{url} → {resp.status_code}",
            message="인증 또는 경로 문제일 수 있습니다.",
        )
    return Check(
        name="gate reachable",
        severity=Severity.ok,
        detail=f"{url} → {resp.status_code}",
        message="",
    )


async def check_keeper_map_alignment() -> Check:
    """DISCORD_KEEPER_MAP 에 적힌 키퍼 이름이 실제 gate 의 keepers 목록에 있는지."""

    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="keeper names exist",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    keepers_expected = set(cfg.keeper_map().values())
    if not keepers_expected:
        return Check(
            name="keeper names exist",
            severity=Severity.skip,
            message="바인딩이 비어 있어 정렬 확인을 건너뜀",
        )
    base = cfg.gate_base_url.rstrip("/")
    url = f"{base}/api/v1/gate/keepers"
    try:
        async with httpx.AsyncClient(timeout=NETWORK_TIMEOUT_SEC) as client:
            resp = await client.get(
                url,
                headers={"Authorization": f"Bearer {cfg.gate_api_token}"}
                if cfg.gate_api_token
                else {},
            )
    except httpx.HTTPError as exc:
        return Check(
            name="keeper names exist",
            severity=Severity.warn,
            detail=url,
            message=f"keepers 목록을 가져오지 못했습니다: {exc}",
        )
    if resp.status_code >= 400:
        return Check(
            name="keeper names exist",
            severity=Severity.warn,
            detail=f"{resp.status_code}",
            message="keepers 엔드포인트가 오류 응답. 토큰/권한 확인 필요.",
        )
    try:
        body = resp.json()
        known = {str(k) for k in _extract_keeper_names(body)}
    except (json.JSONDecodeError, ValueError):
        return Check(
            name="keeper names exist",
            severity=Severity.warn,
            message="keepers 응답을 파싱하지 못했습니다.",
        )
    missing = sorted(keepers_expected - known)
    if missing:
        return Check(
            name="keeper names exist",
            severity=Severity.error,
            detail=", ".join(missing),
            message="KEEPER_MAP 에 적힌 대상이 서버에 등록돼 있지 않습니다.",
            hint="config/keepers/*.toml 또는 runtime 등록을 확인",
        )
    return Check(
        name="keeper names exist",
        severity=Severity.ok,
        detail=f"{len(keepers_expected)} bound / {len(known)} registered",
        message="",
    )


def _extract_keeper_names(body: object) -> list[str]:
    """gate /keepers 응답에서 이름 필드를 보수적으로 추출한다."""

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


async def check_binding_paths_writable() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="binding paths writable",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    candidates: list[tuple[str, Path]] = [
        ("binding store", cfg.binding_store_path()),
        ("binding audit", cfg.binding_audit_path()),
        ("status", cfg.status_path()),
        ("names", cfg.names_path()),
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
        # Auto-fix failure must be observable: silent pass makes the follow-up
        # rerun look identical to "fix didn't run" from the operator's side.
        for p in auto_fix_targets:
            try:
                p.chmod(0o755)
            except OSError as exc:
                print(
                    f"[doctor] chmod 0755 {p} failed: {exc.strerror or exc}",
                    file=sys.stderr,
                )

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


async def check_legacy_runtime_paths() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="legacy runtime paths",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    migrations = cfg.legacy_runtime_migrations()
    present: list[tuple[str, Path, Path]] = [
        m for m in migrations if m[1].exists()
    ]
    if not present:
        return Check(
            name="legacy runtime paths",
            severity=Severity.ok,
            detail="none",
            message="",
        )
    describe = ", ".join(f"{label}: {src} → {dst}" for label, src, dst in present)
    return Check(
        name="legacy runtime paths",
        severity=Severity.warn,
        detail=f"{len(present)} legacy file(s)",
        message=f"구 레이아웃 잔존: {describe}",
        hint="봇을 한 번 기동하면 자동 이관됩니다 (storage_migration.py)",
    )
