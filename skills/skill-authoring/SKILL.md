---
name: skill-authoring
description: "Decides whether recurring work belongs in a Tool, a composition Skill, an instruction Skill or nowhere, and writes a SKILL.md that the MASC parser admits and a Keeper picks at the right moment. Use when creating or changing a MASC Skill from the TUI Tools screen, the Dashboard Skill Studio or a skills source directory, and when a Skill is not being used or its composition fails to load."
---

# Skill authoring

## 1. Decide where the work belongs

| What is needed | Where it goes |
|---|---|
| A capability that does not exist yet, a schema, permission or typed error contract, or a call to an outside system | A Tool |
| A fixed chain of tool calls with no judgement between the steps | A composition Skill |
| A judgement at a fork, a known trap, or an order of steps that needs reading | An instruction Skill |
| Something the runtime already puts in the turn's first request (the current time arrives there as `[Temporal]`; a request after tool results does not repeat it) | Nothing |
| A procedure that steps around a tool or harness defect | No Skill. Fix the defect |

A Skill that works around a defect turns the defect into the documented way of working,
and the next author copies it. Fix the tool instead.

A composition with one node is the same as calling that tool directly, so it is not
worth a Skill.

## 2. Instruction or composition

Write a **composition** when every node input is known before the plan runs: a
declared parameter, a literal, or a field of an earlier node's output. Write an
**instruction** when a step depends on reading what an earlier step returned.

The body alone decides the kind. No `toml composition` fence makes an instruction
Skill, served through `keeper_skill`. Exactly one fence makes a composition Skill,
exposed as the tool `keeper_compose_<name>`. Two fences, or one the parser rejects,
produce no tool: the body stays listed as an instruction Skill and the reason is a
diagnostic in `/api/v1/skills`. When a composition tool is missing, read that
diagnostic first.

## 3. What the Keeper sees

- **Instruction Skill:** the frontmatter `description`, one line in the `keeper_skill`
  Available list. The body is read only when the Keeper opens it.
- **Composition Skill:** only the fence's `description` and each param's `description`.
  The prose around the fence never reaches the Keeper. Put when to use it, when not
  to, and how to read the result in that TOML `description`. Keep the frontmatter
  `description` identical to it.

Write a description as what it does, then when to use it, with the words a Keeper
would have in mind first. Third person. At most 1024 characters. If a neighbouring
Skill or tool covers a nearby case, name it and say which case goes where. Quote a
YAML description that contains `:`, `#`, or a leading backtick.

## 4. Composition rules the parser enforces

- The directory name, frontmatter `name` and composition `name` are the same string:
  lowercase letters, digits and single hyphens, at most 49 bytes (the tool name
  `keeper_compose_<name>` has a 64-byte limit).
- Every node `tool` is a registered tool on the Keeper surface. Check each input field
  name, type and enum against the tool's `config/tools/<tool>.toml`. Inputs are
  validated when the composition is called, not when the Skill loads, so a misspelled
  field loads cleanly and fails on first use. An input made only of literals and
  params is checked before any node runs; an input that reads another node's output
  is checked when its node runs, after the nodes before it.
- `kind = "output"` reads a field of an earlier node only when that tool declares a JSON
  output schema (`keeper_spawn` declares `/handle`). Most tools do not; their output
  cannot feed another node.
- Params are scalar (`string`, `integer`, `number`, `boolean`) and all required. Every
  declared param is referenced by some node and every reference is declared; either
  mismatch rejects the composition.
- `execution = "async"` needs every node to be statically read-only.
- In one dependency layer, only tools marked `Concurrent` run together; a `Serial` tool
  runs alone. When a node fails, the call fails with that node as `cause` and the
  batches after it do not run. A successful call returns `actions`, one per node, keyed
  by `node_id`.

## 5. Spell out node inputs

A node given `{}` or only its required field gets every default of the tool: page
size, projection, compact or full rows. A plan repeats the same input every time it
runs, so whatever size the defaults produce is paid on every run, and a default can
change without the Skill changing. Set `limit`, `compact`, `projection` or the tool's
equivalent explicitly on every node that has one.

## 6. Instruction body

- Keep `SKILL.md` under 500 lines. Put long material in `references/<file>.md`, one
  level below the Skill root, and say in the body when to read it. The Keeper reads
  it with `keeper_skill` and `file = "references/<file>.md"`.
- Give one default way to do the job, with the exception that leaves it. A menu of
  options moves the decision back to the Keeper.
- Give the reason for a rule instead of writing ALWAYS or NEVER. A reason also tells
  the Keeper when the rule does not apply.
- Keep a section of traps: what went wrong before and what to do instead.
- Cut what the model already knows. Ask of each sentence whether the Keeper would get
  the job wrong without it.

## 7. Creating and editing

- **TUI, Tools screen:** `J`/`K` select a published Skill. `c` opens a new instruction
  Skill in `$EDITOR`, `C` a composition starter. `e` edits the selected exact revision.
  `Enter` loads that revision's evidence: recorded activations and the latest completed
  composition run.
- **Dashboard, Skills:** **Skill Studio** → **+ New Skill**, choose a writable source,
  the kind, a name, a description and a body, then **Create + publish**. Expand a row
  and use **Edit source** to change it.
- **Keeper draft:** write a proposed `SKILL.md` in the sandbox with `Write`, export
  it with `keeper_artifact_transfer` (`action="export"`), then pass the returned
  `artifact` object and proposed directory name `package_id` to `keeper_skill_validate`.
  This checks document and composition-plan rules; it does not execute or publish.
  Writing the draft does not update the catalog.
- **Keeper publish:** `keeper_skill_publish` takes `package_id`, the whole `SKILL.md`
  as `source_text`, and a non-empty `evidence` list (Memory fact ids, turn or tool
  call references). It creates the package in the `project-agents` source and
  republishes the catalog; the returned `reference` is what later turns find, except a Keeper whose meta declares a `skills` list sees it only once that list names it. An
  existing name is refused as `package_already_exists`. `created_but_unpublished`
  means the file was written but the catalog was not republished. Operators delete
  published Skills through the editor.
- Editor creation never overwrites an existing package. Saving an edit checks that the file
  still holds the revision you loaded, validates the document and the composition
  plan, writes it, and republishes the workspace snapshot. `saved_but_unpublished`
  means the file changed but the snapshot did not; reload after publication recovers.
