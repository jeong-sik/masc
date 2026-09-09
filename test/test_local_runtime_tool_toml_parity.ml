(** The publication order of [Tool_schemas_local_runtime.schemas] and the
    clamped bounds those schemas publish.

    The descriptions and schemas this suite also pinned were literals read off
    the same published values before the declarations moved into
    [config/tools/*.toml] -- one producer against a snapshot of itself. Those
    cases are gone.

    The bounds case used to substring-search the literal in this file, so it
    asserted a property of its own fixture and could not see the published
    schema at all. It reads [published] and parses the JSON now.

    Order is not in the TOML. It is the order of the OCaml list, and #34379 is
    the open question about what changed it, so it stays. *)

open Alcotest


(* name, description, input_schema (keys sorted) *)
let expected =
  [ "masc_runtime_verify"
  ; "masc_runtime_ollama_probe"
  ]
;;

let published = Tool_schemas_local_runtime.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_schemas_local_runtime.schemas")
;;



(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_local_runtime.schemas in order"
    expected
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

(* The clamp and the schema have to name the same numbers. Before this, the
   schema said only `type: integer` for both while the code quietly folded a
   larger value into range: a model asking for probe_runs = 10 got 4, with no
   refusal and nothing on the wire saying so. The literals below are the ones
   in tool_local_runtime_probe.ml; a clamp that moves without the schema
   moving fails here (#25006). *)
let test_clamped_params_publish_their_bounds () =
  let schema = (find "masc_runtime_ollama_probe").input_schema in
  let bound param key =
    match schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) ->
         (match List.assoc_opt param properties with
          | Some (`Assoc entry) ->
            (match List.assoc_opt key entry with
             | Some (`Int value) -> Some value
             | _ -> None)
          | _ -> None)
       | _ -> None)
    | _ -> None
  in
  List.iter
    (fun (param, key, value) ->
       check
         (option int)
         (Printf.sprintf "masc_runtime_ollama_probe %s %s" param key)
         (Some value)
         (bound param key))
    [ "probe_runs", "maximum", 4
    ; "probe_runs", "minimum", 1
    ; "max_tokens", "maximum", 128
    ; "max_tokens", "minimum", 1
    ]
;;

let () =
  run
    "local_runtime_tool_toml_parity"
    [ ( "surface"
      , [ test_case "published order" `Quick test_the_published_order_is_unchanged
        ; test_case "clamped bounds" `Quick test_clamped_params_publish_their_bounds
        ] )
    ]
;;
