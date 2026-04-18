"""iMessage Sidecar Doctor — 기동 전 건강 점검 (macOS 전용).

iMessage 커넥터는 토큰을 쓰지 않는다. 대신 macOS 의 두 가지 권한에 의존한다:

1. **Full Disk Access (FDA)** — `~/Library/Messages/chat.db` 읽기
2. **Automation (Messages.app)** — `osascript` 로 메시지 전송

Doctor 는 이 두 권한이 실제로 살아있는지까지 한 번에 검증한다.
단순 존재 확인이 아니라 SQLite 열기 시도 / osascript 실행 시도로
"설정돼 있는 것처럼 보이지만 실제로 안 되는" 케이스를 잡아낸다.

사용법::

    python -m src doctor           # 사람용 출력
    python -m src doctor --json    # 자동화용 JSON
    python -m src doctor --fix     # 가능한 auto-fix 후 재점검
"""

from __future__ import annotations

import os
import platform
import shutil
import sqlite3
import subprocess
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
    doc = Doctor("iMessage Sidecar Doctor")
    doc.register(check_python_version)
    doc.register(check_macos_platform)
    doc.register(check_sqlite3_module)
    doc.register(check_chat_db_readable)
    doc.register(check_osascript_available)
    doc.register(check_env_gate_url)
    doc.register(check_env_api_token)
    doc.register(check_reply_mode_consistency)
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


async def check_macos_platform() -> Check:
    system = platform.system()
    if system != "Darwin":
        return Check(
            name="macOS host",
            severity=Severity.error,
            detail=system,
            message="iMessage 커넥터는 macOS (Darwin) 에서만 동작합니다.",
            hint="macOS 호스트에서만 이 sidecar 를 기동하세요.",
        )
    release = platform.mac_ver()[0] or "unknown"
    return Check(
        name="macOS host",
        severity=Severity.ok,
        detail=f"Darwin {release}",
        message="",
    )


async def check_sqlite3_module() -> Check:
    ver = sqlite3.sqlite_version
    return Check(
        name="sqlite3 module",
        severity=Severity.ok,
        detail=ver,
        message="",
    )


def _config_or_none() -> BotConfig | None:
    try:
        return get_config()
    except (ValidationError, OSError):
        return None


# --- FDA & chat.db -----------------------------------------------------------


async def check_chat_db_readable() -> Check:
    """FDA 권한이 실제로 살아있는지 SQLite open + SELECT 1 로 검증."""

    cfg = _config_or_none()
    path = Path(cfg.chat_db_path if cfg else "~/Library/Messages/chat.db").expanduser()
    if not path.exists():
        return Check(
            name="chat.db readable (FDA)",
            severity=Severity.error,
            detail=str(path),
            message="chat.db 를 찾을 수 없습니다.",
            hint="Messages.app 을 한 번 실행해서 chat.db 가 생성되게 하세요.",
        )
    if not os.access(path, os.R_OK):
        return Check(
            name="chat.db readable (FDA)",
            severity=Severity.error,
            detail=str(path),
            message="파일은 있지만 읽기 권한이 없습니다.",
            hint=_fda_hint(),
        )
    # 진짜 FDA 가 통과했는지는 open + query 로만 확실하게 알 수 있다.
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1.0)
        try:
            conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
        finally:
            conn.close()
    except sqlite3.OperationalError as exc:
        return Check(
            name="chat.db readable (FDA)",
            severity=Severity.error,
            detail=str(path),
            message=f"SQLite open 실패: {exc}",
            hint=_fda_hint(),
        )
    size = path.stat().st_size
    size_mb = size / (1024 * 1024)
    return Check(
        name="chat.db readable (FDA)",
        severity=Severity.ok,
        detail=f"{path.name} ({size_mb:.1f} MiB)",
        message="",
    )


def _fda_hint() -> str:
    return (
        "System Settings → Privacy & Security → Full Disk Access → "
        "현재 터미널(또는 sidecar 를 실행하는 프로세스) 에 권한 부여"
    )


# --- osascript (Messages.app Automation) -------------------------------------


