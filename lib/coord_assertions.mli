(** Coord_assertions — state inspection and assertion-based
    verification.

    Defines the boolean snapshot of agent state ({!agent_state}),
    the closed variant of supported assertions ({!assertion_kind}),
    and the {!handle_check} entry point that the [masc_check] tool
    invokes via JSON-RPC.

    The {!assertion_kind} variant is the SSOT for the assertion
    taxonomy.  Adding a new assertion requires:
    1. Extending {!assertion_kind} (forces every match site to
       compile).
    2. Adding the canonical name to {!assertion_kind_to_string}.
    3. Adding the lenient-parse aliases to
       {!assertion_kind_of_string_lenient}.
    4. Adding the operator runbook entry referenced by the
       fix-hint.

    All of step 2-4 are wired through this module's hidden helpers
    so the .mli surfaces the cascade explicitly. *)

(** {1 State snapshot} *)

type agent_state = {
  room_set : bool;
  joined : bool;
  task_claimed : bool;
  current_task_set : bool;
  worktree_active : bool;
}
(** Concrete record because {!Tool_coord} field-constructs it
    when projecting an inspected context to the assertion engine
    ([Coord_assertions.room_set = s.room_set]).  Hiding would
    break the type seam. *)

(** {1 Assertion taxonomy} *)

type assertion_kind =
  | Room_set         (** Project root configured (legacy aliases: [namespace_ready], [project_ready]). *)
  | Joined           (** Agent has joined the project namespace. *)
  | Task_claimed     (** Agent owns at least one claimed task. *)
  | Current_task_set (** [current_task] is set, fresh, and unambiguous. *)
  | Worktree_active  (** Agent is in an isolated branch worktree. *)
(** Closed variant — every match site must update on extension.
    [Tool_coord] type-aliases this exact shape with the same five
    constructors, so the cross-module re-export is structurally
    pinned. *)

val assertion_kind_to_string : assertion_kind -> string
(** [assertion_kind_to_string k] returns the canonical snake_case
    tag (e.g. [Room_set -> "room_set"]).  This is the operator-
    visible name in JSON output — runbook commands grep on these
    literals. *)

val all_assertion_kinds : assertion_kind list
(** Canonical declaration order: [Room_set; Joined; Task_claimed;
    Current_task_set; Worktree_active].  Used by
    {!handle_check}'s default-list fallback when callers omit the
    [assertions] argument. *)

val valid_assertion_strings : string list
(** [List.map assertion_kind_to_string all_assertion_kinds].
    Used in the "Unknown assertion: ... (expected one of: ...)"
    error message so operators see the exact accepted values. *)

val assertion_kind_of_string_lenient : string -> assertion_kind option
(** [assertion_kind_of_string_lenient s] parses an assertion
    name leniently: in addition to the canonical
    [assertion_kind_to_string] outputs, it accepts the legacy
    aliases [namespace_ready] / [project_ready] (both -> [Room_set]).

    Returns [None] for any other input — the {!handle_check}
    handler reports unknown assertions as a passing failure with
    a fix hint listing {!valid_assertion_strings}.

    Adding a new alias requires touching this function explicitly;
    .mli hides the alias set on purpose so a future "be more
    lenient" PR must extend the contract. *)

(** {1 Tool entry point} *)

val handle_check :
  inspect_state:(Coord_types.context -> agent_state) ->
  Coord_types.context ->
  Yojson.Safe.t ->
  Coord_types.tool_result
(** [handle_check ~inspect_state ctx args] is the [masc_check]
    JSON-RPC entry point.

    {2 Arguments}
    - [inspect_state ctx] resolves the current {!agent_state}.
      Caller-supplied so the handler is testable without a real
      context.
    - [args] is the raw JSON-RPC params.  Recognises an optional
      [assertions: [<string>...]] array; missing or non-list values
      fall back to the canonical defaults (the five
      [project_ready / joined / task_claimed / current_task_set /
      worktree_active] strings — note [project_ready] is the legacy
      alias for [room_set]).  An empty list also falls back to
      defaults so callers cannot accidentally pass nothing.

    {2 Return value}
    [{ success = true; message = json_string }] — [success] is
    always [true] (the handler does not use it to signal failure;
    failure is encoded inside the JSON body).  The JSON body has
    shape:
    {[
      `Assoc [
        ("assertions", `List [<per-assertion result>...]);
        ("all_passed", `Bool <all assertions passed>);
        ("fix_hint", `String | `Null);
      ]
    ]}
    [fix_hint] is the first failing assertion's hint; when all
    pass, [fix_hint] is [`Null]. *)
