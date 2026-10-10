open Keeper_memory_os_types

let ( let* ) = Result.bind
let ( let+ ) value f = Result.map f value

type candidate = { sequence : int; request_id : string; fact : fact }
type state = { generation : string; last_sequence : int; pending : candidate list }
type batch = { generation : string; rows : candidate list }

let suffix = ".memory-admission.json"
let path ~keepers_dir ~keeper_id = Filename.concat keepers_dir (keeper_id ^ suffix)
let candidates batch = batch.rows

let split batch =
  match batch.rows with
  | [] | [_] -> None
  | _ ->
    let half = List.length batch.rows / 2 in
    Some ({batch with rows = List.take half batch.rows},
          {batch with rows = List.drop half batch.rows})

let candidate_to_json row =
  `Assoc ["sequence", `Int row.sequence; "request_id", `String row.request_id;
          "fact", fact_to_json row.fact]

let candidate_id ~generation row : Keeper_memory_os_current.explicit_candidate_id =
  {queue_generation=generation; request_id=row.request_id; sequence=row.sequence;
   input_sha256=Digestif.SHA256.(digest_string
     (Yojson.Safe.to_string (candidate_to_json row)) |> to_hex)}

let candidate_ids batch = List.map (candidate_id ~generation:batch.generation) batch.rows

let canonical_string name fields =
  let* value = wire_string_field name fields in
  if value = "" || String.trim value <> value
  then wire_fail [Wire_field name] Blank_string else Ok value

let candidate_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result ["sequence"; "request_id"; "fact"] fields in
    let* sequence = wire_int_field "sequence" fields in
    let* request_id = canonical_string "request_id" fields in
    let* json = wire_json_field "fact" fields in
    let+ fact = wire_at (Wire_field "fact") (fact_of_json json) in
    {sequence; request_id; fact}
  | _ -> wire_here Expected_object

let state_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result ["generation"; "last_sequence"; "pending"] fields in
    let* generation = canonical_string "generation" fields in
    let* last_sequence = wire_int_field "last_sequence" fields in
    let* () = if last_sequence < 0 then wire_fail [Wire_field "last_sequence"] Negative else Ok () in
    let* rows = wire_list_field "pending" fields in
    let rec decode previous seen index = function
      | [] -> Ok []
      | json :: rest ->
        let* row = wire_at_element "pending" index (candidate_of_json json) in
        let* () =
          if row.sequence <= previous || row.sequence > last_sequence
          then wire_fail [Wire_field "pending"; Wire_index index] Not_ascending
          else if Set_util.StringSet.mem row.request_id seen
          then wire_fail [Wire_field "pending"; Wire_index index] (Duplicate_entry row.request_id)
          else Ok () in
        let+ rest = decode row.sequence (Set_util.StringSet.add row.request_id seen) (index+1) rest in
        row :: rest in
    let+ pending = decode 0 Set_util.StringSet.empty 0 rows in
    { generation; last_sequence; pending }
  | _ -> wire_here Expected_object

let protect action =
  try action () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (error, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))

let read ~keepers_dir ~keeper_id =
  protect (fun () ->
    match Fs_compat.load_file_opt (path ~keepers_dir ~keeper_id) with
    | None -> Ok None
    | Some bytes ->
      (match Yojson.Safe.from_string bytes with
       | json -> state_of_json json |> Result.map Option.some |> Result.map_error wire_error_to_string
       | exception Yojson.Json_error detail -> Error detail))

let write ~keepers_dir ~keeper_id (state : state) =
  Fs_compat.save_file_atomic_strict (path ~keepers_dir ~keeper_id)
    (Yojson.Safe.to_string (`Assoc ["generation", `String state.generation;
      "last_sequence", `Int state.last_sequence;
      "pending", `List (List.map candidate_to_json state.pending)]))

let locked ~keepers_dir ~keeper_id action = protect (fun () ->
  Fs_compat.mkdir_p keepers_dir;
  Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock (path ~keepers_dir ~keeper_id) action))

let append ~keepers_dir ~keeper_id ~request_id fact =
  let* () = canonical_string "request_id" ["request_id", `String request_id]
    |> Result.map ignore |> Result.map_error wire_error_to_string in
  let* fact = fact_of_json (fact_to_json fact) |> Result.map_error wire_error_to_string in
  locked ~keepers_dir ~keeper_id (fun () ->
    let* prior = read ~keepers_dir ~keeper_id in
    let state = match prior with
      | Some state -> state
      | None -> { generation = Random_id.prefixed ~prefix:"explicit-writes-" ~bytes:16;
                  last_sequence = 0; pending = [] } in
    match List.find_opt (fun row -> String.equal row.request_id request_id) state.pending with
    | Some row when row.fact = fact -> Ok row
    | Some _ -> Error "pending admission request identity has different content"
    | None ->
      let previous = state.last_sequence in
      if previous = max_int then Error "pending admission sequence exhausted"
      else
        let row = {sequence = previous+1; request_id; fact} in
        let+ () = write ~keepers_dir ~keeper_id {state with last_sequence=row.sequence; pending = state.pending @ [row]} in
        row)

