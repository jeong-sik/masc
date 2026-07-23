(** Drift gate for [canonical_keeper_meta_key_names].

    Persisted keeper meta JSON is runtime-only; config fields live in TOML.
    The reflection-via-roundtrip pattern in [keeper_meta_json.ml] derives the
    canonical runtime key list by parsing a minimal seed JSON and
    re-serialising it. *)

open Masc

(* [shared_memory_scope] removed in commit e3f4d82c60 ("refactor: remove
   shared_memory_scope and all related logic"). Drop from the drift gate so
   it does not pin a key the JSON serialisation no longer emits. *)
let target_keys =
  [ "trace_history"
  ; "instructions"
  ; "last_runtime_attempt"
  ; "current_task_id"
  ; "keeper_id"
  ; "oas_env"
  ; "meta_version"
  ]

let test_canonical_includes_runtime_keys () =
  let canonical = Keeper_meta_json.canonical_keeper_meta_key_names in
  List.iter
    (fun key ->
      Alcotest.(check bool)
        (Printf.sprintf
           "canonical_keeper_meta_key_names contains %s"
           key)
        true
        (List.mem key canonical))
    target_keys

let test_meta_to_json_redacts_last_model_used () =
  let json =
    `Assoc
      [ "name", `String "meta-redaction"
      ; "agent_name", `String "meta-redaction"
      ; "trace_id", `String "trace-meta-redaction"
      ; "last_model_used", `String "openai:gpt-5.4"
      ]
  in
  match Keeper_meta_json.meta_of_json json with
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
  | Ok meta ->
    let emitted = Keeper_meta_json.meta_to_json meta in
    let has_last_model_used =
      match emitted with
      | `Assoc fields -> List.mem_assoc "last_model_used" fields
      | _ -> Alcotest.fail "meta_to_json must emit an object"
    in
    Alcotest.(check bool) "legacy last_model_used key is redacted on write" false
      has_last_model_used

(* Regression: the persisted identity-counter JSON key stays ["generation"]
   even though the OCaml field is [nonce] (every other JSON surface — keeper
   status, dashboard — already keeps this key while reading [rt.nonce]).
   Renaming the wire key would load every pre-rename on-disk meta file as
   [nonce = 0] and silently reset the fencing counter. The round-trip pins both
   sides: a [generation:7] input must load its counter (not default to 0 when a
   ["nonce"] key is absent) and re-serialise under ["generation"] (not
   ["nonce"]). *)
let test_persisted_identity_counter_key_is_generation () =
  let input =
    `Assoc
      [ "name", `String "meta-wire-key"
      ; "agent_name", `String "meta-wire-key"
      ; "trace_id", `String "trace-wire-key"
      ; "generation", `Int 7
      ]
  in
  let meta =
    match Keeper_meta_json.meta_of_json input with
    | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
    | Ok meta -> meta
  in
  (match Keeper_meta_json.meta_to_json meta with
   | `Assoc fields ->
     Alcotest.(check bool)
       "writer emits the generation key"
       true
       (List.mem_assoc "generation" fields);
     Alcotest.(check bool)
       "writer does not emit a nonce key"
       false
       (List.mem_assoc "nonce" fields);
     (match List.assoc "generation" fields with
      | `Int n ->
        Alcotest.(check int)
          "generation:7 round-trips (reader did not default the absent nonce key to 0)"
          7
          n
      | _ -> Alcotest.fail "generation value must be a JSON integer")
   | _ -> Alcotest.fail "meta_to_json must emit an object")
;;

let () =
  Alcotest.run
    "keeper_meta_canonical_seed"
    [ ( "drift_gate"
      , [ Alcotest.test_case
            "runtime keys present"
            `Quick
            test_canonical_includes_runtime_keys
        ; Alcotest.test_case
            "meta_to_json redacts last_model_used"
            `Quick
            test_meta_to_json_redacts_last_model_used
        ; Alcotest.test_case
            "persisted identity counter key is generation"
            `Quick
            test_persisted_identity_counter_key_is_generation
        ] )
    ]
;;
