(** Tool_schemas_agent — MCP tool schemas for the [masc_agent*] family.

    Read from [config/tools/*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2) rather than built here.

    [masc_tool_schemas] only depends on [masc_types], so it cannot reach
    {!Tool_agent} for the [masc_agent_card] action values. They are still
    mirrored, now as the enum line in [config/tools/masc_agent_card.toml],
    and [test_agent_card_action_mirror] still reads the published schema and
    compares it against the owner's list, so drift fails there.

    Issues: #8501 (mirror pattern), #8372 (agent_status enum derivation),
    #8467/#8480/#8484/#8490/#8493 (related mirror+sync pattern). *)

type operation =
  | Agent_card
  | Agent_fitness
  | Get_metrics
[@@deriving enumerate]
(** Closed vocabulary routed by [Tool_agent.dispatch]. *)

val operations : operation list
(** Exhaustive stable-order projection of the agent operations. *)

val tool_name : operation -> string
(** Canonical wire name for an agent operation. *)

val operation_of_tool_name : string -> operation option
(** Parse a canonical agent wire name at the dispatch boundary. *)

val schema : operation -> Masc_domain.tool_schema
(** Declaration for an operation. Decoding refuses the boot on a missing or
    malformed file rather than publishing a partial surface. *)

val schemas : Masc_domain.tool_schema list
(** [schema] applied to every operation. *)
