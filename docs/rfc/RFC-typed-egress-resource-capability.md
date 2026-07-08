# Typed egress-resource capability — durable-remote creation beyond gh subcommands

- Status: Draft
- Author: Claude (Opus 4.8), on behalf of jeong-sik (vincent)
- Date: 2026-07-08
- Related: RFC-0309 (typed gh capability gating), RFC-0208 (typed domain classification / shell-ir compositional risk), RFC-0107 (outbound HTTP stack consolidation), RFC-0181 (capability-intent runtime SSOT), RFC-0042 (eliminate string classifiers)
- Tracking: issue #23445 (`gh api` REST POST durable-remote create bypasses the capability axis); adversarial audit follow-up 2026-07-07

> Anchors marked **(verified)** were read against `origin/main` @ `77d4d1b049`.

## 1. Problem

RFC-0309 gates GitHub durable-remote mutations (repo/discussion create, etc.) at the
**capability axis** (`Gh_capability_policy`), keyed on the parsed **gh subcommand
family**. But the same durable-remote effect is reachable through paths the axis does
not type, so an autonomous keeper can create/mutate remote surfaces without the
non-blocking HITL approval that the typed path enforces:

| Surface | Current verdict (autonomous) | Gated? |
|---|---|---|
| `gh repo create o/n --private` | Ask | ✅ RFC-0309 |
| `gh api graphql -f query='mutation{createRepository}'` | Ask | ✅ #23424 (graphql body scan) |
| `gh api -X DELETE /repos/o/r` (literal) | Deny | ✅ floor |
| `gh api -X $METHOD /repos/o/r` (opaque) | Ask | ✅ #23634 (method opacity) |
| **`gh api -X POST /user/repos`** (REST create) | **Allow** | ❌ **#23445** |
| **`curl -X POST https://api.github.com/user/repos`** | **Allow** | ❌ (no egress model) |

The capability axis reads the gh *subcommand*; a REST call's resource is determined
by **HTTP method × path**, which the axis cannot see. `risk_of_gh_verb(Api)` is
body/path-blind by design (RFC-0208), so `gh api` REST mutations fall through to
`Allowed`. **(verified via #23634 reproduction: `gh api -X POST /user/repos` →
Allow under the autonomous overlay.)** The `curl` variant is not gated by the gh
capability axis at all.

### 1.1 Common root

The capability axis is **CLI-shape-scoped** (gh subcommand), not
**effect-scoped**. The durable-remote *effect* — "create a repository on the remote"
— is invariant across `gh repo create`, `gh api POST /user/repos`, and
`curl POST api.github.com/user/repos`, but only the first is typed. There is no
egress/resource model that recognizes the effect regardless of the wrapper.

## 2. The constraint that makes this hard (why not the obvious fix)

The obvious fix — a list of dangerous `(method, path)` strings — **reintroduces the
RFC-0042 string-classifier anti-pattern** that RFC-0309 was built to eliminate:

- a hand-maintained wordlist of "dangerous REST paths" is exactly the
  `repo_hosting_cli_irreversible` list RFC-0309 retired;
- the compiler cannot force coverage of a new resource; new API paths are silently
  `Allowed`;
- it is the same `Unknown → Permissive` failure mode (an unlisted path auto-runs).

So this RFC's real work is a **typed resource model** that survives the RFC-0042
bar, not a path denylist. This is the crux the design must defend.

## 3. Design

### 3.1 Option A — typed REST-resource classifier (narrow, closes #23445)

Parse `gh api`'s `(method, endpoint)` into a **closed, typed** resource-effect
lattice, not a free wordlist:

```
type rest_effect =
  | Read                         (* GET, HEAD *)
  | Durable_remote_create        (* POST /user/repos, POST /orgs/{org}/repos,
                                    POST /repos/{o}/{r}/... that create surfaces *)
  | Durable_remote_destroy       (* DELETE /repos/{o}/{r}, ... *)
  | Reversible_mutation          (* PATCH/PUT on non-destructive resources *)
  | Unknown_mutation             (* any mutating method whose path is not typed *)
```

