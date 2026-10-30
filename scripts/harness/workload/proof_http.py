"""HTTP helpers for exact proof collectors.

Authenticated evidence reads never follow redirects, and browser credentials
are scoped to the exact MASC origin.
"""

from __future__ import annotations

from typing import Any
from urllib.request import HTTPRedirectHandler, Request, build_opener
from urllib.parse import urlsplit


class RedirectRejected(OSError):
    pass


class RejectRedirects(HTTPRedirectHandler):
    def redirect_request(
        self,
        req: Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> Request | None:
        del fp, code, msg, headers
        raise RedirectRejected(f"redirect rejected: {req.full_url} -> {newurl}")


def open_no_redirect(request: Request, *, timeout: float) -> Any:
    return build_opener(RejectRedirects()).open(request, timeout=timeout)


def _origin(url: str) -> tuple[str, str, int | None]:
    parsed = urlsplit(url)
    port = parsed.port
    if port is None:
        if parsed.scheme.lower() == "http":
            port = 80
        elif parsed.scheme.lower() == "https":
            port = 443
    return parsed.scheme.lower(), (parsed.hostname or "").lower(), port


def same_origin(left: str, right: str) -> bool:
    return _origin(left) == _origin(right)


def scoped_bearer_headers(
    *, base_url: str, request_url: str, headers: dict[str, str], token: str
) -> dict[str, str]:
    scoped = {
        name: value for name, value in headers.items() if name.lower() != "authorization"
    }
    if same_origin(request_url, base_url):
        scoped["Authorization"] = f"Bearer {token}"
    return scoped
