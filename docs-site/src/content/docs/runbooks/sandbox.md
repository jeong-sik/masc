---
title: Keeper Sandbox
description: Isolating a Keeper's tool commands with Docker, microVM, or remote SSH.
---

A Keeper's shell commands run isolated, not on your host. There is no host
profile: a Keeper declared without an accepted `sandbox_profile` is refused at
boot, so a Keeper cannot start until you pick one.

## Isolation backends

- **`docker`** — runs the Keeper's tools inside a container. Needs Docker installed
  and its daemon running.
- **`microvm`** — runs them behind a hypervisor boundary. On macOS this uses
  Apple's `container` CLI; install it first.
- **`remote_ssh`** — runs them on a remote host declared under
  `[exec.ssh.endpoints]` in `runtime.toml`, selected with `remote_endpoint`.

## Configuration

`masc keeper-create` writes these fields for you (`--sandbox-profile` and the
required `--network-mode`). The resulting `<base-path>/.masc/config/keepers/<name>.toml`
looks like:

```toml
sandbox_profile = "docker"   # "docker" | "microvm" | "remote_ssh"
network_mode = "none"        # "none" | "inherit"

# only for sandbox_profile = "remote_ssh":
# remote_endpoint = "worker-node-1"
```

`network_mode` is separate from the profile and is required. `none` gives the
guest no network at all — a Keeper that does web search or `git push` needs
`inherit`. The default for `docker` and `microvm` is `none`, which is why
`masc keeper-create` refuses to proceed without the flag rather than choosing for
you.