async def check_osascript_available() -> Check:
    """osascript 가 설치돼 있고 Messages.app Automation 권한이 있는지."""

    path = shutil.which("osascript")
    if not path:
        return Check(
            name="osascript available",
            severity=Severity.error,
            message="osascript 바이너리가 없습니다 (macOS 필수 도구).",
        )
    # Messages Automation 실제 권한은 send 시도가 있어야 확인 가능하지만,
    # 소극적으로 Messages.app 번들 존재 + osascript 로 tell application 호출이
    # Automation 권한 프롬프트를 띄우는지 문법만 체크.
    try:
        result = subprocess.run(
            [path, "-e", 'tell application "Messages" to name'],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        return Check(
            name="osascript available",
            severity=Severity.warn,
            detail=path,
            message="osascript 호출이 5초 안에 끝나지 않았습니다 (권한 프롬프트 대기 가능).",
            hint="시스템 설정에서 Messages Automation 권한을 승인한 뒤 다시 실행.",
        )
    except OSError as exc:
        return Check(
            name="osascript available",
            severity=Severity.warn,
            detail=path,
            message=f"osascript 실행 실패: {exc}",
        )
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        if "not allowed" in stderr.lower() or "1743" in stderr:
            return Check(
                name="osascript available",
                severity=Severity.error,
                detail=path,
                message="Messages.app Automation 권한이 거부됐습니다.",
                hint=(
                    "System Settings → Privacy & Security → Automation → "
                    "현재 터미널이 Messages 를 제어할 수 있도록 체크"
                ),
            )
        return Check(
            name="osascript available",
            severity=Severity.warn,
            detail=path,
            message=f"osascript 가 비정상 종료 (rc={result.returncode}): {stderr}",
        )
    return Check(
        name="osascript available",
        severity=Severity.ok,
        detail=path,
        message="",
    )


# --- gate + env --------------------------------------------------------------


async def check_env_gate_url() -> Check:
    raw = os.getenv("MASC_GATE_URL", "").strip() or os.getenv("GATE_BASE_URL", "").strip() or "http://127.0.0.1:8935"
    return Check(name="MASC_GATE_URL", severity=Severity.ok, detail=raw, message="")


async def check_env_api_token() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="MASC_GATE_API_TOKEN policy",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    if cfg.gate_api_token:
        return Check(
            name="MASC_GATE_API_TOKEN policy",
            severity=Severity.ok,
            detail="token set",
            message="",
        )
    if cfg.is_loopback():
        return Check(
            name="MASC_GATE_API_TOKEN policy",
            severity=Severity.info,
            detail="loopback gate",
            message="loopback 대상이므로 토큰 없이 통신이 허용됩니다.",
        )
    return Check(
        name="MASC_GATE_API_TOKEN policy",
        severity=Severity.error,
        message="비-loopback gate 에 접근하려면 MASC_GATE_API_TOKEN 이 필요합니다.",
        hint="MASC 서버의 gate_api_token 과 동일한 값을 설정",
    )


async def check_reply_mode_consistency() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="reply_mode consistency",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    if cfg.reply_mode == "self-chat" and not cfg.self_chat_guid:
        return Check(
            name="reply_mode consistency",
            severity=Severity.warn,
            detail="reply_mode=self-chat, self_chat_guid=''",
            message="self-chat 모드지만 IMESSAGE_SELF_CHAT_GUID 가 비어 있습니다.",
            hint="Messages.app 의 자기 자신 대화방 guid 를 지정하면 대화방 자동 탐색 없이 안정적으로 동작합니다.",
        )
    return Check(
        name="reply_mode consistency",
        severity=Severity.ok,
        detail=cfg.reply_mode,
        message="",
    )


async def check_gate_reachable() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="gate reachable",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    url = cfg.gate_health_url()
    headers = {"Authorization": f"Bearer {cfg.gate_api_token}"} if cfg.gate_api_token else {}
    try:
        async with httpx.AsyncClient(timeout=NETWORK_TIMEOUT_SEC) as client:
            res = await client.get(url, headers=headers)
    except httpx.ConnectError as exc:
        return Check(
            name="gate reachable",
            severity=Severity.error,
            detail=url,
            message=f"연결 실패: {exc}",
            hint="MASC 서버 기동 여부 확인 (./start-masc-mcp.sh)",
        )
    except httpx.HTTPError as exc:
        return Check(
            name="gate reachable",
            severity=Severity.warn,
            detail=url,
            message=f"HTTP 오류: {exc}",
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


# --- filesystem --------------------------------------------------------------


def _resolve_state_path(raw: str) -> Path:
    p = Path(raw).expanduser()
    if p.is_absolute():
        return p
    base = os.getenv("MASC_BASE_PATH", "").strip()
    return Path(base).expanduser() / p if base else Path.cwd() / p


async def check_binding_paths_writable() -> Check:
    cfg = _config_or_none()
    if cfg is None:
        return Check(
            name="binding paths writable",
            severity=Severity.skip,
            message="config 로드 실패로 건너뜀",
        )
    candidates = [
        ("binding store", _resolve_state_path(cfg.binding_store_path)),
        ("binding audit", _resolve_state_path(cfg.binding_audit_path)),
        ("status", _resolve_state_path(cfg.status_path)),
        ("cursor", _resolve_state_path(cfg.cursor_path)),
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
    legacy = _resolve_state_path(cfg.legacy_binding_store_path)
    if legacy.exists():
        return Check(
            name="legacy binding path",
            severity=Severity.warn,
            detail=str(legacy),
            message="pre-v0.9.0 binding store 가 남아 있습니다.",
            hint="봇을 기동하면 다음 save 시 신 포맷으로 이관됩니다.",
        )
    return Check(name="legacy binding path", severity=Severity.ok, detail="none", message="")
