(* See .mli. *)

let sanitize_name name = Workspace_utils_backend_setup.sanitize_namespace_segment name
let ask_dir base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_ask"

let log_path ~base_path ~keeper_name =
  Filename.concat (ask_dir base_path) (sanitize_name keeper_name ^ ".jsonl")

let ensure_ask_dir ~base_path =
  let (_ : string) = Keeper_fs.ensure_dir (ask_dir base_path) in
  ()

type answer_failure =
  | Ask_not_found of { ask_id : string }
  | Already_answered of {
      answers : Keeper_ask.answer list;
      responder : Keeper_ask.responder;
      answered_at : float;
    }
  | Already_withdrawn of { reason : string; withdrawn_at : float }
  | Rejected of Keeper_ask.invalid_answer list
  | Store_failed of string

type withdraw_failure =
  | Withdraw_ask_not_found of { ask_id : string }
  | Withdraw_already_answered of { answered_at : float }
  | Withdraw_already_withdrawn of { withdrawn_at : float }
  | Withdraw_store_failed of string

let answer_failure_to_string = function
  | Ask_not_found { ask_id } -> "no such ask: " ^ ask_id
  | Already_answered { answered_at; _ } ->
      Printf.sprintf "already answered at %.0f" answered_at
  | Already_withdrawn { reason; _ } -> "already withdrawn: " ^ reason
  | Rejected errors ->
      String.concat "; " (List.map Keeper_ask.invalid_answer_to_string errors)
  | Store_failed detail -> "store failed: " ^ detail

let withdraw_failure_to_string = function
  | Withdraw_ask_not_found { ask_id } -> "no such ask: " ^ ask_id
  | Withdraw_already_answered { answered_at } ->
      Printf.sprintf "already answered at %.0f" answered_at
  | Withdraw_already_withdrawn { withdrawn_at } ->
      Printf.sprintf "already withdrawn at %.0f" withdrawn_at
  | Withdraw_store_failed detail -> "store failed: " ^ detail

let append_event ~base_path ~keeper_name event =
  try
    ensure_ask_dir ~base_path;
    let path = log_path ~base_path ~keeper_name in
    Fs_compat.append_file path (Yojson.Safe.to_string (Keeper_ask.event_to_json event) ^ "\n");
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      let detail = Printexc.to_string exn in
      Log.Keeper.warn "keeper_ask_store: append failed for %s: %s" (sanitize_name keeper_name)
        detail;
      Error detail

let decode_line line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error detail -> Error detail
  | json -> Keeper_ask.event_of_json json

let load_events_result ~base_path ~keeper_name =
  let path = log_path ~base_path ~keeper_name in
  if not (Sys.file_exists path) then Ok []
  else
    try
      let (parsed_rev, line_count), _boundary =
        Fs_compat.fold_appended_lines ~path ~from:0 ~init:([], 0)
          ~f:(fun (acc, line_no) line ->
            let line_no = line_no + 1 in
            let trimmed = String.trim line in
            if trimmed = "" then (acc, line_no)
            else ((line_no, decode_line trimmed) :: acc, line_no))
      in
      let parsed = List.rev parsed_rev in
      (* A final line that does not decode is the shape an append cut short by
         a crash leaves. Anywhere else it means the history itself is damaged,
         and a reader that skipped it would report a shortened past as
         complete. *)
      let fatal =
        List.filter_map
          (fun (line_no, result) ->
            match result with
            | Ok _ -> None
            | Error detail -> if line_no = line_count then None else Some (line_no, detail))
          parsed
      in
      match fatal with
      | (line_no, detail) :: _ ->
          Error (Printf.sprintf "%s:%d ask log decode failed: %s" path line_no detail)
      | [] ->
          Ok
            (List.filter_map
               (fun (_, result) -> match result with Ok event -> Some event | Error _ -> None)
               parsed)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Sys_error detail -> Error (Printf.sprintf "%s ask log read failed: %s" path detail)
    | exn ->
        Error
          (Printf.sprintf "%s ask log load failed for %s: %s" path (sanitize_name keeper_name)
             (Printexc.to_string exn))

let load_events ~base_path ~keeper_name =
  match load_events_result ~base_path ~keeper_name with
  | Ok events -> events
  | Error msg ->
      Log.Keeper.warn "keeper_ask_store: %s" msg;
      []

let rows ~base_path ~keeper_name =
  Keeper_ask.fold_events (load_events ~base_path ~keeper_name)

let open_asks ~base_path ~keeper_name =
  Keeper_ask.open_asks (load_events ~base_path ~keeper_name)

let open_ask_count ~base_path ~keeper_name =
  List.length (open_asks ~base_path ~keeper_name)

let settled ~base_path ~keeper_name ~ask_id =
  List.find_map
    (fun (id, (_, resolution)) -> if String.equal id ask_id then Some resolution else None)
    (rows ~base_path ~keeper_name)

let record_ask ~base_path (a : Keeper_ask.ask) =
  append_event ~base_path ~keeper_name:a.keeper_name (Keeper_ask.Asked a)

let find_row rows_list ask_id =
  List.find_map
    (fun (id, row) -> if String.equal id ask_id then Some row else None)
    rows_list

let answer ~base_path ~keeper_name ~ask_id ~submissions ~responder ~now =
  match find_row (rows ~base_path ~keeper_name) ask_id with
  | None -> Error (Ask_not_found { ask_id })
  | Some (_, Keeper_ask.Answered_by { answers; responder; answered_at }) ->
      Error (Already_answered { answers; responder; answered_at })
  | Some (_, Keeper_ask.Withdrawn_because { reason; withdrawn_at }) ->
      Error (Already_withdrawn { reason; withdrawn_at })
  | Some (recorded_ask, Keeper_ask.Open) -> (
      match Keeper_ask.parse_answers ~ask:recorded_ask ~submissions with
      | Error errors -> Error (Rejected errors)
      | Ok answers -> (
          let event =
            Keeper_ask.Answered { ask_id; answers; responder; answered_at = now }
          in
          match append_event ~base_path ~keeper_name event with
          | Ok () -> Ok answers
          | Error detail -> Error (Store_failed detail)))

let withdraw ~base_path ~keeper_name ~ask_id ~reason ~now =
  match find_row (rows ~base_path ~keeper_name) ask_id with
  | None -> Error (Withdraw_ask_not_found { ask_id })
  | Some (_, Keeper_ask.Answered_by { answered_at; _ }) ->
      Error (Withdraw_already_answered { answered_at })
  | Some (_, Keeper_ask.Withdrawn_because { withdrawn_at; _ }) ->
      Error (Withdraw_already_withdrawn { withdrawn_at })
  | Some (_, Keeper_ask.Open) -> (
      let event = Keeper_ask.Withdrawn { ask_id; reason; withdrawn_at = now } in
      match append_event ~base_path ~keeper_name event with
      | Ok () -> Ok ()
      | Error detail -> Error (Withdraw_store_failed detail))
