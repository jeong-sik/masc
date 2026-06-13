(** Workspace_assertions — state inspection and assertion-based
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
    so the .mli surfaces the runtime explicitly. *)

(** {1 State snapshot} *)

(** Concrete record because {!Tool_workspace} field-constructs it
    when projecting an inspected context to the assertion engine. *)
type agent_state =
  { task_claimed : bool
  ; current_task_set : bool
  }

(** {1 Assertion taxonomy} *)

(** Closed variant — every match site must update on extension. *)
type assertion_kind =
  | Task_claimed (** Agent owns at least one claimed task. *)
  | Current_task_set (** [current_task] is set, fresh, and unambiguous. *)

(** [assertion_kind_to_string k] returns the canonical snake_case
    tag.  This is the operator-
    visible name in JSON output — runbook commands grep on these
    literals. *)
val assertion_kind_to_string : assertion_kind -> string

(** Canonical declaration order: [Task_claimed; Current_task_set].  Used by
    {!handle_check}'s default-list fallback when callers omit the
    [assertions] argument. *)
val all_assertion_kinds : assertion_kind list

(** [List.map assertion_kind_to_string all_assertion_kinds].
    Used in the "Unknown assertion: ... (expected one of: ...)"
    error message so operators see the exact accepted values. *)
val valid_assertion_strings : string list

(** [assertion_kind_of_string_lenient s] parses an assertion
    name from the canonical [assertion_kind_to_string] outputs.

    Returns [None] for any other input — the {!handle_check}
    handler reports unknown assertions as a passing failure with
    a fix hint listing {!valid_assertion_strings}.

    Adding a new accepted string requires touching this function
    explicitly; .mli hides the parse set on purpose so a future
    compatibility PR must extend the contract. *)
val assertion_kind_of_string_lenient : string -> assertion_kind option

(** {1 Tool entry point} *)

(** [handle_check ~inspect_state ctx args] is the [masc_check]
    JSON-RPC entry point.

    {2 Arguments}
    - [inspect_state ctx] resolves the current {!agent_state}.
      Caller-supplied so the handler is testable without a real
      context.
    - [args] is the raw JSON-RPC params.  Recognises an optional
      [assertions: [<string>...]] array; missing or non-list values
      fall back to the canonical defaults ([task_claimed] /
      [current_task_set]).  An empty list also falls back to
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
val handle_check
  :  inspect_state:(Workspace_types.context -> agent_state)
  -> tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result
