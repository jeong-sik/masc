module String_set = Set.Make (String)

let history_limit = 200

type deletion_failure =
  { path : string
  ; detail : string
  }

type summary =
  { removed : int
  ; retained_references : int
  ; candidate_files : int
  ; deletion_failures : deletion_failure list
  }

type error =
  | Turn_record_store_unreadable of string
  | Malformed_turn_record of
      { path : string
      ; line_number : int option
      ; detail : string
      }
  | Incompatible_turn_record of string
  | Wrong_keeper_turn_record of
      { expected : string
      ; actual : string
      }
  | Invalid_raw_trace_reference of string
  | Raw_trace_directory_unreadable of string

let error_to_string = function
  | Turn_record_store_unreadable detail ->
    Printf.sprintf "cannot read current TurnRecord window: %s" detail
  | Malformed_turn_record { path; line_number; detail } ->
    Printf.sprintf "malformed TurnRecord path=%s line=%s: %s"
      path
      (Option.fold ~none:"unknown" ~some:string_of_int line_number)
      detail
  | Incompatible_turn_record detail ->
    Printf.sprintf "incompatible current TurnRecord: %s" detail
  | Wrong_keeper_turn_record { expected; actual } ->
    Printf.sprintf "TurnRecord keeper mismatch: expected=%s actual=%s" expected actual
  | Invalid_raw_trace_reference path ->
    Printf.sprintf "TurnRecord raw-trace reference is outside the keeper store: %s" path
  | Raw_trace_directory_unreadable detail ->
    Printf.sprintf "cannot read keeper raw-trace directory: %s" detail
;;

let path_is_in_store ~dir path =
  String.equal (Filename.dirname path) dir
  && Filename.check_suffix path Keeper_types_support.raw_trace_file_extension
;;

let protected_references ~config ~keeper_name ~dir =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  match Dated_jsonl.read_recent_result store history_limit with
  | Error error ->
    Error
      (Turn_record_store_unreadable (Dated_jsonl.read_error_to_string error))
  | Ok entries ->
    let rec collect protected = function
      | [] -> Ok protected
      | Dated_jsonl.Malformed_json { path; line_number; detail } :: _ ->
        Error (Malformed_turn_record { path; line_number; detail })
      | Dated_jsonl.Parsed json :: rest ->
        (match Turn_record.of_json json with
         | Error detail -> Error (Incompatible_turn_record detail)
         | Ok record when not (String.equal record.keeper keeper_name) ->
           Error
             (Wrong_keeper_turn_record
                { expected = keeper_name; actual = record.keeper })
         | Ok { raw_trace_run_ref = None; _ } -> collect protected rest
         | Ok { raw_trace_run_ref = Some run_ref; _ } ->
           if path_is_in_store ~dir run_ref.path
           then collect (String_set.add run_ref.path protected) rest
           else Error (Invalid_raw_trace_reference run_ref.path))
    in
    let open Result.Syntax in
    collect String_set.empty entries
;;

let regular_trace_files dir =
  let entries =
    try Ok (Sys.readdir dir) with
    | Sys_error detail -> Error (Raw_trace_directory_unreadable detail)
  in
  match entries with
  | Error _ as error -> error
  | Ok entries ->
    Ok
      (entries
       |> Array.to_list
       |> List.filter_map (fun entry ->
         if Filename.check_suffix entry Keeper_types_support.raw_trace_file_extension
         then
           let path = Filename.concat dir entry in
           (match Unix.lstat path with
            | { Unix.st_kind = Unix.S_REG; _ } -> Some path
            | _ -> None
            | exception Unix.Unix_error _ -> None)
         else None))
;;

let prune ~config ~keeper_name () =
  let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
  match protected_references ~config ~keeper_name ~dir with
  | Error _ as error -> error
  | Ok references ->
    (match regular_trace_files dir with
     | Error _ as error -> error
     | Ok files ->
       let candidates =
         List.filter (fun path -> not (String_set.mem path references)) files
       in
       let removed, deletion_failures =
         List.fold_left
           (fun (removed, failures) path ->
             try
               Sys.remove path;
               removed + 1, failures
             with
             | Sys_error detail ->
               removed, { path; detail } :: failures)
           (0, [])
           candidates
       in
       Ok
         { removed
         ; retained_references = String_set.cardinal references
         ; candidate_files = List.length candidates
         ; deletion_failures = List.rev deletion_failures
         })
;;
