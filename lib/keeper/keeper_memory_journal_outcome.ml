module Current = Keeper_memory_os_current

type t =
  { last_success_at : float option
  ; last_failure : Current.librarian_failure_kind option
  }

let empty = { last_success_at = None; last_failure = None }

type kept =
  { cursor : Dated_jsonl.append_cursor
  ; outcome : t
  }

let kept : (string, kept) Hashtbl.t = Hashtbl.create 16
let kept_mu = Stdlib.Mutex.create ()

let step outcome = function
  | Dated_jsonl.Malformed_json _ -> outcome
  | Dated_jsonl.Parsed json ->
    (match Keeper_memory_os_journal_codec.journal_entry_of_json json with
     | Ok (Current.Journal_committed { recorded_at; source = { kind = Current.Librarian; _ }; _ }) ->
       { last_success_at = Some recorded_at; last_failure = None }
     | Ok (Current.Journal_failed { kind; _ }) -> { outcome with last_failure = Some kind }
     | Ok
         (Current.Journal_committed
            { source = { kind = Current.(Explicit_write | Explicit_retract); _ }; _ })
     | Ok (Current.Journal_quarantined _)
     | Error _ -> outcome)
;;

let fold path ~cursor ~init =
  Dated_jsonl.fold_file_appended_entries_result path ~cursor ~init ~f:step
;;

let read ~keepers_dir ~keeper_id =
  let path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let previous = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.find_opt kept path) in
  let store value = Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.replace kept path value) in
  let from_start () =
    match fold path ~cursor:None ~init:empty with
    | Ok (Dated_jsonl.Appended (outcome, cursor)) ->
      store { cursor; outcome };
      Some outcome
    (* Only a passed cursor can be invalidated. *)
    | Ok Dated_jsonl.Cursor_invalidated | Error _ -> None
  in
  if not (Sys.file_exists path)
  then (
    Stdlib.Mutex.protect kept_mu (fun () -> Hashtbl.remove kept path);
    empty)
  else (
    let read =
      match previous with
      | None -> from_start ()
      | Some { cursor; outcome } ->
        (match fold path ~cursor:(Some cursor) ~init:outcome with
         | Ok (Dated_jsonl.Appended (outcome, cursor)) ->
           store { cursor; outcome };
           Some outcome
         | Ok Dated_jsonl.Cursor_invalidated -> from_start ()
         | Error _ -> None)
    in
    match read, previous with
    | Some outcome, _ -> outcome
    | None, Some { outcome; _ } -> outcome
    | None, None -> empty)
;;
