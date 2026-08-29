(** Byte-identity pins for the three agent declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off the OCaml literals in
    [Tool_schemas_agent] before the files existed, so this suite passing after
    the move is what proves the files say the same thing. What a Keeper
    receives must not change because a declaration moved.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
  [ ( {|masc_agent_fitness|}
    , {|Get fitness scores for agents based on completion rate, reliability, and speed metrics.|}
    , {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Optional: Get fitness for specific agent. If omitted, returns all agents.","type":"string"},"days":{"default":7,"description":"Number of days to analyze (default: 7)","type":"integer"}},"type":"object"}|}
    )
  ; ( {|masc_get_metrics|}
    , {|Fetch raw performance metrics for an agent: task completion, timing, error rates, collaboration history.|}
    , {|{"additionalProperties":false,"properties":{"agent_name":{"description":"Agent name to get metrics for","type":"string"},"days":{"default":7,"description":"Number of days of history (default: 7)","maximum":90,"minimum":1,"type":"integer"}},"required":["agent_name"],"type":"object"}|}
    )
  ; ( {|masc_agent_card|}
    , {|Return the MASC server agent card and optional live agent summary.|}
    , {|{"additionalProperties":false,"properties":{"action":{"default":"get","description":"Card action: get or refresh.","enum":["get","refresh"],"type":"string"},"agent_name":{"description":"Optional live agent name to include in the card.","type":"string"}},"type":"object"}|}
    )
  ]
;;

let published = Tool_schemas_agent.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failf "%s is absent from Tool_schemas_agent.schemas" name
;;

let test_each () =
  List.iter
    (fun (name, description, schema_json) ->
      let s = find name in
      check string (name ^ " description") description s.description;
      check string
        (name ^ " input_schema")
        (Yojson.Safe.to_string (sorted (Yojson.Safe.from_string schema_json)))
        (Yojson.Safe.to_string (sorted s.input_schema)))
    expected
;;

(* The list is a published surface: a tool appearing or vanishing changes what
   a Keeper is offered, so the count is pinned too. *)
let test_no_extras () =
  check int "published count" (List.length expected) (List.length published)
;;

let () =
  run
    "agent tool toml parity"
    [ ( "parity"
      , [ test_case "each declaration is byte-identical" `Quick test_each
        ; test_case "no tool appeared or vanished" `Quick test_no_extras
        ] )
    ]
;;
