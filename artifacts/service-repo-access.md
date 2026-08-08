# Service Repo Access Map for Backlog-Zero Goals

## Goals covered

- goal-kidsnote-backlog-zero
- goal-benefit-zero
- goal-benefit-thanks-zero
- goal-benefit-bonus-zero
- goal-benefit-firstcome-zero
- goal-store-attendance-zero
- goal-cn-erp-zero

## Method

- Listed `repos/` and `.masc/repos/`.
- Ran `git -C <workspace_root> remote -v` and `git status --short`.
- Searched for service-name substrings under the workspace root.

## Findings

### 1. `repos/` directory

```
repos/
├── masc/
├── masc-wtask-188/
├── masc-wtask-195/
├── masc-wtask-204/
└── masc-wtask-205/
```

- Only MASC-related checkouts exist in `repos/`.
- No `kidsnote_web_inapp`, `benefit`, `store-attendance`, or `cn-erp` repo here.

### 2. `.masc/repos/` directory

```
.masc/repos/
└── vp-slugify-lib/
```

- Only `vp-slugify-lib` (a small utility library).
- No service repos.

### 3. Workspace root is a git repo with service-related files

The sandbox root itself (`/Users/dancer/me/.masc/playground/sangsu`) is a git repo:

```
origin	https://github.com/jeong-sik/me.git (fetch/push)
masc	https://github.com/jeong-sik/masc.git (fetch/push)
masc-mcp	https://github.com/jeong-sik/masc-mcp.git (fetch/push)
```

The workspace root contains many files that reference the target services:

| File | Service hint | Notes |
|------|-------------|-------|
| `a11y_fix_cn_erp.py` | cn-erp | Accessibility fix script |
| `fix_benefit_bonus_*.py` | benefit-bonus | Multiple fix scripts |
| `fix_benefit_thanks_*.py` | benefit-thanks | Props/RQ/error-handling fixes |
| `setup_msw_benefit_bonus.py` | benefit-bonus | MSW setup script |
| `update_vite_config.py` | benefit? | Vite config update |
| `useBenefitReq_dump.ts` | benefit | Hook/type dump |
| `fix_reserve_item.py` | store-attendance? | Reserve item fix |
| `docs/kidsnote-frontend-toctou-improvement-plan.*` | kidsnote | Frontend TOCTOU plan/report |
| `docs/kidsnote-toctou-button-audit-report.*` | kidsnote | Button audit report |
| `docs/kidsnote-toctou-related-jira-tickets.*` | kidsnote | Jira ticket mapping |
| `docs/kidsnote-toctou-self-review.*` | kidsnote | Self-review |

This suggests the service code may not be organized as separate repos inside this sandbox. Instead, the workspace root seems to hold patches, migration scripts, and audit reports for these services.

### 4. No full source tree found

- No `package.json`, `dune-project`, `Cargo.toml`, `pyproject.toml`, or similar project root files for the service repos in the sandbox root.
- The scripts appear to be **helper/audit/migration scripts** rather than the service source itself.
- Therefore, the actual service codebases (kidsnote_web_inapp, benefit services, cn-erp, store-attendance) are likely managed in separate repositories that are **not currently checked out** in the sangsu sandbox.

## Access status summary

| Service | Repo present? | Notes |
|---------|---------------|-------|
| masc | Yes (repos/masc) | Actively worked on |
| kidsnote_web_inapp | No | Not in sangsu sandbox; code-reviewer sandbox has it |
| benefit* | No | Only helper scripts in workspace root |
| cn-erp | No | Only `a11y_fix_cn_erp.py` script |
| store-attendance | No | Only `fix_reserve_item.py` hint |

## Open questions

1. Are the service repos expected to be cloned into `repos/<service>` or are they intentionally absent from the sangsu sandbox?
2. Is the workspace root (`jeong-sik/me`) the authoritative source for service scripts, or is it a scratch area?
3. Should backlog-zero tasks for these services be delegated to keepers with the proper repo checkouts (e.g., code-reviewer or kidsnote keeper)?
4. If the repos are private or restricted, what is the process for sangsu to request access?

## Recommended next steps

1. **Operator clarification**: Ask the operator to confirm which repos sangsu should have access to for these backlog-zero goals.
2. **If access is granted**: clone the missing service repos into `repos/` and create triage tasks per service.
3. **If access is not granted**: convert the backlog-zero goals into "coordination" goals and delegate service-specific tasks to keepers that already have the repos.
4. **Immediate safe action**: Treat the existing scripts and docs in the workspace root as evidence of past work, but do not modify them until repo ownership is clarified.

## Conclusion

The sangsu sandbox currently cannot directly work on kidsnote, benefit, cn-erp, or store-attendance source code because the repositories are not checked out. The workspace root contains only auxiliary scripts and reports. The first blocker is repository access, not task triage.
