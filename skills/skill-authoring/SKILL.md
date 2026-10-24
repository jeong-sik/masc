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

Prefer the direct tool for one call. A one-node composition can be useful when it
defines a reusable parameter or selected-output contract; make that contract
explicit instead of adding a wrapper with the same inputs and full result.

## 2. Instruction or composition

Write a **composition** when its inputs and dependencies can be declared as
parameters, literals or fields of earlier nodes' outputs. Write an
**instruction** when choosing the next step needs model judgement about an earlier
result. Passing a declared output field to the next node is still a composition.

The body alone decides the kind. No `toml composition` fence makes an instruction
Skill, served through `keeper_skill`. Exactly one fence makes a composition Skill,
exposed as the tool `keeper_compose_<name>`. Two fences, or one the parser rejects,
produce no tool: the body stays listed as an instruction Skill and the reason is a
diagnostic in `/api/v1/skills`. When a composition tool is missing, read that
diagnostic first.

## 3. What the Keeper sees

- **Instruction Skill:** the frontmatter `description`, one line in the `keeper_skill`
  Available list or capability search result. The body is read only when the Keeper
  opens it. Use the returned exact `reference.identity` and `content_revision`;
  a remembered name does not pin a source or revision.
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
  output schema (`keeper_spawn` declares `/handle`, `Read` declares `/path`). An opaque
  result cannot feed another node. The same rule applies to `[[compositions.exports]]`:
  give each export a unique `name`, a producer `node` and an RFC 6901 `pointer` into
  its declared output. For example, `name = "profile"`, `node = "lane"`,
  `pointer = "/profile"` selects the profile from a `keeper_lane_status` node.
- Params are scalar (`string`, `integer`, `number`, `boolean`) and all required. Every
  declared param is referenced by some node and every reference is declared; either
  mismatch rejects the composition.
- `execution = "async"` admits statically read-only ordinary leaves and the runtime's
  durable owned-job/Ask contracts. A general state-changing tool is not admitted
  merely because it is in the catalog. Read the current tool schema and admission
  diagnostic; inline file mutation does not imply durable async replay.
- Ready independent nodes marked `Concurrent` can run together. A `Serial` node is
  exclusive and preserves the serial schedule's order. `branch_failure_policy`
  defaults to `"fail_fast"`: a failure stops work that has not committed to run;
  already active nodes still settle. `"continue_independent"` lets independent
  branches finish, while failed producers' descendants and stopped serial chains
  stay blocked. The overall failure, cause and effect disposition remain visible.
- Without exports, a successful call returns `actions` keyed by `node_id`. With
  exports, it returns named selected fields, per-node availability and settlement,
  and an `execution_artifact` containing the complete original result. Use available
  fields before opening that artifact for missing details. JSON null is a value;
  an unavailable producer or missing field is reported separately.
- An async call returns a request receipt and completion notification. Continue
  independent work while it runs. The completion carries selected results and the
  original task/run references when they fit; use its exact `result_reference` for
  omitted details or an unavailable canonical result. Ordinary completion does not
  require repeated status polling. Failed, cancelled and unknown-effect results
  remain visible; do not replay a plan merely to recover its result.

## 5. Spell out node inputs

A node given `{}` or only its required field gets every default of the tool: page
size, projection, compact or full rows. A plan repeats the same input every time it
runs, so whatever size the defaults produce is paid on every run, and a default can
change without the Skill changing. Set `limit`, `compact`, `projection` or the tool's
equivalent explicitly on every node that has one.

## 6. Instruction body

- State the procedure's applicability and evidence, including the source revision
  and conditions that mattered. Before reusing a rule, check the current task,
  authoritative contract and tool schema. A past success does not override a later
  explicit instruction, a changed contract or a correction to its evidence.
- Describe repeatable decisions rather than preserving incidental lane setup,
  account names or a one-off stack size as universal prerequisites. For repository
  operations, point to the repository's current review and merge guide; do not
  freeze its API routes or approval policy from one historical run.
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
- **Task-specific composition:** pass the structured prepare input as
  `keeper_composition_run.recipe` to validate, save and execute in one call. Use
  `keeper_composition_prepare` separately when the plan needs inspection before
  execution, then run its exact draft reference. Both paths freeze the caller,
  plan and authorized tool/Skill contracts without publishing a Skill. Ordinary
  nodes take fixed `args` or an `input` template for upstream values, never both.
  Exact admitted child Skills take `skill_reference` and expose their declared
  exports. Supported inline Read/Edit/Write plans can overlap independent file
  scopes after inputs resolve; unsupported bindings keep the original schedule.
  Original handlers, authorization and publication recovery still apply.
  Durable async plans use the admitted read-only and owned-job/Ask contracts above.
  Preparation does not execute or activate a Skill, and is not a prerequisite for
  an existing composition or a direct tool.
- **Same draft to Skill:** for a reusable parameter-free plan, include `skill`
  metadata (`package_id`, `description`) during prepare. This freezes the validated
  `SKILL.md` bytes too. Use the same `draft_sha256` and `package_id` for
  `keeper_skill_validate` and `keeper_skill_publish`; publish also requires the
  evidence list below. Both refuse changed ownership, package or tool contracts.
  A task-only draft lacks Skill metadata and cannot use this publication path.
  Parameterized source remains authored explicitly rather than inferred from
  literal values. Generated fences carry the canonical plan in `plan_json`;
  this field cannot be mixed with separate nodes, params, exports or failure policy.
- **Keeper publish:** `keeper_skill_publish` takes `package_id`, the whole `SKILL.md`
  as `source_text`, and a non-empty `evidence` list (Memory fact ids, turn or tool
  call references). It creates the package in the `project-agents` source and
  republishes the catalog; the returned `reference` is what later turns find, except a Keeper whose meta declares a `skills` list sees it only once that list names it. An
  existing package in `project-agents` is refused as `package_already_exists`.
  `created_but_shadowed` means a package earlier in the catalog (usually in an
  earlier source) already declares the name: yours is written and published, but
  turns that list Skills by name see `winner`, and only a Task that pins your
  exact reference gets yours.
  `created_but_unpublished` means the file was written but the catalog was not
  republished. Operators delete published Skills through the editor.
- Editor creation never overwrites an existing package. Saving an edit checks that the file
  still holds the revision you loaded, validates the document and the composition
  plan, writes it, and republishes the workspace snapshot. `saved_but_unpublished`
  means the file changed but the snapshot did not; reload after publication recovers.
