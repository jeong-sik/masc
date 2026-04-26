(** Property-based tests for [Prompt_registry_types.prompt_entry] yojson
    contract.

    Same root-cause class as #10356 / #10450 / #10463 (telemetry_eio) and the
    metrics_store_eio companion suite, but for a distinct persistence
    boundary: prompt entries are written as standalone JSON files in a
    user-configured prompts directory and reloaded across keeper restarts
    (see [Prompt_registry.load_from_disk]). A schema migration that adds a
    new option field, or a producer that elides [None]'s [metrics] key, must
    not silently drop the entry on reload.

    [prompt_entry] has one [option] field today ([metrics]). The PBT is
    still worth keeping: it pins the encoder/decoder contract so that
    future option fields inherit the same null/drop tolerance by default,
    rather than waiting for a silent-failure regression.

    Properties:
    1. [prop_roundtrip] — every encoded entry decodes back to itself.
    2. [prop_null_absorption] — replacing [metrics]'s value with [`Null]
       still yields a successful decode.
    3. [prop_drop_absorption] — removing the [metrics] key entirely still
       yields a successful decode. *)

module Types = Prompt_registry.Types

let opt_metrics =
  let open QCheck.Gen in
  oneof
    [ return None
    ; map
        (fun (usage_count, avg_score_int, last_used_int) ->
           Some
             Types.
               { usage_count
               ; avg_score = float_of_int avg_score_int /. 100.0
               ; last_used = float_of_int last_used_int
               })
        (triple nat_small (int_range 0 1000) nat_small)
    ]
;;

let gen_prompt_entry : Types.prompt_entry QCheck.Gen.t =
  let open QCheck.Gen in
  let* id = string_small in
  let* template = string_small in
  let* version = string_small in
  let* variables = list_size (int_range 0 3) string_small in
  let* metrics = opt_metrics in
  let* created_at = map float_of_int nat_small in
  let* deprecated = bool in
  return Types.{ id; template; version; variables; metrics; created_at; deprecated }
;;

let show_prompt_entry (e : Types.prompt_entry) : string =
  Yojson.Safe.pretty_to_string (Types.prompt_entry_to_yojson e)
;;

let arb_prompt_entry = QCheck.make ~print:show_prompt_entry gen_prompt_entry

let saturated_prompt_entry : Types.prompt_entry =
  { id = "code-review-v2"
  ; template = "Review {{x}}"
  ; version = "2.0"
  ; variables = [ "x" ]
  ; metrics = Some { usage_count = 7; avg_score = 0.82; last_used = 1.0 }
  ; created_at = 1_777_120_000.0
  ; deprecated = false
  }
;;

let null_field key fields =
  List.map (fun (k, v) -> if k = key then k, `Null else k, v) fields
;;

let drop_field key fields = List.filter (fun (k, _) -> k <> key) fields

let mutate_top f json =
  match json with
  | `Assoc top -> `Assoc (f top)
  | _ -> json
;;

let prop_roundtrip =
  QCheck.Test.make
    ~count:200
    ~name:"prompt_entry JSON round-trip"
    arb_prompt_entry
    (fun r ->
       let json = Types.prompt_entry_to_yojson r in
       match Types.prompt_entry_of_yojson json with
       | Ok r' -> r = r'
       | Error _ -> false)
;;

let prop_null_absorption =
  QCheck.Test.make
    ~count:1
    ~name:"prompt_entry: nulling [metrics] still parses"
    QCheck.unit
    (fun () ->
       let base = Types.prompt_entry_to_yojson saturated_prompt_entry in
       let mutated = mutate_top (null_field "metrics") base in
       match Types.prompt_entry_of_yojson mutated with
       | Ok _ -> true
       | Error _ -> false)
;;

let prop_drop_absorption =
  QCheck.Test.make
    ~count:1
    ~name:"prompt_entry: dropping [metrics] still parses"
    QCheck.unit
    (fun () ->
       let base = Types.prompt_entry_to_yojson saturated_prompt_entry in
       let mutated = mutate_top (drop_field "metrics") base in
       match Types.prompt_entry_of_yojson mutated with
       | Ok _ -> true
       | Error _ -> false)
;;

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ prop_roundtrip; prop_null_absorption; prop_drop_absorption ]
  in
  Alcotest.run "Prompt_registry PBT" [ "yojson contract", suite ]
;;
