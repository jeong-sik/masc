# RFC-0202: Keeper Git/PR Dedicated Tool Surface

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-28
- **Related**: Issue #19320, RFC-0008 (Credential Provider), RFC-0097 (Turn-Scope Sandbox), 5-Layer Lock Analysis (#19315)
- **Drives**: Enable keepers to perform Git and PR operations through typed, governed tool surfaces instead of generic shell execution

## 1. Problem

Keepers cannot perform Git/PR operations despite having:
- Valid GitHub credentials configured (`credentials.toml` + `keeper_repo_mappings.toml`)
- Network access (`network_mode = "inherit"`)
- Shell execution capability (`tool_execute` in `delivery` preset)

**Root cause**: No dedicated Git/PR tool surfaces exist. Keepers must use `tool_execute` (generic shell), which:
1. Is classified as `Shell_dynamic` → `External_effect` for git/gh commands
2. Requires LLM to learn exact git/gh CLI syntax
3. Returns unstructured stdout instead of typed results
4. Has no credential injection — keeper must discover credentials at runtime
5. Destructive classification blocks some operations (Lock 4 revised: not a blocker for Execute mode, but still a governance gap)

**Evidence**: 5-layer lock analysis (Issue #19315) identified Lock 1 (no dedicated tool surface) as the primary remaining structural blocker.

## 2. Design Principles

| # | Principle | Rationale |
|---|-----------|-----------|
| P1 | **Typed surfaces over shell passthrough** | LLM emits structured JSON, not shell strings. Compiler catches missing fields. |
| P2 | **Credential injection at tool level** | Tools resolve credentials internally via `Credential_provider`. Keeper doesn't see tokens. |
| P3 | **Effect classification per operation** | `git clone` is `Local_mutation`, `git push` is `External_effect`, `gh pr view` is `Read_only`. |
| P4 | **Graduated risk** | Low-risk ops (clone, view) available in `research` preset. High-risk ops (push, merge) require `delivery` or explicit opt-in. |
| P5 | **Reuse existing infrastructure** | `Credential_provider` (RFC-0008), `Keeper_turn_sandbox_runtime` (RFC-0097), `Tool_spec.register` pattern. |

## 3. Proposed Tool Surfaces

### 3.1 `tool_git_clone`

```json
{
  "name": "tool_git_clone",
  "description": "Clone a repository into the keeper's playground workspace",
  "input_schema": {
    "type": "object",
    "properties": {
      "repository": {
        "type": "string",
        "description": "Repository URL or owner/repo shorthand (e.g., 'jeong-sik/masc-mcp')"
      },
      "branch": {
        "type": "string",
        "description": "Branch to checkout after clone (default: repository default branch)"
      },
      "depth": {
        "type": "integer",
        "description": "Clone depth (default: 1 for shallow clone)"
      }
    },
    "required": ["repository"]
  }
}
```

- **Effect class**: `Local_mutation` (creates files in workspace)
- **Risk level**: `Low`
- **Credential**: Uses `Credential_provider.resolve` to get `gh` config dir, sets `GH_CONFIG_DIR` env
- **Implementation**: `git clone --depth {depth} https://x-access-token:{token}@github.com/{repository}.git`

### 3.2 `tool_git_commit`

```json
{
  "name": "tool_git_commit",
  "description": "Stage and commit changes in the current workspace",
  "input_schema": {
    "type": "object",
    "properties": {
      "message": {
        "type": "string",
        "description": "Commit message (Conventional Commits format preferred)"
      },
      "files": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Specific files to stage (default: all changed files)"
      },
      "allow_empty": {
        "type": "boolean",
        "description": "Allow empty commit (default: false)"
      }
    },
    "required": ["message"]
  }
}
```

- **Effect class**: `Local_mutation`
- **Risk level**: `Medium`
- **Credential**: Not required (local operation)
- **Implementation**: `git add {files} && git commit -m "{message}"`

### 3.3 `tool_git_push`

```json
{
  "name": "tool_git_push",
  "description": "Push committed changes to a remote repository",
  "input_schema": {
    "type": "object",
    "properties": {
      "remote": {
        "type": "string",
        "description": "Remote name (default: 'origin')"
      },
      "branch": {
        "type": "string",
        "description": "Branch to push (default: current branch)"
      },
      "force": {
        "type": "boolean",
        "description": "Force push (default: false, requires approval gate)"
      },
      "set_upstream": {
        "type": "boolean",
        "description": "Set upstream tracking (default: true for new branches)"
      }
    }
  }
}
```

- **Effect class**: `External_effect`
- **Risk level**: `High` (when `force: true`), `Medium` (otherwise)
- **Credential**: Uses `Credential_provider.resolve` for auth
- **Implementation**: `git push {remote} {branch}` with token in URL

### 3.4 `tool_pr_create`

```json
{
  "name": "tool_pr_create",
  "description": "Create a draft pull request on GitHub",
  "input_schema": {
    "type": "object",
    "properties": {
      "title": {
        "type": "string",
        "description": "PR title"
      },
      "body": {
        "type": "string",
        "description": "PR body (markdown)"
      },
      "base": {
        "type": "string",
        "description": "Base branch (default: repository default)"
      },
      "draft": {
        "type": "boolean",
        "description": "Create as draft (default: true)"
      },
      "reviewers": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Reviewer usernames"
      }
    },
    "required": ["title"]
  }
}
```

- **Effect class**: `External_effect`
- **Risk level**: `Medium`
- **Credential**: Uses `Credential_provider.resolve` for `gh` CLI auth
- **Implementation**: `gh pr create --draft --title "{title}" --body "{body}"`

### 3.5 `tool_pr_review`

```json
{
  "name": "tool_pr_review",
  "description": "Submit a review on a GitHub pull request",
  "input_schema": {
    "type": "object",
    "properties": {
      "pr_number": {
        "type": "integer",
        "description": "PR number to review"
      },
      "event": {
        "type": "string",
        "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"],
        "description": "Review event type"
      },
      "body": {
        "type": "string",
        "description": "Review comment body"
      },
      "comments": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "path": { "type": "string" },
            "line": { "type": "integer" },
            "body": { "type": "string" }
          },
          "required": ["path", "line", "body"]
        },
        "description": "Inline review comments"
      }
    },
    "required": ["pr_number", "event"]
  }
}
```

- **Effect class**: `External_effect`
- **Risk level**: `Low` (COMMENT), `Medium` (REQUEST_CHANGES), `High` (APPROVE)
- **Credential**: Uses `Credential_provider.resolve` for `gh` CLI auth
- **Implementation**: `gh pr review {pr_number} --{event} --body "{body}"`

### 3.6 `tool_pr_merge` (Future — gated behind approval)

```json
{
  "name": "tool_pr_merge",
  "description": "Merge an approved pull request",
  "input_schema": {
    "type": "object",
    "properties": {
      "pr_number": {
        "type": "integer",
        "description": "PR number to merge"
      },
      "strategy": {
        "type": "string",
        "enum": ["squash", "merge", "rebase"],
        "description": "Merge strategy (default: squash)"
      }
    },
    "required": ["pr_number"]
  }
}
```

- **Effect class**: `External_effect`
- **Risk level**: `Critical` (requires explicit approval gate)
- **Not included in initial implementation** — requires approval workflow integration

## 4. Shard and Preset Assignment

### 4.1 Shard Definition

```ocaml
(* lib/tool_shard.ml *)
let shard_git_pr : shard =
  { name = "git_pr"
  ; tools = git_pr_tools  (* from tool_shard_types_schemas_git_pr.ml *)
  ; read_only_tools = [ "tool_pr_view" ]  (* future: read-only PR inspection *)
  ; removable = true
  ; description = "Git/PR: repository operations and pull request management"
  }
```

### 4.2 Preset Assignment

```toml
# config/tool_policy.toml

[groups.git_pr]
tools = ["tool_git_clone", "tool_git_commit", "tool_git_push", "tool_pr_create", "tool_pr_review"]

[presets.research]
groups = ["base", "search_files", "git_pr"]  # add git_pr
# Note: git_push and pr_create are External_effect, blocked in Diagnose mode

[presets.delivery]
groups = ["base", "search_files", "execute", "git_pr", "voice"]
```

### 4.3 CDAL Classification

```ocaml
(* In mode_enforcer.ml or via register_tool_class *)
Mode_enforcer.register_tool_class "tool_git_clone" Local_mutation;
Mode_enforcer.register_tool_class "tool_git_commit" Local_mutation;
Mode_enforcer.register_tool_class "tool_git_push" External_effect;
Mode_enforcer.register_tool_class "tool_pr_create" External_effect;
Mode_enforcer.register_tool_class "tool_pr_review" External_effect;
```

## 5. Credential Injection

Tools resolve credentials internally via `Credential_provider`:

```ocaml
(* In tool handler *)
let resolve_credentials () =
  let open Keeper_turn_sandbox_runtime in
  let* binding = Credential_provider.resolve ~identity:keeper_identity () in
  Ok binding.env  (* contains GH_TOKEN, GH_CONFIG_DIR, etc. *)
```

The keeper's `keeper_repo_mappings.toml` determines which credential to use based on the target repository. The tool handler:
1. Resolves the credential for the current keeper + target repo
2. Injects `GH_TOKEN` or `GH_CONFIG_DIR` into the execution environment
3. Executes the git/gh command with credentials
4. Returns structured result (not raw stdout)

## 6. Implementation Plan

| Phase | Scope | PR |
|-------|-------|-----|
| **Phase 1** | Schema definitions + shard + preset assignment | PR-A |
| **Phase 2** | `tool_git_clone` + `tool_git_commit` handlers | PR-B |
| **Phase 3** | `tool_git_push` + `tool_pr_create` + `tool_pr_review` handlers | PR-C |
| **Phase 4** | Credential injection wiring | PR-D |
| **Phase 5** | `tool_pr_merge` + approval gate integration | Future RFC |

### Phase 1 Deliverables

1. `lib/tool_shard_types_schemas_git_pr.ml` — schema definitions
2. `lib/tool_shard.ml` — shard registration
3. `config/tool_policy.toml` — group + preset updates
4. `lib/cdal_runtime/mode_enforcer.ml` — effect classification registration
5. `lib/tool_name.ml` — add new tool name variants (if using typed dispatch)

### Phase 2-3 Deliverables

1. `lib/tool_handlers/tool_handler_git_pr.ml` — handler implementations
2. Credential resolution wiring via `Keeper_turn_sandbox_runtime`
3. Tests for each tool operation

## 7. Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| **Credential leak in logs** | Tool handlers never log tokens. `Credential_provider` returns masked env vars. |
| **Force push data loss** | `force: true` requires `High` risk → `Draft` mode → approval gate |
| **Merge without review** | `tool_pr_merge` gated behind approval workflow (Phase 5) |
| **Scope creep** | Phase 1-3 only. Merge tool requires separate RFC. |
| **Backward compatibility** | Existing `tool_execute` continues to work. New tools are additive. |

## 8. Success Criteria

1. Keeper can clone a repository using `tool_git_clone` (structured JSON input)
2. Keeper can commit changes using `tool_git_commit`
3. Keeper can create a draft PR using `tool_pr_create`
4. Keeper can submit a review using `tool_pr_review`
5. All operations use injected credentials (no hardcoded tokens)
6. CDAL mode enforcement correctly classifies each operation
7. Existing `tool_execute` path continues to work for ad-hoc commands

## 9. Open Questions

1. **Should `tool_git_push` require `set_upstream: true` by default for new branches?** (Yes — prevents accidental pushes to wrong remote)
2. **Should `tool_pr_create` always create drafts?** (Yes — aligns with "Draft PR Only" workflow guardrail)
3. **How to handle credential expiration mid-operation?** (Retry with fresh credential via `Credential_provider.resolve`)
4. **Should tools support multi-repo operations?** (No — each tool operates on the current workspace. Multi-repo requires orchestration layer.)
