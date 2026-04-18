"""CLI connector Doctor — 대화형 모드 사전 점검.

CLI connector 는 다른 sidecar 와 달리 **stateless** 다. 바인딩도, 상태 파일도,
토큰도 없다. 따라서 doctor 는 짧다. 대신 다른 sidecar 가 가정하는 "지속적
서비스" 대신 "**사람이 즉시 쓰는 터미널 도구**" 의 관점에서 본다:

- stdin 이 TTY 인가? (파이프 환경에서 interactive loop 는 헛돈다)
- keepers 목록이 비어있지 않은가? (빈 목록 = 서버가 아직 keeper 를 안 띄운 상태)
- default keeper 가 실제로 존재하는가?

사용법::

    python -m src doctor          # 사람용 출력
    python -m src doctor --json   # 자동화용 JSON
"""

from __future__ import annotations

import importlib.metadata
import os
import sys
from pathlib import Path

_shared_root = Path(__file__).resolve().parent.parent.parent / "shared"
if str(_shared_root) not in sys.path:
    sys.path.insert(0, str(_shared_root))

import httpx  # noqa: E402

from gate_shared import Check, Doctor, Severity  # noqa: E402
from gate_shared.doctor import (  # noqa: E402
    NETWORK_TIMEOUT_SEC,
    check_dependencies_installed,
)

_REQUIRED_PACKAGES = ("httpx",)


async def run_doctor() -> Doctor:
    doc = Doctor("CLI Connector Doctor")
    doc.register(check_python_version)
    doc.register(check_dependencies_installed(_REQUIRED_PACKAGES))
    doc.register(check_httpx_installed)
    doc.register(check_stdin_is_tty)
    doc.register(check_env_gate_url)
    doc.register(check_gate_reachable)
    doc.register(check_keepers_available)
    doc.register(check_default_keeper_exists)
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
        )
    return Check(name="python >= 3.11", severity=Severity.ok, detail=ver, message="")


async def check_httpx_installed() -> Check:
    try:
        ver = importlib.metadata.version("httpx")
    except importlib.metadata.PackageNotFoundError:
        return Check(
            name="httpx installed",
            severity=Severity.error,
            message="httpx 미설치.",
            hint="pip install -r requirements.txt",
        )
    return Check(name="httpx installed", severity=Severity.ok, detail=ver, message="")


async def check_stdin_is_tty() -> Check:
    """파이프/redirect 로 들어오면 interactive loop 는 헛돈다."""

    if sys.stdin.isatty():
        return Check(name="stdin is TTY", severity=Severity.ok, detail="tty", message="")
    return Check(
        name="stdin is TTY",
        severity=Severity.warn,
        detail="not a TTY",
        message="stdin 이 파이프/리다이렉트 입니다. interactive loop 대신 one-shot 입력만 처리됩니다.",
        hint="직접 타이핑이 목적이면 터미널에서 `python -m src <keeper>` 로 실행",
    )


# --- gate --------------------------------------------------------------------


def _gate_base_url() -> str:
    return os.environ.get("GATE_BASE_URL", "").strip() or "http://localhost:8935"


async def check_env_gate_url() -> Check:
    return Check(
        name="GATE_BASE_URL",
        severity=Severity.ok,
        detail=_gate_base_url(),
        message="",
    )


async def _gate_get(path: str) -> tuple[str, httpx.Response | str]:
    url = _gate_base_url().rstrip("/") + path
    token = os.environ.get("GATE_API_TOKEN", "").strip()
    headers = {"Authorization": f"Bearer {token}"} if token else {}
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
            detail=url,
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


async def check_keepers_available() -> Check:
    url, res = await _gate_get("/api/v1/gate/keepers")
    if isinstance(res, str):
        return Check(
            name="keepers available",
            severity=Severity.warn,
            detail=url,
            message=f"keepers 목록 조회 실패: {res}",
        )
    if res.status_code >= 400:
        return Check(
            name="keepers available",
            severity=Severity.warn,
            detail=str(res.status_code),
            message="keepers 엔드포인트 오류.",
        )
    try:
        body = res.json()
    except ValueError:
        return Check(
            name="keepers available",
            severity=Severity.warn,
            message="keepers 응답 파싱 실패",
        )
    names = _extract_keeper_names(body)
    if not names:
        return Check(
            name="keepers available",
            severity=Severity.error,
            detail="0 keepers",
            message="서버에 등록된 keeper 가 없습니다.",
            hint="config/keepers/*.toml 에 keeper 를 정의하거나 runtime 등록 수행",
        )
    return Check(
        name="keepers available",
        severity=Severity.ok,
        detail=f"{len(names)} registered",
        message="",
    )


async def check_default_keeper_exists() -> Check:
    default = os.environ.get("CLI_DEFAULT_KEEPER", "sangsu").strip()
    url, res = await _gate_get("/api/v1/gate/keepers")
    if isinstance(res, str) or res.status_code >= 400:
        return Check(
            name="default keeper exists",
            severity=Severity.skip,
            detail=default,
            message="gate 응답 오류로 판단 건너뜀",
        )
    try:
        names = _extract_keeper_names(res.json())
    except ValueError:
        return Check(name="default keeper exists", severity=Severity.skip, message="keepers 응답 파싱 실패")
    if default not in names:
        return Check(
            name="default keeper exists",
            severity=Severity.warn,
            detail=default,
            message=f"CLI_DEFAULT_KEEPER='{default}' 가 등록된 keeper 목록에 없습니다. CLI 는 여전히 직접 이름 지정으로 동작합니다.",
            hint="python -m src <existing_keeper_name> 으로 직접 지정",
        )
    return Check(
        name="default keeper exists",
        severity=Severity.ok,
        detail=default,
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
