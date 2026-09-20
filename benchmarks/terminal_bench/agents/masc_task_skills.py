"""Harbor task Skill snapshot and MASC catalog preflight."""
from __future__ import annotations

import json
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path

from render_configs import TASK_SKILL_SOURCE_ID, task_skill_names

SKILL_CATALOG_PATH = "/api/v1/skills"


def validate_task_skill_catalog(catalog: object, expected_names: list[str]) -> None:
    """Reject a bootstrap that silently omitted a Harbor task Skill."""
    if not isinstance(catalog, dict) or catalog.get("state") != "ready":
        raise RuntimeError("task Skill catalog is not ready")
    snapshot = catalog.get("snapshot")
    if not isinstance(snapshot, dict):
        raise RuntimeError("task Skill catalog has no snapshot")

    sources = snapshot.get("sources")
    task_sources = [source for source in sources
                    if isinstance(source, dict)
                    and source.get("id") == TASK_SKILL_SOURCE_ID] \
        if isinstance(sources, list) else []
    if len(task_sources) != 1:
        raise RuntimeError("task Skill source is missing or duplicated")
    observation = task_sources[0].get("observation")
    if (task_sources[0].get("access") != "read-only"
            or not isinstance(observation, dict)
            or observation.get("kind") != "ready"):
        raise RuntimeError("task Skill source is not ready and read-only")

    rejections = snapshot.get("rejections")
    task_rejections = [row for row in rejections
                       if isinstance(row, dict)
                       and row.get("source_id") == TASK_SKILL_SOURCE_ID] \
        if isinstance(rejections, list) else []
    if task_rejections:
        raise RuntimeError(f"task Skill catalog rejected packages: {task_rejections}")

    def task_identity(value: object) -> bool:
        return isinstance(value, dict) and value.get("source_id") == TASK_SKILL_SOURCE_ID

    shadows = snapshot.get("shadows")
    task_shadows = [row for row in shadows
                    if isinstance(row, dict)
                    and (task_identity(row.get("winner"))
                         or task_identity(row.get("shadowed")))] \
        if isinstance(shadows, list) else []
    if task_shadows:
        raise RuntimeError(f"task Skill catalog has name collisions: {task_shadows}")

    def identities(field: str) -> set[tuple[str, str, str]]:
        rows = snapshot.get(field)
        found = set()
        for row in rows if isinstance(rows, list) else []:
            identity = row.get("identity") \
                if field == "skills" and isinstance(row, dict) else row
            if not isinstance(identity, dict):
                continue
            source_id = identity.get("source_id")
            package_id = identity.get("package_id")
            name = identity.get("name")
            if (isinstance(source_id, str) and isinstance(package_id, str)
                    and isinstance(name, str)):
                found.add((source_id, package_id, name))
        return found

    expected = {(TASK_SKILL_SOURCE_ID, name, name) for name in expected_names}
    missing_entries = expected - identities("skills")
    missing_effective = expected - identities("effective_skills")
    if missing_entries or missing_effective:
        raise RuntimeError(
            "task Skills are not effective: "
            f"missing_entries={sorted(missing_entries)}, "
            f"missing_effective={sorted(missing_effective)}")


@asynccontextmanager
async def task_skills_snapshot(agent, environment):
    """Yield one local immutable snapshot of Harbor's in-container directory."""
    with tempfile.TemporaryDirectory(prefix="masc-task-skills-") as temp:
        if not agent.skills_dir:
            yield None, []
            return
        if not await environment.is_dir(agent.skills_dir):
            raise RuntimeError(
                f"Harbor task skills_dir is not a directory: {agent.skills_dir}")
        local = Path(temp) / "task-skills"
        await environment.download_dir(agent.skills_dir, local)
        yield local, task_skill_names(local)


async def preflight_task_skill_catalog(agent, environment, expected_names: list[str]) -> None:
    if not expected_names:
        return
    result = await agent.exec_as_root(
        environment,
        f"curl -fsS http://127.0.0.1:8935{SKILL_CATALOG_PATH}",
        timeout_sec=30)
    try:
        catalog = json.loads(result.stdout or "")
    except json.JSONDecodeError as exc:
        raise RuntimeError("task Skill catalog response is not JSON") from exc
    validate_task_skill_catalog(catalog, expected_names)