- The `(method × path-template)` → `rest_effect` mapping is a **structured, closed
  table of path templates** (segments + typed captures like `{org}`, `{owner}`),
  version-pinned to the GitHub REST surface — *not* a substring match. Adding a
  method/path family is a typed edit the reviewer sees, and an **unknown mutating
  method fails closed** to `Unknown_mutation → Requires_approval` (Ask), not
  `Allowed`. This is the RFC-0042-compliant inversion: unknown → gated, not unknown →
  permissive.
- Wire into `Gh_capability_policy`: `Durable_remote_create` / `Unknown_mutation` →
  `Requires_approval` (Ask), mirroring the typed gh path; `Durable_remote_destroy` →
  floor Deny (matches literal `-X DELETE` today); `Read`/`Reversible_mutation` per
  existing policy.
- Opaque method already handled (#23634); opaque **path** (`$ENDPOINT`) must also
  fail closed to Ask by the same opacity principle.

**Defensibility vs RFC-0042:** the distinction is *closed sum type + typed path
template + unknown-fails-closed*, versus RFC-0042's *open wordlist of operation
names + unknown-is-permissive*. The former makes illegal states unrepresentable and
forces reviewer-visible edits; the latter silently drifts. The RFC must include a
drift test: a new mutating method on an untyped path classifies `Unknown_mutation`,
not `Read`.

### 3.2 Option B — egress capability layer (broad, subsumes curl/HTTP)

Gate **outbound mutating HTTP by destination + method**, independent of the CLI
wrapper. An egress capability that recognizes `POST/PUT/PATCH/DELETE` to
`api.github.com` (and other durable hosts) → `Requires_approval`, covering
`gh api`, `curl`, `wget`, and direct HTTP. This is the effect-scoped model §1.1
argues for, and connects to RFC-0107 (outbound HTTP stack consolidation) and
RFC-0181 (capability-intent SSOT).

**Trade-off:** broader and more principled, but larger blast radius (touches the
generic egress/curl path, more false-positive risk on benign POSTs to non-durable
hosts), and needs a host/resource taxonomy. Higher cost, higher payoff.

### 3.3 Recommendation & sequencing

- **Phase 1 (Option A):** close #23445 for `gh api` REST with the typed resource
  classifier. Bounded, mirrors the existing #23424/#23634 pattern, directly retires
  the confirmed bypass.
- **Phase 2 (Option B):** generalize to an egress capability for `curl`/direct HTTP,
  subsuming Phase 1's gh-api table as one caller. Deferred until Phase 1 lands and the
  host/resource taxonomy is designed.

Doing A first avoids over-building; doing B eventually avoids the "one bypass closed,
the adjacent one opens" treadmill the 2026-07-07 audit documented (each typed gate
strengthened reveals the next string-borne equivalent path).

## 4. Why not the tempting non-fixes (tradeoffs)

- **REST-path denylist / substring:** RFC-0042 anti-pattern (§2). Rejected.
- **Blanket "all `gh api` mutating methods → Ask":** over-blocks benign reversible
  REST calls and does nothing for `curl`. A coarse stopgap at best; the typed lattice
  (§3.1) is the same effort with correct granularity.
- **Telemetry on REST creates:** an alarm, not a gate. Rejected per the workaround bar.

## 5. Verification

- **Differential harness** (mirrors #23634 tests): `gh api -X POST /user/repos` → Ask;
  `gh api -X POST /orgs/o/repos` → Ask; `gh api -X DELETE /repos/o/r` → Deny;
  `gh api /repos/o/r` (GET) → Allow; `gh api -X POST /repos/o/r/issues` (reversible)
  → per policy; `gh api -X POST /unknown/typed/path` → Ask (unknown-fails-closed).
- **Drift test:** adding a mutating method to an untyped path must classify
  `Unknown_mutation` (Ask), proving no silent `Allowed` drift.
- **Phase 2:** `curl -X POST https://api.github.com/user/repos` → Ask;
  `curl -X POST https://benign.example/webhook` → per host policy.

## 6. Relationship to RFC-0309

This is a coverage extension of RFC-0309's thesis ("typed gating, no string
classifiers, unknown fails closed") to the REST/egress surface that RFC-0309's
gh-subcommand axis structurally cannot see. #23634 (opaque method) and #23424
(graphql body) closed two adjacent string-borne equivalents; #23445 (REST
method×path) is the next, and `curl`/HTTP egress is the general case.
