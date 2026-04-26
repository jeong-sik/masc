(** Property-based tests for [Metrics_store_eio.task_metric] yojson contract.

    Same root-cause class as #10356 / #10450 / #10463 (telemetry_eio), but for
    a different persistence boundary: per-agent JSONL files at
    [.masc/metrics/{agent}/YYYY-MM.jsonl]. Files outlive any single MASC
    process — keeper restarts, agent rotations, and month-boundary rollovers
    all read records previously written by a different version. A producer
    that elides a [None] option key, or a future schema migration that adds
    a new option field, must not silently drop the entire row.

    [task_metric] has four [option] fields (completed_at, error_message,
    handoff_from, handoff_to). Annotating each with [\[@default None\]] makes
    [ppx_deriving_yojson] tolerate both `null` and missing keys. This suite
    pins that contract.

    Properties:
    1. [prop_roundtrip] — every encoded record decodes back to itself.
       Catches [@@deriving yojson] / [@default] drift between encoder and
       decoder on any of the four option fields.
    2. [prop_null_absorption] — for each option key, replacing its encoded
       value with [`Null] still yields a successful decode (with that field
       = [None]).
    3. [prop_drop_absorption] — same as (2) but the key is removed entirely.
       Future producers may elide [None] fields; readers must remain
       tolerant. *)

module Metrics_store_eio = Masc_mcp.Metrics_store_eio

let opt_string =
  let open QCheck.Gen in
  oneof [ return None; map (fun s -> Some s) string_small ]
;;

let opt_float =
  let open QCheck.Gen in
  oneof [ return None; map (fun n -> Some (float_of_int n)) nat_small ]
;;

let gen_task_metric : Metrics_store_eio.task_metric QCheck.Gen.t =
  let open QCheck.Gen in
  let* id = string_small in
  let* agent_id = string_small in
  let* task_id = string_small in
  let* started_at = map float_of_int nat_small in
  let* completed_at = opt_float in
  let* success = bool in
  let* error_message = opt_string in
  let* collaborators = list_size (int_range 0 3) string_small in
  let* handoff_from = opt_string in
  let* handoff_to = opt_string in
  return
    Metrics_store_eio.
      { id
      ; agent_id
      ; task_id
      ; started_at
      ; completed_at
      ; success
      ; error_message
      ; collaborators
      ; handoff_from
      ; handoff_to
      }
;;

let arb_task_metric =
  QCheck.make ~print:Metrics_store_eio.show_task_metric gen_task_metric
;;

(** Every option field name on [task_metric]. Keep in sync with the record. *)
let task_metric_option_keys =
  [ "completed_at"; "error_message"; "handoff_from"; "handoff_to" ]
;;

(** Saturated record — every option key is [Some _], so the encoded JSON
    contains the full key set we will mutate. *)
let saturated_task_metric : Metrics_store_eio.task_metric =
  { id = "metric-1"
  ; agent_id = "keeper-claude"
  ; task_id = "task-42"
  ; started_at = 1_777_120_000.0
  ; completed_at = Some 1_777_120_001.0
  ; success = false
  ; error_message = Some "boom"
  ; collaborators = [ "gemini"; "codex" ]
  ; handoff_from = Some "claude"
  ; handoff_to = Some "codex"
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
    ~name:"task_metric JSON round-trip"
    arb_task_metric
    (fun r ->
       let json = Metrics_store_eio.task_metric_to_yojson r in
       match Metrics_store_eio.task_metric_of_yojson json with
       | Ok r' -> r = r'
       | Error _ -> false)
;;

let prop_null_absorption =
  QCheck.Test.make
    ~count:1
    ~name:"task_metric: nulling any optional key still parses"
    QCheck.unit
    (fun () ->
       let base = Metrics_store_eio.task_metric_to_yojson saturated_task_metric in
       List.for_all
         (fun key ->
            let mutated = mutate_top (null_field key) base in
            match Metrics_store_eio.task_metric_of_yojson mutated with
            | Ok _ -> true
            | Error _ -> false)
         task_metric_option_keys)
;;

let prop_drop_absorption =
  QCheck.Test.make
    ~count:1
    ~name:"task_metric: dropping any optional key still parses"
    QCheck.unit
    (fun () ->
       let base = Metrics_store_eio.task_metric_to_yojson saturated_task_metric in
       List.for_all
         (fun key ->
            let mutated = mutate_top (drop_field key) base in
            match Metrics_store_eio.task_metric_of_yojson mutated with
            | Ok _ -> true
            | Error _ -> false)
         task_metric_option_keys)
;;

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ prop_roundtrip; prop_null_absorption; prop_drop_absorption ]
  in
  Alcotest.run "Metrics_store_eio PBT" [ "yojson contract", suite ]
;;
