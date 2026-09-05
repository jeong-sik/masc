---
title: Keeper Sandbox Runbook
description: Isolating Keeper tool executions using Docker and MicroVM boundaries.
---

To protect host environments from destructive commands, MASC enforces isolated execution. There is no host profile; a Keeper declared without an accepted sandbox profile is refused at boot.

## Isolation Backends

1. **Docker (`docker`)**: Confines tool runs within a dedicated container.
2. **MicroVM (`microvm`)**: Guest isolated behind a hypervisor boundary (on macOS: `microvm_backend = "apple_container"`).
3. **Remote SSH (`remote_ssh`)**: Remote execution target declared under `[exec.ssh.endpoints]` in `runtime.toml`.

---

## Configuration Example

In `<base-path>/.masc/config/keepers/<keeper-name>.toml`:

```toml
[keeper]
autoboot_enabled = true
sandbox_profile = "docker" # "docker" | "microvm" | "remote_ssh"
# When microvm (macOS):
# microvm_backend = "apple_container"
# When remote_ssh:
# remote_endpoint = "worker-node-1"
```
