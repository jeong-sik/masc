# Keeper egress policy

The operator runbook for `network_mode = "policy"` (RFC-0415).

`network_mode` used to be a switch. `none` gives a keeper no network, and
`inherit` gives it the whole internet, so a keeper that needs one host gets
every host. `policy` is the mode in between: the guest reaches a proxy this
server owns and nothing else, and the proxy judges each destination against
that keeper's allowlist.

The lane is fail-closed at the network, not at an environment variable. A
subprocess that opens its own socket does not get out, because the guest is
on a host-only network with no route except the proxy.

## Availability

| Backend | Policy lane |
|---|---|
| `microvm` + `apple_container` | Available |
| `microvm` + `microsandbox` | Refused — msb's network profiles are unmeasured, and msb does not boot under masc today |
| `microvm` + `nerdctl_kata` | Refused — a Kata guest's egress boundary is unmeasured |
| `docker` | Refused — the Docker egress boundary is unmeasured |
| `remote_ssh` | Refused — an endpoint's network is its own host's policy |

Each refusal names what has to be measured before it can be lifted. A mode
that is policy on one backend and advice on another is worse than one that
says no, so none of them fall back to `inherit`.

## 1. Declare what the keeper may reach

In the effective `<base>/.masc/runtime.toml`:

```toml
[egress.keepers.rondo]
allow = [
  "github.com",
  "api.github.com",
  "*.githubusercontent.com",
]
```

One table per keeper, keyed by the keeper's name. `allow` is required: a
table without it fails the load rather than being read as an empty list,
because the two spellings of "reaches nothing" should not both be silent.

**A rule is parsed when the file is read, not when a request arrives.** An
entry the matcher and a resolver could read differently fails the load and
names the byte:

```
egress.keepers.rondo.allow: "evil\x00.example.com" is not a host this lane
will match: byte \x00 at offset 4 is not allowed in a host
```

That is the whole reason the check lives here. An allowlist with a hole in
it is worse than no allowlist, because it reads as protection.

### What a rule admits

A rule is a host and the port it may be reached on. An unqualified rule
means port 443, so an allowlist of ordinary web hosts needs no `:443` after
each entry; a service on another port says so.

| Rule | Admits | Refuses |
|---|---|---|
| `github.com` | `github.com:443`, `GitHub.COM:443`, `github.com.:443` | `api.github.com`, `github.com:80` |
| `*.github.com` | `api.github.com:443`, `a.b.github.com:443` | `github.com:443`, `notgithub.com:443` |
| `registry.internal:8443` | that host on 8443 | the same host on 443 |
| `140.82.121.6` | that address on 443 | any name |

A host may be named twice to permit two ports:

```toml
allow = ["registry.internal", "registry.internal:8443"]
```

A host the allowlist names, reached on a port it does not, is reported as
that and not as an unlisted host, and the refusal says which ports would
have worked:

```
registry.internal is allowed on 8443, not on port 443
```

The two are different mistakes fixed in different places, and reporting the
first as the second sends an operator looking for a rule they already
wrote.

A wildcard is strictly below its apex, and matching is on parsed labels, so
`notgithub.com` cannot ride `*.github.com` the way a string-suffix check
would let it. A name rule never admits an address: an allowlist of
`github.com` is not permission to open a socket to github's IP, so an
address a keeper must reach is listed as itself.

A keeper with no `[egress.keepers.<name>]` table has an empty allowlist, and
an empty allowlist admits nothing. Omitting the table is not permission.

## 2. Put the keeper in the lane

In `<base>/.masc/config/keepers/<name>.toml`:

```toml
sandbox_profile = "microvm"
microvm_backend = "apple_container"
network_mode = "policy"
```

`network_mode` is the keeper's declaration; `[egress.keepers.<name>]` is the
operator's answer to it. They are apart for the same reason
`sandbox_profile = "remote_ssh"` sits apart from `[exec.ssh.endpoints.*]`:
a keeper names a lane, and what that lane permits is not the keeper's to
say.

## 3. What the guest sees

Two flags, and both are the policy rather than a default:

- `--network masc-egress-policy` — a host-only network. Measured on
  container 1.3.1: a guest on it cannot reach `1.1.1.1:443` or a public
  address by raw TCP, and can reach a listener on the host gateway.
- `--no-dns` — no resolver in the guest, on purpose. The proxy speaks
  CONNECT, so the guest hands it a name and the proxy resolves that same
  name, after the allowlist has judged it. One resolver, downstream of the
  matcher.

The guest is told where the proxy is through the usual proxy environment
variables. That is convenience, not enforcement: a client that ignores them
finds no route rather than a way around.

## 4. Reading what a keeper reached

Every request through the proxy produces one event, admitted or refused,
recorded when the request is judged rather than when the tunnel closes.

```
admitted api.github.com:443
refused: evil.com is not in this keeper's allowlist
refused: destination is not a host this lane will resolve: byte \x00 at offset 17 is not allowed in a host
upstream api.github.com:443 failed: Connection refused
```

`refused` and `upstream ... failed` are different facts and stay apart. A
refusal is the allowlist saying no; an upstream failure means the allowlist
said yes and the network did not cooperate. Reading one as the other is how
a policy problem gets chased as an outage.

A keeper's own account of where it went is not evidence. These events are.

## Limits worth stating

- **CONNECT only.** A proxy that also spoke plain HTTP would have to parse a
  body to say honestly what it forwarded; this one records an authority,
  which is the whole of what it can truthfully claim to know. The port is not
  fixed, but it is permitted per rule rather than left open, so the lane
  never becomes a generic tunnel by omission.
- **The proxy sees the name, not the payload.** TLS is tunnelled, not
  terminated. What a keeper sent to an allowed host is not recorded here.
- **The allowlist is fixed for the life of a listener.** A tunnel outliving
  the policy that opened it would be worse than a restart, so a policy
  change restarts the listener.
- **This is not a complete security boundary.** Neither is any of the
  sandbox profiles. It bounds reach and records it; it does not make an
  unattended agent safe.
