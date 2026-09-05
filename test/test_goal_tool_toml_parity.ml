(** The three Goal tool definitions moved out of an OCaml literal into
    config/tools/masc_goal_*.toml. This pins what they emit.

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

let published =
  [ ( "masc_goal_list"
  , "List shared planning goals, optionally filtered by explicit lifecycle phase."
  , "{\"type\":\"object\",\"properties\":{\"phase\":{\"type\":\"string\",\"enum\":[\"executing\",\"verifying\",\"completed\",\"dropped\"],\"description\":\"Optional explicit Goal lifecycle phase filter\"}},\"additionalProperties\":false}" )
  ; ( "masc_goal_upsert"
  , "Create or update flat Goal metadata.

Creation requires a measurable success condition: metric and target_value (RFC-0387 B1). Use masc_goal_transition for lifecycle changes."
  , "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"metric\":{\"type\":\"string\",\"description\":\"What measures this goal, and where that measurement can be read: a file path, a recorded command output, or a URL. The completion judge opens exactly what this names — it cannot list directories or search, so a metric that names no observable is refused as unmeasurable rather than hunted for. Required (non-blank) when the upsert creates a new goal (RFC-0387 B1); optional on update.\"},\"target_value\":{\"type\":\"string\",\"description\":\"The value the metric has to reach, comparable against what the metric's source actually reads: a number, a count, a threshold. The judge approves only when it read the measurement and it reaches this. Required (non-blank) when the upsert creates a new goal (RFC-0387 B1); optional on update.\"},\"due_date\":{\"type\":\"string\"},\"priority\":{\"type\":\"integer\"}},\"additionalProperties\":false}" )
  ; ( "masc_goal_transition"
  , "Apply an explicit Goal lifecycle transition (RFC-0387 stage 2 gate).

request_complete no longer completes the Goal directly: it moves executing -> verifying and persists a durable proof request. Verifier verdicts are application-owned typed commits and are deliberately not accepted by this MCP tool. A Goal whose criterion was judged unreachable is refused on request_complete."
  , "{\"type\":\"object\",\"properties\":{\"goal_id\":{\"type\":\"string\"},\"action\":{\"type\":\"string\",\"enum\":[\"request_complete\",\"drop\",\"reopen\"]},\"note\":{\"type\":\"string\"}},\"required\":[\"goal_id\",\"action\"],\"additionalProperties\":false}" )
  ]
;;

let test_schemas_match_their_declarations () =
  let emitted =
    Tool_schemas_workspace_extra.schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) ->
      schema.name, schema.description, Yojson.Safe.to_string schema.input_schema)
  in
  check int "every declared Goal tool is published" (List.length published)
    (List.length emitted);
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
