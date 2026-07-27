(** Drift gate for the explicit current Keeper-meta key set. *)

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

let () =
  Alcotest.run
    "keeper_meta_current_keyset"
    [ ( "drift_gate"
      , [ Alcotest.test_case
            "runtime keys present"
            `Quick
            test_canonical_includes_runtime_keys
        ] )
    ]
;;
