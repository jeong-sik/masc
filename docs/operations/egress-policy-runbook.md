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

The guest is told where the proxy is through four environment variables set
on its boot — `http_proxy`, `https_proxy`, and both upper-case spellings.
All four, because the common clients do not agree on which they read: curl
and wget take the lower-case names, many Go and Java clients take the
upper-case ones, and `gh` inherits whichever its libc build honours. Setting
one and not the other is how a keeper reaches the proxy for `git` and
silently finds no route for `gh`.

The value is an address, not a name, because the guest has no resolver. The
address is the policy network's own gateway, read from the network at boot:
container assigns the subnet, so a fixed address would be right only until a
host had a network on that one already.

`NO_PROXY` is deliberately absent. An exception list there would be a second
allowlist, one the proxy never sees and cannot record.

This is convenience, not enforcement. A client that ignores these finds no
route rather than a way around — the enforcement point is the host-only
network, not this list. A guest that is never handed them is merely stuck,
so a boot that does not know the proxy's address is refused rather than
started.

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
- **The allowlist is read per request, so an edit applies to the next
  connection.** No restart, no reload command. The sibling SSH lane already
  re-reads its endpoint registry on every dispatch, and one `runtime.toml`
  behaving two ways would be worse than the cost of a parse.

  It is read per request rather than per connection because a tunnel
  outliving the policy that opened it is the one thing worse than a slow
  reload: the rules that admit a CONNECT are the rules in force when it is
  admitted, and that tunnel then runs to completion under them. Removing a
  host stops the next connection, not one already open.

  **A read that fails keeps the last rules that parsed**, and logs. That is
  fail-closed-to-previous, not fail-open: a typo in `runtime.toml` leaves the
  keeper with the reach you last successfully granted rather than widening
  it. Watch for this line, because the file and the enforced policy have
  diverged until it stops:

  ```
  egress allowlist unreadable, serving the last rules that parsed: <detail>
  ```

  **The first read is different.** There is no previous set to fall back to,
  so the lane is refused rather than served an empty allowlist that would
  read as a deliberate "reaches nothing":

  ```
  egress proxy not started keeper=<name>: <detail> (the lane stays closed)
  ```

- **This is not a complete security boundary.** Neither is any of the
  sandbox profiles. It bounds reach and records it; it does not make an
  unattended agent safe.
