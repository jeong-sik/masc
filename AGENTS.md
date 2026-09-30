# MASC Agent Instructions

## Required Contract

- Before planning or changing MASC, read `docs/constitution.xml` in full.
- For MASC coding-agent work, its `<execution_protocol>` is the repository-specific workflow authority. It overrides parent or general contributor guidance, including `CONTRIBUTING.md`, only where those sources would require local Dune builds, CI watch/wait loops, or a different default for parallel review agents.
- System, developer, and explicit user instructions still take precedence. The execution protocol does not relax safety, scope, destructive-action, or evidence-honesty rules.
- Follow the concrete contributor procedures in `docs/guides/CONTRIBUTOR-WORKFLOW.md` after reading the constitution.
- Keep this file as a thin entrypoint. Do not duplicate the full constitution here.

## Keeper Runtime Boundary

- `docs/constitution.xml` is a product and development contract, not a Keeper runtime system prompt.
- The shared Keeper runtime prompt is `config/prompts/keeper.md`. Per-Keeper behavior also comes from the resolved `<base-path>/.masc/config/keepers/<name>.toml` `keeper.instructions`.
- Edit the contract and runtime prompts independently; changing one does not implicitly change the other.
- `<execution_protocol>` in `docs/constitution.xml` binds external coding-agent sessions, not Keeper lanes. A Keeper may build and test locally when its lane has a toolchain, but local results are never merge evidence: verdicts cite the current head's PR-check run, and targeted suites cite a `test.yml` targeted run.
