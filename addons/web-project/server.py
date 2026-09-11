"""A Web-project layer: correlate one target and request with actual documents."""

from __future__ import annotations

import hashlib
import sys
from dataclasses import dataclass
from enum import Enum
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, Source, boolean, evidence, number, object_value,
                      row, serve, stable_id, string)


@dataclass(frozen=True)
class Target:
    id: str
    environment: str
    url: str

    @classmethod
    def parse(cls, value: object) -> Target:
        value = object_value(value, "target")
        return cls(*(string(value.get(key), f"target.{key}")
                     for key in ("id", "environment", "url")))

    def json(self) -> dict:
        return {"id": self.id, "environment": self.environment, "url": self.url}


class Kind(Enum):
    DEPLOYMENT = "deployment"
    BROWSER = "browser"
    PROBE = "probe"


class RevisionMarker(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.revisions: list[str | None] = []
        self.namespaces: list[str | None] = []
        self.in_head = False
        self.heads = 0
        self.body_seen = False
        self.inert: list[str] = []
        self.ambiguous = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        # Only document-head metadata declares the served build. HTMLParser
        # reports lexical tags inside template/noscript/title as well; those
        # are not active document metadata and cannot supply this identity.
        inert_tags = {"template", "noscript", "title"}
        if self.inert:
            if tag in inert_tags:
                self.inert.append(tag)
            return
        if tag == "head":
            self.heads += 1
            self.ambiguous |= self.heads != 1 or self.body_seen
            self.in_head = not self.ambiguous
            return
        if tag == "body":
            self.body_seen = True
            self.in_head = False
            return
        if not self.in_head:
            return
        if tag in inert_tags:
            self.inert.append(tag)
            return
        if tag not in {"base", "link", "meta", "style", "script"}:
            # In HTML, ordinary body content implicitly ends the head.
            # Refuse subsequent lexical markers in that context.
            self.in_head = False
            return
        if tag != "meta":
            return
        names = [value for key, value in attrs if key == "name"]
        contents = [value for key, value in attrs if key == "content"]
        content = contents[0] if len(contents) == 1 else None
        if names == ["masc-revision"]:
            self.revisions.append(content)
        if names == ["masc-revision-namespace"]:
            self.namespaces.append(content)

    def handle_endtag(self, tag: str) -> None:
        if self.inert:
            if tag == self.inert[-1]:
                self.inert.pop()
            elif tag in {"template", "noscript", "title", "head", "body"}:
                self.ambiguous = True
            return
        if tag == "head":
            self.in_head = False

    def revision(self) -> tuple[str, str] | None:
        if (self.heads != 1 or self.ambiguous or self.inert
                or len(self.revisions) != 1 or len(self.namespaces) != 1):
            return None
        revision, namespace = self.revisions[0], self.namespaces[0]
        if not revision or not namespace:
            return None
        return namespace, revision


def document_key(observation: dict) -> tuple[str, str, str]:
    return tuple(string(observation.get(key), key)
                 for key in ("client_id", "tab_id", "document_id"))


def observe(binding: dict, sources: tuple[Source, ...]) -> dict:
    target = Target.parse(binding.get("target"))
    request_id = string(binding.get("request_id"), "request_id")
    expected = object_value(binding.get("expected"), "expected")
    namespace = string(expected.get("namespace"), "expected.namespace")
    revision = string(expected.get("revision"), "expected.revision")
    manifest = evidence([expected.get("manifest")])
    if manifest[0]["sha256"] is None:
        raise InvalidInput("expected.manifest.sha256 is required for the immutable build reference")
    expectation = {
        "id": stable_id("web-expectation", target.json(), request_id, expected),
        "lane_id": "web/expectation", "kind": "value", "title": "Expected build revision",
        "observed_at": number(expected.get("observed_at"), "expected.observed_at"),
        "subject_id": target.id, "clock": None, "actor": None,
        "fields": {"target": target.json(), "request_id": request_id,
                   "namespace": namespace, "revision": revision},
        "evidence": manifest, "related_ids": []}
    rows, coverage = [expectation], []
    browsers: list[tuple[dict, tuple[str, str, str], str, str | None]] = []
    probes: list[tuple[dict, tuple[str, str, str]]] = []
    deployments: list[dict] = []
    for source in sources:
        skipped: set[str] = set()
        seen: set[str] = set()
        for observation in source.observations:
            try:
                kind = Kind(observation.get("kind"))
            except (ValueError, TypeError):
                skipped.add(str(observation.get("kind", "untyped")))
                continue
            actual_target = Target.parse(observation.get("target"))
            actual_request = string(observation.get("request_id"), "observation.request_id")
            matches = actual_target == target and actual_request == request_id
            fields = {"target": actual_target.json(), "request_id": actual_request,
                      "matches_binding": matches}
            if kind is Kind.DEPLOYMENT:
                fields["recorded_revision"] = string(observation.get("revision"), "deployment.revision")
                title = "Deployment receipt reports a revision"
            elif kind is Kind.BROWSER:
                key = document_key(observation)
                fields.update(zip(("client_id", "tab_id", "document_id"), key))
                html = observation.get("html")
                if html is not None and not isinstance(html, str):
                    raise InvalidInput("browser.html must be the same document HTML or null")
                marker = RevisionMarker()
                if html is not None:
                    marker.feed(html)
                    marker.close()
                actual = marker.revision()
                status, actual_revision = "unknown", None
                if actual is not None:
                    fields["namespace"], actual_revision = actual
                    if actual[0] == namespace:
                        status = "match" if actual[1] == revision else "mismatch"
                if not matches:
                    status = "unrelated"
                fields.update({"observed_revision": actual_revision, "comparison": status,
                               "html_sha256": hashlib.sha256(html.encode("utf-8")).hexdigest()
                               if html is not None else None})
                title = "Browser document observed"
            else:
                key = document_key(observation)
                fields.update(zip(("client_id", "tab_id", "document_id"), key))
                fields["passed"] = boolean(observation.get("passed"), "probe.passed")
                title = "Document feature probe passed" if fields["passed"] else "Document feature probe failed"
            item = row(source, observation, lane=f"web/{kind.value}", subject=actual_target.id,
                       title=title, fields=fields)
            if item["id"] in seen:
                raise InvalidInput("duplicate event id within source incarnation")
            seen.add(item["id"])
            rows.append(item)
            if matches and kind is Kind.BROWSER:
                browsers.append((item, key, status, actual_revision))
            if matches and kind is Kind.PROBE:
                probes.append((item, key))
            if matches and kind is Kind.DEPLOYMENT:
                deployments.append(item)
        coverage.append(source.coverage(skipped))
    for browser, key, status, actual_revision in browsers:
        related_probes = [probe for probe, probe_key in probes if key == probe_key]
        # Receipts are reported deployment intent/result claims. Including
        # their evidence does not replace the actual document observation.
        related = [expectation, *deployments, browser, *related_probes]
        rows.append({
            "id": stable_id("web-relation", *(item["id"] for item in related)),
            "lane_id": "web/revision", "kind": "relation",
            "title": {"mismatch": "This browser document differs from the expected revision",
                      "match": "This browser document matches the expected revision",
                      "unknown": "This browser document revision is not confirmed"}[status],
            "observed_at": browser["observed_at"], "subject_id": target.id,
            "clock": None, "actor": None,
            "fields": {"target": target.json(), "request_id": request_id,
                       "client_id": key[0], "tab_id": key[1], "document_id": key[2],
                       "namespace": namespace, "expected_revision": revision,
                       "observed_revision": actual_revision, "comparison": status,
                       "deployment_receipt_ids": [receipt["id"] for receipt in deployments],
                       "failed_probe_ids": [probe["id"] for probe in related_probes
                                            if not probe["fields"]["passed"]],
                       "derived_by": "web-project@0.1.0"},
            "evidence": [ref for item in related for ref in item["evidence"]],
            "related_ids": [item["id"] for item in related]})
    return {"rows": rows, "coverage": coverage}


if __name__ == "__main__":
    serve("masc-web-project", observe)