let read_pending ~keepers_dir ~keeper_id =
  let+ state = read ~keepers_dir ~keeper_id in
  match state with
  | None | Some {pending = []; _} -> None
  | Some state -> Some {generation = state.generation; rows = state.pending}

(* Strictly ascending pending sequences are a subset of 1..last_sequence. Every
   position pending no longer holds was removed by an earlier acknowledgement,
   which required its committed receipt, and candidate receipts are retained
   per candidate. So each removed position must still be named by a receipt;
   one that is not (a restored older receipt file, a rolled-back snapshot) is
   input nothing proves was consumed. The scan returns the first such position. *)
let first_unproven_consumed (state : state)
    (receipts : Keeper_memory_os_current.explicit_candidate_id list) =
  let covered = Hashtbl.create (List.length state.pending + List.length receipts) in
  List.iter (fun (row : candidate) -> Hashtbl.replace covered row.sequence ()) state.pending;
  List.iter (fun (receipt : Keeper_memory_os_current.explicit_candidate_id) ->
    Hashtbl.replace covered receipt.sequence ()) receipts;
  let rec scan sequence =
    if sequence > state.last_sequence then None
    else if Hashtbl.mem covered sequence then scan (sequence + 1)
    else Some sequence in
  scan 1

let acknowledge_committed ~keepers_dir ~keeper_id =
  let* initial = read ~keepers_dir ~keeper_id in
  match initial with
  | None -> Ok ()
  | Some initial ->
    (* Receipt recovery owns the aggregate lock. Take this observation first,
       then revalidate the queue generation and every matching payload under
       its lock. A later receipt is consumed by a subsequent acknowledgement.
       Positions already missing from [initial] were removed before these
       receipts were read, so they are checked against them here. Rows another
       acknowledgement removes after this read carry receipts this observation
       may not contain, so the locked rewrite does not repeat the check. *)
    let* receipts = Keeper_memory_os_current.committed_explicit_candidates
      ~keepers_dir ~keeper_id ~queue_generation:initial.generation in
    match first_unproven_consumed initial receipts, receipts with
    | Some unproven_sequence, _ ->
      Error (Printf.sprintf
        "admission receipt recovery required: generation=%s unproven_sequence=%d consumed_sequence_count=%d; recovery needs an independently attested exact backup that this product does not create — without one this state is unrecoverable and the queue stays blocked (docs/guides/MEMORY-ADMISSION-RECOVERY.md); pending input is unchanged"
        initial.generation unproven_sequence (initial.last_sequence - List.length initial.pending))
    | None, [] -> Ok ()
    | None, _ :: _ -> locked ~keepers_dir ~keeper_id (fun () ->
      let* current = read ~keepers_dir ~keeper_id in
      match current with
      | None -> Error "pending admission queue disappeared before acknowledgement"
      | Some state when state.generation <> initial.generation ->
        Error "pending admission generation changed before acknowledgement"
      | Some state ->
        let by_request = Hashtbl.create (List.length receipts) in
        let by_sequence = Hashtbl.create (List.length receipts) in
        let* () = List.fold_left (fun result (receipt : Keeper_memory_os_current.explicit_candidate_id) ->
          let* () = result in
          if receipt.queue_generation <> state.generation || receipt.sequence > state.last_sequence then
            Error "committed admission candidate is outside the queue generation or sequence history"
          else (
            Hashtbl.add by_request receipt.request_id receipt;
            Hashtbl.add by_sequence receipt.sequence receipt;
            Ok ())) (Ok ()) receipts in
        let* retained = List.fold_left (fun result row ->
          let* retained = result in
          let expected = candidate_id ~generation:state.generation row in
          match Hashtbl.find_opt by_request row.request_id,
                Hashtbl.find_opt by_sequence row.sequence with
          | None, None -> Ok (row :: retained)
          | Some by_id, Some by_seq when by_id = expected && by_seq = expected -> Ok retained
          | Some _, None | None, Some _ | Some _, Some _ ->
            Error "committed admission candidate does not match pending identity and payload")
          (Ok []) state.pending in
        let pending = List.rev retained in
        if List.length pending = List.length state.pending then Ok ()
        else write ~keepers_dir ~keeper_id {state with pending})

let list_keeper_ids ~keepers_dir = protect (fun () ->
  if not (Sys.file_exists keepers_dir) then Ok []
  else Sys.readdir keepers_dir |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix)
    |> List.sort String.compare |> fun ids -> Ok ids)
