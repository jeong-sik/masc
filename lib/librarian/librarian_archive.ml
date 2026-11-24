module Types = Keeper_memory_os_types
module Log = Librarian_log
module Log_store = Librarian_log_store
module Codec = Librarian_log_codec
module By_id = Map.Make (String)
module By_seq = Map.Make (Int)
module Change = Librarian_memory_change

type left =
  { fact : Types.fact
  ; removal : Librarian_effects.removal
  ; at : float
  ; line_at : int
  }

type t =
  { left : left list
  ; unreadable : int
  }

type history =
  { unsequenced : left list
  ; changes : Change.t list
  ; unreadable : int
  ; live_lines : int
  }

type seen =
  { gone : (int * left) By_id.t
  ; removals : int
  }

let left_to_json (entry : left) =
  `Assoc
    [ "fact", Types.fact_to_json entry.fact
    ; "removal", Codec.removal_to_json entry.removal
    ; "at", `Float entry.at
    ; "line_at", `Int entry.line_at
    ]
;;

let left_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () = Types.exact_field_names_result [ "fact"; "removal"; "at"; "line_at" ] fields in
    let* fact_json = Types.wire_json_field "fact" fields in
    let* fact = Types.wire_at (Types.Wire_field "fact") (Types.fact_of_json fact_json) in
    let* removal_json = Types.wire_json_field "removal" fields in
    let* removal =
      Types.wire_at (Types.Wire_field "removal") (Codec.removal_of_json removal_json)
    in
    let* at = Types.wire_number_field "at" fields in
    let* line_at = Types.wire_int_field "line_at" fields in
    Ok { fact; removal; at; line_at }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Types.wire_here Types.Expected_object
;;

let record_left seen (entry : left) =
  { gone = By_id.add (Types.memory_id entry.fact) (seen.removals, entry) seen.gone
  ; removals = seen.removals + 1
  }
;;

let after_change seen (c : Change.t) =
  let seen = List.fold_left
      (fun seen (fact, removal) -> record_left seen { fact; removal; at = c.at; line_at = c.line_at })
      seen c.removed in
  { seen with gone = List.fold_left (fun gone fact -> By_id.remove (Types.memory_id fact) gone)
                       seen.gone c.added }
;;

let left_of_history (history : history) ~current =
  let initial = { gone = By_id.empty; removals = 0 } in
  let seen = List.fold_left record_left initial history.unsequenced in
  let seen = List.fold_left after_change seen history.changes in
  let gone = List.fold_left (fun gone fact -> By_id.remove (Types.memory_id fact) gone) seen.gone current in
  let ordered = By_id.bindings gone |> List.map snd |> List.sort (fun (a, _) (b, _) -> Int.compare a b) in
  { left = List.map snd ordered; unreadable = history.unreadable }
;;

let write_history ~archive_path (history : history) =
  let dir = Filename.dirname archive_path in
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
  | () ->
    let buf = Buffer.create 4096 in
    let write json = Buffer.add_string buf (Yojson.Safe.to_string json); Buffer.add_char buf '\n' in
    List.iter (fun old -> write (left_to_json old)) history.unsequenced;
    List.iter (fun c -> write (Change.to_json c)) history.changes;
    Fs_compat.save_file_atomic_strict archive_path (Buffer.contents buf)
;;

type lock_entry =
  { mu : Cross_context_mutex.t
  ; mutable users : int
  }

let lock_registry_mu = Mutex.create ()
let path_locks : (string, lock_entry) Hashtbl.t = Hashtbl.create 16

let canonical_lock_key log_path =
  let dir = Filename.dirname log_path in
  let base = Filename.basename log_path in
  let real_dir =
    try Unix.realpath dir with
    | Unix.Unix_error _ -> dir
  in
  Filename.concat real_dir base
;;

let with_path_lock ~log_path f =
  let key = canonical_lock_key log_path in
  let entry =
    Mutex.lock lock_registry_mu;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock_registry_mu)
      (fun () ->
         match Hashtbl.find_opt path_locks key with
         | Some e ->
           e.users <- e.users + 1;
           e
         | None ->
           let e = { mu = Cross_context_mutex.create (); users = 1 } in
           Hashtbl.replace path_locks key e;
           e)
  in
  let release () =
    Mutex.lock lock_registry_mu;
    Fun.protect
      ~finally:(fun () -> Mutex.unlock lock_registry_mu)
      (fun () ->
         entry.users <- entry.users - 1;
         if entry.users <= 0 then Hashtbl.remove path_locks key)
  in
  Fun.protect ~finally:release (fun () -> Cross_context_mutex.with_lock entry.mu f)
;;

let history_unlocked path =
  let open Result.Syntax in
  (* A checkpoint publishes the archive first. Capturing live before cold
     therefore sees either copy of every committed sequence, including when
     another process is between the two atomic renames. *)
  let* live, unreadable, live_lines =
    Log_store.fold path ~init:([], 0, 0) ~f:(fun (changes, bad, count) row ->
      match row.Log_store.line with
      | Ok (Log.Started _) -> changes, bad, count + 1
      | Ok (Committed commit) -> Change.of_commit ~line_at:row.at commit :: changes, bad, count + 1
      | Error _ -> changes, bad + 1, count + 1)
  in
  let cold = Log_store.archive_path_of_log_path path in
  let add_change (events, bad) (c : Change.t) =
    match By_seq.find_opt c.seq events with
    | None -> By_seq.add c.seq (Some c) events, bad
    | Some (Some prior) when { prior with line_at = c.line_at } = c -> events, bad
    | Some (Some _) -> By_seq.add c.seq None events, bad + 1
    | Some None -> events, bad
  in
  let* old, (events, bad) =
    Private_jsonl_scan.fold cold ~rows_per_read:128 ~init:([], (By_seq.empty, unreadable))
      ~f:(fun (old, (events, bad)) ~at:_ raw ->
        match Yojson.Safe.from_string raw with
        | exception Yojson.Json_error _ -> old, (events, bad + 1)
        | `Assoc fields as json when List.mem_assoc "seq" fields ->
          (match Change.of_json json with
           | Ok c -> old, add_change (events, bad) c
           | Error _ -> old, (events, bad + 1))
        | json ->
          (match left_of_json json with
           | Ok left -> left :: old, (events, bad)
           | Error _ -> old, (events, bad + 1)))
  in
  (* A live append may have a pending fragment. The atomically published
     cold file always ends at a row boundary, so a cold fragment is lost evidence. *)
  let* bad =
    match Fs_compat.read_private_jsonl_tail_locked_result cold ~max_bytes:1 with
    | Fs_compat.Private_file_failed err
    | Private_file_failed_with_cleanup_failure { error = err; _ } ->
      Error (Private_jsonl_scan.Read_failed { path = cold; detail = Fs_compat.Private_jsonl_tail.error_to_string err })
    | Private_file_succeeded tail | Private_file_succeeded_with_cleanup_failure { value = tail; _ } ->
      (match tail with
       | Fs_compat.Private_jsonl_tail.Tail_present { incomplete_tail = true; _ } -> Ok (bad + 1)
       | Tail_missing | Tail_present { incomplete_tail = false; _ } -> Ok bad)
  in
  let events, unreadable = List.fold_left add_change (events, bad) live in
  let changes = By_seq.bindings events |> List.filter_map snd in
  (* A pre-change writer could have published the old removal sidecar while
     the corresponding live log was still visible. Only suppress an exact
     removal occurrence. Repeated changes to a fact at other times survive. *)
  let known = Hashtbl.create 16 in
  List.iter (fun (c : Change.t) ->
    List.iter (fun (fact, removal) -> Hashtbl.replace known (Types.memory_id fact, removal, c.at) ())
      c.removed) changes;
  let unsequenced = List.rev old |> List.filter (fun (e : left) ->
    not (Hashtbl.mem known (Types.memory_id e.fact, e.removal, e.at))) in
  Ok { unsequenced; changes; unreadable; live_lines }
;;

let history path = with_path_lock ~log_path:path (fun () -> history_unlocked path)

let read path ~current =
  Result.map (fun history -> left_of_history history ~current) (history path)
;;
