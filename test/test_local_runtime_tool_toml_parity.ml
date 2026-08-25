(** Byte-identity pins for the local runtime tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_schemas_local_runtime.schemas] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    The operation vocabulary stays in OCaml: Local_runtime_tool_policy maps
    each operation to an execution policy and a model-exposure decision, and
    those are code, not declarations. Only the name, description and
    parameters move.

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
    [ {|masc_runtime_verify|}, {|Admin-only contract probe for the optional typed local OpenAI-compatible runtime pool used for local benchmarks. It issues one real chat completion per selected endpoint and may load models or change warm/cache state, so it is not read-only or idempotent. An explicit runtime_pool that matches no endpoint fails closed. Returns reachability, chat-completions contract status, model match, slots, ctx, configured capacity, active slots, and local blocker codes. Missing local discovery does not assess or block official-client, CLI, or remote Keeper provider lanes.|}, {|{"properties":{"expected_ctx":{"type":"integer"},"expected_model":{"type":"string"},"expected_slots":{"type":"integer"},"runtime_pool":{"type":"string"}},"type":"object"}|}
    ; {|masc_runtime_ollama_probe|}, {|Admin-only native Ollama timing probe with repeated /api/generate calls. It may load a model and change warm/cache state, so it is not read-only or idempotent. Returns loaded models from /api/ps, per-run load/prompt-eval/generation timings, tok/sec estimates, and a timing-based repeated-prefix reuse inference. This does not expose direct KV occupancy or hit-rate.|}, {|{"properties":{"generate_when_unloaded":{"type":"boolean"},"keep_alive":{"type":"string"},"max_tokens":{"description":"Output tokens per generate run. Values outside [1, 128] are rejected, not reduced.","maximum":128,"minimum":1,"type":"integer"},"model":{"type":"string"},"probe_runs":{"description":"Generate runs per probe. Values outside [1, 4] are rejected, not reduced.","maximum":4,"minimum":1,"type":"integer"},"prompt":{"type":"string"},"ps_timeout_sec":{"description":"Timeout for the /api/ps state read in seconds. Values outside [1, 30] are rejected, not reduced.","maximum":30,"minimum":1,"type":"integer"},"run_generate":{"type":"boolean"},"server_url":{"type":"string"},"think":{"description":"Boolean shorthand for think_mode. false disables reasoning-mode thinking; true enables it.","type":"boolean"},"think_mode":{"description":"Think mode choice. auto lets model decide; disabled skips reasoning; enabled forces it.","enum":["auto","disabled","enabled"],"type":"string"},"think_policy":{"description":"Adaptive thinking policy for Ollama reasoning models. auto defaults to response-oriented non-thinking probes; enabled measures thinking path explicitly.","type":"string"},"timeout_sec":{"description":"Explicit probe timeout in seconds. Every positive value is passed through unchanged.","minimum":1,"type":"integer"}},"type":"object"}|}
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

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_local_runtime.schemas in order"
    (List.map (fun (name, _, _) -> name) expected)
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

(* The clamp and the schema have to name the same numbers. Before this, the
   schema said only `type: integer` for both while the code quietly folded a
   larger value into range: a model asking for probe_runs = 10 got 4, with no
   refusal and nothing on the wire saying so. The literals below are the ones
   in tool_local_runtime_probe.ml; a clamp that moves without the schema
   moving fails here (#25006). *)
let test_clamped_params_publish_their_bounds () =
  let schema =
    match
      List.find_opt
        (fun (name, _, _) -> String.equal name "masc_runtime_ollama_probe")
        expected
    with
    | Some (_, _, schema) -> schema
    | None -> Alcotest.fail "masc_runtime_ollama_probe is not in the pinned list"
  in
  let mentions needle =
    let rec search from =
      from + String.length needle <= String.length schema
      && (String.sub schema from (String.length needle) = needle
          || search (from + 1))
    in
    search 0
  in
  List.iter
    (fun (param, bound) ->
       Alcotest.(check bool)
         (Printf.sprintf "%s publishes %s" param bound)
         true
         (mentions bound))
    [ "probe_runs", {|"maximum":4|}
    ; "probe_runs", {|"minimum":1|}
    ; "max_tokens", {|"maximum":128|}
    ; "max_tokens", {|"minimum":1|}
    ]
;;

let () =
  run
    "local_runtime_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case
            "clamped params publish their bounds"
            `Quick
            test_clamped_params_publish_their_bounds
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ] )
    ]
;;
