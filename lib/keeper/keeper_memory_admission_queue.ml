open Keeper_memory_os_types

let ( let* ) = Result.bind
let ( let+ ) value f = Result.map f value

type candidate = { sequence : int; request_id : string; fact : fact }
type state = { generation : string; acknowledged : int; pending : candidate list }
type batch = { generation : string; after : int; rows : candidate list }

let suffix = ".memory-admission.json"
let path ~keepers_dir ~keeper_id = Filename.concat keepers_dir (keeper_id ^ suffix)
let candidates batch = batch.rows

let smaller_prefix batch =
  match batch.rows with
  | [] | [_] -> None
  | _ -> Some {batch with rows = List.take (List.length batch.rows / 2) batch.rows}

let candidate_to_json row =
  `Assoc ["sequence", `Int row.sequence; "request_id", `String row.request_id;
          "fact", fact_to_json row.fact]

let input_sha256 rows = Digestif.SHA256.(digest_string
  (Yojson.Safe.to_string (`List (List.map candidate_to_json rows))) |> to_hex)

let range_id batch : Keeper_memory_os_current.explicit_write_range_id =
  { receipt_scope = batch.generation; after_sequence = batch.after;
    through_sequence = List.fold_left (fun _ row -> row.sequence) batch.after batch.rows;
    input_sha256 = input_sha256 batch.rows }

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
    let* () = exact_field_names_result ["generation"; "acknowledged"; "pending"] fields in
    let* generation = canonical_string "generation" fields in
    let* acknowledged = wire_int_field "acknowledged" fields in
    let* () = if acknowledged < 0 then wire_fail [Wire_field "acknowledged"] Negative else Ok () in
    let* rows = wire_list_field "pending" fields in
    let rec decode previous seen index = function
      | [] -> Ok []
      | json :: rest ->
        let* row = wire_at_element "pending" index (candidate_of_json json) in
        let* () =
          if previous = max_int || row.sequence <> previous + 1
          then wire_fail [Wire_field "pending"; Wire_index index] Not_ascending
          else if Set_util.StringSet.mem row.request_id seen
          then wire_fail [Wire_field "pending"; Wire_index index] (Duplicate_entry row.request_id)
          else Ok () in
        let+ rest = decode row.sequence (Set_util.StringSet.add row.request_id seen) (index+1) rest in
        row :: rest in
    let+ pending = decode acknowledged Set_util.StringSet.empty 0 rows in
    { generation; acknowledged; pending }
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
      "acknowledged", `Int state.acknowledged;
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
                  acknowledged = 0; pending = [] } in
    match List.find_opt (fun row -> String.equal row.request_id request_id) state.pending with
    | Some row when row.fact = fact -> Ok row
    | Some _ -> Error "pending admission request identity has different content"
    | None ->
      let previous = List.fold_left (fun _ row -> row.sequence) state.acknowledged state.pending in
      if previous = max_int then Error "pending admission sequence exhausted"
      else
        let row = {sequence = previous+1; request_id; fact} in
        let+ () = write ~keepers_dir ~keeper_id {state with pending = state.pending @ [row]} in
        row)

let read_pending ~keepers_dir ~keeper_id =
  let+ state = read ~keepers_dir ~keeper_id in
  match state with
  | None | Some {pending = []; _} -> None
  | Some state -> Some {generation = state.generation; after = state.acknowledged; rows = state.pending}

let acknowledge_committed ~keepers_dir ~keeper_id =
  let* initial = read ~keepers_dir ~keeper_id in
  match initial with
  | None -> Ok ()
  | Some initial ->
    (* Receipt recovery takes the aggregate lock itself. Read it before taking
       the queue lock; generation and prefix are revalidated below. *)
    let* receipt = Keeper_memory_os_current.committed_explicit_write_range
      ~keepers_dir ~keeper_id ~receipt_scope:initial.generation in
    match receipt with
    | None -> Ok ()
    | Some receipt -> locked ~keepers_dir ~keeper_id (fun () ->
      let* current = read ~keepers_dir ~keeper_id in
      match current with
      | None -> Error "pending admission queue disappeared before acknowledgement"
      | Some state when state.generation <> initial.generation ->
        Error "pending admission generation changed before acknowledgement"
      | Some state when receipt.through_sequence <= state.acknowledged -> Ok ()
      | Some state ->
        if receipt.after_sequence <> state.acknowledged then
          Error "committed admission range does not start at the pending frontier"
        else
          let prefix, tail = List.partition (fun row -> row.sequence <= receipt.through_sequence) state.pending in
          let batch = {generation = state.generation; after = state.acknowledged; rows = prefix} in
          if range_id batch <> receipt then Error "committed admission range does not match pending input"
          else write ~keepers_dir ~keeper_id
            {state with acknowledged = receipt.through_sequence; pending = tail})

let list_keeper_ids ~keepers_dir = protect (fun () ->
  if not (Sys.file_exists keepers_dir) then Ok []
  else Sys.readdir keepers_dir |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix)
    |> List.sort String.compare |> fun ids -> Ok ids)
