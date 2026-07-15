(* Tier K4 — keeper-side tool-emission hook implementation. *)

type accumulator = {
  mutable items : Yojson.Safe.t list;
  mutex : Stdlib.Mutex.t;
  keeper_name : string option;
    (* Tier K6 — set by [accumulator_for_keeper] so the [push]
       function can emit a per-keeper Otel_metric_store counter without
       routing the name through every call site. [None] for the
       process-wide [global_accumulator] and for test-created
       accumulators (no metric emitted in those cases). *)
}

let create_accumulator () =
  { items = []
  ; mutex = Stdlib.Mutex.create ()
  ; keeper_name = None
  }

let create_accumulator_for ~keeper_name =
  { items = []
  ; mutex = Stdlib.Mutex.create ()
  ; keeper_name = Some keeper_name
  }

let push acc (json : Yojson.Safe.t) : unit =
  Stdlib.Mutex.lock acc.mutex;
  acc.items <- json :: acc.items;
  Stdlib.Mutex.unlock acc.mutex;
  (* Tier K6 — emit per-keeper push counter. Counter is incremented
     OUTSIDE the accumulator mutex so the metric write does not
     extend the critical section. The [keeper_name] field is read-
     only so reading after unlock is race-free. *)
  match acc.keeper_name with
  | None -> ()
  | Some name ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ToolEmissionPushes)
      ~labels:[ ("keeper", name) ]
      ()

let drain acc : Yojson.Safe.t list =
  Stdlib.Mutex.lock acc.mutex;
  let items = List.rev acc.items in
  acc.items <- [];
  Stdlib.Mutex.unlock acc.mutex;
  items

let snapshot acc : Yojson.Safe.t list =
  Stdlib.Mutex.lock acc.mutex;
  let items = List.rev acc.items in
  Stdlib.Mutex.unlock acc.mutex;
  items

let unique_field name fields =
  match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ -> Error (Printf.sprintf "tool result repeats reserved field %s" name)

let artifact_ref_of_result = function
  | `Assoc fields as result ->
    let ( let* ) = Result.bind in
    let* kind = unique_field Multimodal.Tool_emission.multimodal_kind_key fields in
    (match kind with
     | None -> Ok None
     | Some (`String _) ->
       (match Multimodal.Tool_emission.extract_kind_from_result result with
        | None -> Error "tool result carries an unknown multimodal kind"
        | Some _ ->
          let* id = unique_field Multimodal.Tool_emission.multimodal_id_key fields in
          (match id with
           | Some json ->
             Shared_types.Artifact_id.of_json json |> Result.map Option.some
           | None -> Error "tagged tool result lacks a multimodal artifact id"))
     | Some _ -> Error "tool result multimodal kind must be a string")
  | _ -> Ok None

let snapshot_artifact_refs acc =
  snapshot acc
  |> List.fold_left
       (fun refs result ->
          let ( let* ) = Result.bind in
          let* refs = refs in
          artifact_ref_of_result result
          |> Result.map (function None -> refs | Some id -> id :: refs))
       (Ok [])
  |> Result.map (List.sort_uniq Shared_types.Artifact_id.compare)

let accumulator_size acc =
  Stdlib.Mutex.lock acc.mutex;
  let n = List.length acc.items in
  Stdlib.Mutex.unlock acc.mutex;
  n

let capture_typed_result acc = function
  | `Assoc _ as data -> push acc data
  | (`List _ | `String _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Null) -> ()

let drain_into_working_context acc ~(working_context : Yojson.Safe.t option)
    : Yojson.Safe.t option =
  let items = drain acc in
  if items = [] then working_context
  else
    Multimodal.Tool_emission.emit_from_tool_results
      ~emit:Multimodal.Keeper_emitter.emit ~working_context items

let global_accumulator = create_accumulator ()

(* Tier K4c — per-keeper registry. Each keeper gets its own
   accumulator so concurrent multi-keeper tool emissions cannot
   bleed across attribution boundaries. The registry itself is
   guarded by [registry_mutex] for the get-or-create path; each
   accumulator value carries its own mutex for push/drain (see
   [push] / [drain]). *)
let registry : (string, accumulator) Hashtbl.t = Hashtbl.create 16
let registry_mutex : Stdlib.Mutex.t = Stdlib.Mutex.create ()

(* Tier K5 — emit registry size gauge after every register/drop so
   operators can alert on divergence from the active keeper count.
   Caller MUST already hold [registry_mutex]; we read the size
   under the same lock that mutated the table. No labels. *)
let emit_registry_size_gauge_holding_lock () : unit =
  let n = Hashtbl.length registry in
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string ToolEmissionRegistrySize)
    ~labels:[]
    (float_of_int n)

let accumulator_for_keeper (keeper_name : string) : accumulator =
  Stdlib.Mutex.lock registry_mutex;
  let acc, grew =
    match Hashtbl.find_opt registry keeper_name with
    | Some a -> a, false
    | None ->
        let a = create_accumulator_for ~keeper_name in
        Hashtbl.add registry keeper_name a;
        a, true
  in
  if grew then emit_registry_size_gauge_holding_lock ();
  Stdlib.Mutex.unlock registry_mutex;
  acc

let capture_typed_result_for_keeper ~keeper_name data =
  capture_typed_result (accumulator_for_keeper keeper_name) data

let registered_keeper_names () : string list =
  Stdlib.Mutex.lock registry_mutex;
  let names = Hashtbl.fold (fun k _ acc -> k :: acc) registry [] in
  Stdlib.Mutex.unlock registry_mutex;
  List.sort String.compare names

let drop_keeper_accumulator (keeper_name : string) : unit =
  Stdlib.Mutex.lock registry_mutex;
  let was_present = Hashtbl.mem registry keeper_name in
  Hashtbl.remove registry keeper_name;
  if was_present then emit_registry_size_gauge_holding_lock ();
  Stdlib.Mutex.unlock registry_mutex
