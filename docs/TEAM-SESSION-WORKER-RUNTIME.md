# Team-Session Worker Runtime

`masc_team_session_step` spawned workers now support an optional Docker-backed
runtime backend.

## Scope

- v1 applies only to team-session spawned workers.
- `observe_only` workers stay local.
- `limited_code_change` and `autonomous` workers can resolve to Docker when the
  backend is enabled.
- This is runtime isolation and reproducibility, not a hostile-code sandbox.

## Config

Config file path:

- `<resolved-config-root>/worker-runtime.json`

Example:

```json
{
  "team_session_spawn": {
    "backend": "docker",
    "docker_scopes": ["limited_code_change", "autonomous"],
    "docker": {
      "image": "masc-worker-runtime:local-<git-sha>",
      "host_mcp_base_url": "http://host.docker.internal:8935"
    }
  }
}
```

Environment overrides:

- `MASC_WORKER_RUNTIME_BACKEND=local|docker`
- `MASC_WORKER_RUNTIME_DOCKER_IMAGE=<image>`
- `MASC_WORKER_RUNTIME_HOST_MCP_BASE_URL=<url>`

## Image Build

```bash
./scripts/build-worker-runtime-image.sh
```

Or pin a tag explicitly:

```bash
./scripts/build-worker-runtime-image.sh masc-worker-runtime:local-my-tag
```

## Runtime Behavior

- Docker preflight runs once per spawn batch before the first Docker-backed
  worker starts.
- Preflight checks Docker daemon availability and the configured image.
- If Docker preflight fails, the entire spawn batch is rejected.
- Worker run metadata now includes `worker_backend=local|docker`.

## Notes

- `masc-worker-run --spec-stdin` is the internal container entrypoint.
- Host loopback URLs used by the worker runtime are rewritten to
  `host.docker.internal`.
- `Docker-in-Docker` is not supported in v1.
