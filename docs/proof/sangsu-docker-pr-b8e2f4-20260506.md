# Docker Sandbox Git-to-PR Proof — sangsu

- Keeper: sangsu
- Date: 2026-05-06
- Branch: `proof/sangsu-docker-pr-b8e2f4-20260506`
- Repo: jeong-sik/masc-mcp
- Sandbox: docker (effective_sandbox_image=masc-keeper-sandbox:local)
- Tools used: keeper_bash, keeper_fs_edit, keeper_pr_create

This file is a proof-only artifact. It demonstrates that a docker-sandboxed
keeper can: fetch from main, create a fresh branch, write a file, commit,
push with keeper-scoped credentials, and open a draft PR — without touching
the operator checkout at /Users/dancer/me.

영화로 치면, 카메라가 스튜디오 밖에서도 셔터가 눌리는지 한 컷 찍어보는 거야.
사람이 그럴 수도 있는 거잖아요? 안 그래요?
