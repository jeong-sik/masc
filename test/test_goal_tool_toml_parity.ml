(** The Goal tool definitions live in config/tools/masc_goal_*.toml. Goal
    schemas are loaded for the closed Goal_name variant, so both the embedded
    TOML file set and the per-tool output pins must stay in sync with it.

    The first three (list, transition, upsert) moved out of an OCaml literal.

    The move was proven byte-identical by dumping both implementations and
    diffing: structure, key order, enum arrays, [required] and
    [additionalProperties] all matched, and the only difference was the two
    [masc_goal_upsert] field descriptions the move deliberately rewrote. This
    test is that dump, frozen — a TOML edit that changes the published shape
    fails here instead of reaching an MCP client.

    The [phase] and [action] enums are literals in TOML because nothing there
    can read an OCaml variant. Their agreement with [Goal_phase.all] and
    [Goal_phase.Public_action.all] is [test_enum_mirror_sync]'s job, not this
    one's; this only pins what the file says. *)

open Alcotest

(* The order is Tool_name.Goal_name.all, the variant's declaration order
   since #33583 routed the goal tools on their closed vocabulary. *)
let published =
  [ ( "masc_goal_list"
  , "List shared planning goals, optionally filtered by explicit lifecycle phase."
  , "{\"type\":\"object\",\"properties\":{\"phase\":{\"type\":\"string\",\"enum\":[\"executing\",\"verifying\",\"awaiting_confirmation\",\"completed\",\"dropped\"],\"description\":\"Optional explicit Goal lifecycle phase filter\"}},\"additionalProperties\":false}" )
  ; ( "masc_goal_measure"
  , "Record an explicit observation of a Goal's declared metric. Supply the exact\ncurrent criterion_revision from masc_goal_list, the observed value, and\nsupporting evidence. This records a reported value; it does not prove\nthat the target was reached or change the Goal phase."
  , "{\"type\":\"object\",\"properties\":{\"goal_id\":{\"type\":\"string\"},\"criterion_revision\":{\"type\":\"string\"},\"observed_value\":{\"type\":\"string\"},\"evidence\":{\"type\":\"string\",\"description\":\"An Evidence Reference: artifact:<producer-root-relative-path>, note:<text>, board:<post-id>, or fusion:<run-id>. Any other form is rejected.\"}},\"required\":[\"goal_id\",\"criterion_revision\",\"observed_value\",\"evidence\"],\"additionalProperties\":false}" )
  ; ( "masc_goal_transition"
  , "Apply an explicit Goal lifecycle transition (RFC-0387 stage 2 gate).

request_complete moves executing -> verifying and persists a durable proof request; repeated while verifying, it re-arms that request. drop and reopen also leave verifying. Verifier verdicts are not accepted by this MCP tool. A Goal whose criterion was judged unreachable is refused on request_complete."
  , "{\"type\":\"object\",\"properties\":{\"goal_id\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"request_complete\",\"drop\",\"reopen\"]},\"note\":{\"type\":\"string\"},\"evidence_refs\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"For request_complete: explicit board:<post_id> or fusion:<run_id> references. Their exact source is captured with this proof request. Omit on retry to keep the submitted snapshot; supplying changed evidence creates a new request.\"}},\"required\":[\"goal_id\",\"action\"],\"additionalProperties\":false}" )
  ; ( "masc_goal_upsert"
  , "Create or update flat Goal metadata.

Creation requires a measurable success condition: metric and target_value (RFC-0387 B1). Use masc_goal_transition for lifecycle changes."
  , "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"metric\":{\"type\":\"string\",\"description\":\"What measures this goal, and where that measurement can be read: a file path, a recorded command output, or a URL. The completion judge opens exactly what this names — it cannot list directories or search, so a metric that names no observable is refused as unmeasurable rather than hunted for. Required (non-blank) when the upsert creates a new goal (RFC-0387 B1); optional on update.\"},\"target_value\":{\"type\":\"string\",\"description\":\"The value the metric has to reach, comparable against what the metric's source actually reads: a number, a count, a threshold. The judge approves only when it read the measurement and it reaches this. Required (non-blank) when the upsert creates a new goal (RFC-0387 B1); optional on update.\"},\"due_date\":{\"type\":\"string\"},\"priority\":{\"type\":\"integer\"}},\"additionalProperties\":false}" )
  ]
;;

(* Names are derived from the closed variant; descriptions and schemas stay pinned. *)
let published_names =
  List.map (fun (name, _, _) -> name) published
;;

let declared_names =
  Tool_name.Goal_name.all |> List.map Tool_name.Goal_name.to_string
;;

let test_schemas_match_their_declarations () =
  let emitted =
    Tool_schemas_workspace_extra.schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) ->
      schema.name, schema.description, Yojson.Safe.to_string schema.input_schema)
  in
  let emitted_names = List.map (fun (name, _, _) -> name) emitted in
  let embedded_goal_names =
    Embedded_config.file_list
    |> List.filter (fun path ->
      Filename.dirname path = "tools"
      && Filename.check_suffix path ".toml"
      && String.starts_with ~prefix:"masc_goal_" (Filename.basename path))
    |> List.map (fun path -> Filename.remove_extension (Filename.basename path))
    |> List.sort String.compare
  in
  check (list string) "embedded Goal TOMLs match Goal_name variants"
    (List.sort String.compare declared_names)
    embedded_goal_names;
  List.iter
    (fun name ->
      check bool (name ^ ": declared Goal tool has a schema pin") true
        (List.mem name published_names))
    declared_names;
  List.iter
    (fun name ->
      check bool (name ^ ": TOML declaration names a Goal tool") true
        (List.mem name declared_names))
    emitted_names;
  check (list string) "schema pins follow Goal tool declaration order" declared_names
    published_names;
  check (list string) "TOML Goal tools match the pinned names" published_names
    emitted_names;
  List.iter2
    (fun (name, description, input_schema) (name', description', input_schema') ->
      check string "tool name" name name';
      check string (name ^ ": description") description description';
      check string (name ^ ": input_schema") input_schema input_schema')
    published
    emitted
;;

let () =
  run
    "goal_tool_toml_parity"
    [ ( "declarations"
      , [ test_case
            "published schemas match their TOML declarations"
            `Quick
            test_schemas_match_their_declarations
        ] )
    ]
;;
