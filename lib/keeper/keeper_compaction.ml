open Result.Syntax

type compaction_anchor =
  { epoch_id : int
  ; coverage : Keeper_compaction_atom.coverage
  ; archived_epochs_through : int option
  ; active_intent : string
  ; observations : (Keeper_compaction_observation.t * Keeper_compaction_atom.name) list
  }

type compaction_trigger =
  | Provider_context_overflow of { provider_limit_tokens : int option }
  | Provider_counted_window of
      { used_tokens : int
      ; limit_tokens : int
      }
  | Explicit_hard_limit of
      { capacity_bytes : int
      ; observed_bytes : int
      }

type store_error =
  | Sqlite_error of
      { operation : string
      ; detail : string
      }
  | Corrupt_record of
      { context : string
      ; detail : string
      }
  | Schema_not_current of
      { path : string
      ; found : int64
      }
  | Invalid_eviction of string

(* The atom-coverage layout (RFC compaction-anchor-names-a-turn-atom). A store
   written before it has the same tables at user_version 0 and is refused. *)
let schema_version = 1L

let store_error_to_string = function
  | Sqlite_error { operation; detail } ->
    Printf.sprintf "compaction sqlite error (%s): %s" operation detail
  | Corrupt_record { context; detail } ->
    Printf.sprintf "compaction corrupt record (%s): %s" context detail
  | Schema_not_current { path; found } ->
    Printf.sprintf
      "compaction store %s has user_version %Ld; this build reads %Ld only (fresh state required)"
      path
      found
      schema_version
  | Invalid_eviction detail -> Printf.sprintf "compaction eviction invalid: %s" detail
;;

let global_on_epoch_committed
    : (keepers_dir:string -> keeper_id:string -> compaction_anchor -> unit) option Atomic.t
  =
  Atomic.make None
;;

let set_on_epoch_committed cb = Atomic.set global_on_epoch_committed cb

let global_on_canonical_epoch_committed
    : (keepers_dir:string -> keeper_id:string -> compaction_anchor -> unit) option Atomic.t
  =
  Atomic.make None
;;

let set_on_canonical_epoch_committed cb = Atomic.set global_on_canonical_epoch_committed cb

let notify_global_epoch_committed ~keepers_dir ~keeper_id anchor =
  (match Atomic.get global_on_canonical_epoch_committed with
   | None -> ()
   | Some cb ->
     (try cb ~keepers_dir ~keeper_id anchor with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          ~keeper_name:keeper_id
          "compaction canonical watermark observer failed: %s"
          (Printexc.to_string exn)));
  match Atomic.get global_on_epoch_committed with
  | None -> ()
  | Some cb ->
    (try cb ~keepers_dir ~keeper_id anchor with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "compaction on_epoch_committed listener failed: %s"
         (Printexc.to_string exn))
;;

(* --- Strict JSON codecs --- *)

let decode_list f items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* decoded = f item in
      loop (decoded :: acc) rest
  in
  loop [] items
;;

let observation_to_json (observation, name) =
  `Assoc
    [ "atom", Keeper_compaction_atom.name_to_json name
    ; "observation", Keeper_compaction_observation.to_yojson observation
    ]
;;

let observation_of_json = function
  | `Assoc fields ->
    (match List.sort compare fields with
     | [ "atom", atom; "observation", json ] ->
       let* observation = Keeper_compaction_observation.of_yojson json in
       let* name = Keeper_compaction_atom.name_of_json atom in
       Ok (observation, name)
     | _ -> Error "expected atom and observation")
  | _ -> Error "expected an anchored observation object"
;;

let anchor_to_json (a : compaction_anchor) =
  `Assoc
    [ "active_intent", `String a.active_intent
    ; ( "archived_epochs_through"
      , Option.fold ~none:`Null ~some:(fun n -> `Int n) a.archived_epochs_through )
    ; "coverage", Keeper_compaction_atom.coverage_to_json a.coverage
    ; "epoch_id", `Int a.epoch_id
    ; "observations", `List (List.map observation_to_json a.observations)
    ]
;;

let anchor_of_json = function
  | `Assoc fields ->
    (match List.sort compare fields with
     | [ "active_intent", `String active_intent
       ; "archived_epochs_through", archived
       ; "coverage", coverage
       ; "epoch_id", `Int epoch_id
       ; "observations", `List rows
       ] ->
       if epoch_id < 1
       then Error "epoch_id must be positive"
       else
         let* archived_epochs_through =
           match archived with
           | `Null -> Ok None
           | `Int n when n >= 1 && n <= epoch_id -> Ok (Some n)
           | _ -> Error "archived_epochs_through must be null or an epoch in range"
         in
         let* coverage = Keeper_compaction_atom.coverage_of_json coverage in
         let* observations = decode_list observation_of_json rows in
         Ok { epoch_id; coverage; archived_epochs_through; active_intent; observations }
     | _ -> Error "compaction_anchor field set mismatch")
  | _ -> Error "expected JSON object for compaction_anchor"
;;

let trigger_to_json = function
  | Provider_context_overflow { provider_limit_tokens } ->
    `Assoc
      [ "kind", `String "provider_context_overflow"
      ; ( "provider_limit_tokens"
        , match provider_limit_tokens with
          | None -> `Null
          | Some n -> `Int n )
      ]
  | Provider_counted_window { used_tokens; limit_tokens } ->
    `Assoc
      [ "kind", `String "provider_counted_window"
      ; "limit_tokens", `Int limit_tokens
      ; "used_tokens", `Int used_tokens
      ]
  | Explicit_hard_limit { capacity_bytes; observed_bytes } ->
    `Assoc
      [ "kind", `String "explicit_hard_limit"
      ; "capacity_bytes", `Int capacity_bytes
      ; "observed_bytes", `Int observed_bytes
      ]
;;

let trigger_of_json = function
  | `Assoc fields ->
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fields in
    (match sorted with
     | [ "kind", `String "provider_context_overflow"; "provider_limit_tokens", `Null ] ->
       Ok (Provider_context_overflow { provider_limit_tokens = None })
     | [ "kind", `String "provider_context_overflow"; "provider_limit_tokens", `Int n ] ->
       Ok (Provider_context_overflow { provider_limit_tokens = Some n })
     | [ "capacity_bytes", `Int capacity_bytes
       ; "kind", `String "explicit_hard_limit"
       ; "observed_bytes", `Int observed_bytes
       ] ->
       Ok (Explicit_hard_limit { capacity_bytes; observed_bytes })
     | [ "kind", `String "provider_counted_window"
       ; "limit_tokens", `Int limit_tokens
       ; "used_tokens", `Int used_tokens
       ] ->
       Ok (Provider_counted_window { used_tokens; limit_tokens })
     | _ -> Error "unknown or malformed compaction_trigger")
  | _ -> Error "expected JSON object for compaction_trigger"
;;

(* --- Anchor rendering as pinned Agent_core message --- *)

let render_anchor_text (a : compaction_anchor) =
  let buf = Buffer.create 512 in
  let covers = Keeper_compaction_atom.coverage_to_string a.coverage in
  (match a.archived_epochs_through with
   | None -> Printf.bprintf buf "[compaction anchor epoch=%d covers=%s]\n" a.epoch_id covers
   | Some through_ep ->
     Printf.bprintf
       buf
       "[compaction anchor epoch=%d covers=%s archived_epochs=1..%d]\n"
       a.epoch_id
       covers
       through_ep);
  Printf.bprintf
    buf
    "Last archived user excerpt: %s\n"
    (Yojson.Safe.to_string (`String a.active_intent));
  List.iter
    (fun (observation, name) ->
       Printf.bprintf
         buf
         "[atom:%s] %s\n"
         (Keeper_compaction_atom.name_to_string name)
         (Keeper_compaction_observation.render observation))
    a.observations;
  Buffer.contents buf
;;

let anchor_to_message (a : compaction_anchor) : Agent_core.Types.message =
  { origin = Llm_provider.Types.Outside_context
  ; role = Agent_core.Types.User
  ; content = [ Agent_core.Types.Text (render_anchor_text a) ]
  ; name = None
  ; tool_call_id = None
  ; metadata = Runtime_model_input_tail_window.compaction_anchor_metadata
  }
;;

(* --- Incremental anchored fold --- *)

type archived_atom =
  { name : Keeper_compaction_atom.name
  ; messages : Agent_core.Types.message list
  }

let first_nonblank_text (blocks : Agent_core.Types.content_block list) =
  List.find_map
    (function
      | Agent_core.Types.Text s ->
        let trimmed = String.trim s in
        if String.equal trimmed "" then None else Some trimmed
      | ToolUse _ | ToolResult _ | ToolReference _ | Thinking _
      | ReasoningDetails _ | RedactedThinking _ | Image _ | Document _ | Audio _ -> None)
    blocks
;;

(* Fold the newly archived atoms onto the previous anchor: its observations
   are kept and the new atoms' observations follow, each naming its atom. The
   active intent is the last conversational user text seen so far. *)
let fold_anchor ~(previous : compaction_anchor option) ~coverage ~(fresh : archived_atom list) =
  let active_intent =
    List.fold_left
      (fun intent (atom : archived_atom) ->
         List.fold_left
           (fun intent (msg : Agent_core.Types.message) ->
              if msg.role = User && msg.origin = Conversation
              then Option.value ~default:intent (first_nonblank_text msg.content)
              else intent)
           intent
           atom.messages)
      (Option.fold ~none:"" ~some:(fun a -> a.active_intent) previous)
      fresh
  in
  let observations =
    List.concat_map
      (fun (atom : archived_atom) ->
         List.map
           (fun observation -> observation, atom.name)
           (Keeper_compaction_observation.of_messages atom.messages))
      fresh
  in
  { epoch_id = Option.fold ~none:1 ~some:(fun a -> a.epoch_id + 1) previous
  ; coverage
  ; archived_epochs_through = Option.bind previous (fun a -> a.archived_epochs_through)
  ; active_intent
  ; observations =
      Option.fold ~none:[] ~some:(fun a -> a.observations) previous @ observations
  }
;;

(* --- Structural Anchor Budget & Lossless Roll-Off --- *)

let default_anchor_max_bytes = 32_768

let compaction_bytes_per_token = 4

let saturating_mul a b =
  if a <= 0 || b <= 0
  then 0
  else if a > max_int / b
  then max_int
  else a * b
;;

let compaction_bytes_of_tokens tokens =
  saturating_mul (max 0 tokens) compaction_bytes_per_token
;;

(* Structural 1/4 anchor-window ratio. This is intentionally NOT
   [compaction_bytes_per_token]: that factor translates provider tokens
   into bytes, while this quarters a byte window into an anchor budget.
   Both happen to be 4 today but they are different concepts; retuning
   one must not silently re-size the other. *)
let anchor_budget_for_window ~capacity_bytes ~reserved_bytes =
  max 0 ((capacity_bytes - reserved_bytes) / 4)
;;

let utf8_safe_prefix s max_bytes =
  let len = String.length s in
  if max_bytes <= 0
  then ""
  else if len <= max_bytes
  then s
  else (
    let rec advance pos =
      if pos >= max_bytes
      then pos
      else (
        let d = String.get_utf_8_uchar s pos in
        let next = pos + Uchar.utf_decode_length d in
        if next > max_bytes then pos else advance next)
    in
    String.sub s 0 (advance 0))
;;

let truncate_intent_to_budget s budget =
  if String.length s <= budget
  then s
  else if budget <= 3
  then utf8_safe_prefix s budget
  else utf8_safe_prefix s (budget - 3) ^ "..."
;;

(* "[atom:" + "] " + "\n" around each rendered observation. *)
let observation_line_overhead = 9

let bound_anchor_to_budget ~measure_message_bytes ~max_anchor_bytes (anchor : compaction_anchor) =
  let fits a = measure_message_bytes (anchor_to_message a) <= max 0 max_anchor_bytes in
  if fits anchor then anchor
  else
    let rolled = { anchor with archived_epochs_through = Some anchor.epoch_id } in
    (* Keep the oldest-first, heaviest-section roll-off. A long assistant
       quotation should not evict every tool receipt before it is trimmed. *)
    let requests = Queue.create (), ref 0 in
    let results = Queue.create (), ref 0 in
    let statements = Queue.create (), ref 0 in
    let weights =
      Array.of_list
        (List.mapi
           (fun index (observation, name) ->
              let queue, bytes =
                match observation with
                | Keeper_compaction_observation.Tool_requested _ -> requests
                | Tool_result_recorded _ -> results
                | Assistant_said _ -> statements
              in
              let weight =
                String.length (Keeper_compaction_observation.render observation)
                + String.length (Keeper_compaction_atom.name_to_string name)
                + observation_line_overhead
              in
              Queue.add index queue;
              bytes := !bytes + weight;
              weight)
           rolled.observations)
    in
    let count = Array.length weights in
    let rank = Array.make count 0 in
    for step = 1 to count do
      let heavier ((_, a) as left) ((_, b) as right) = if !a >= !b then left else right in
      let queue, bytes = heavier statements (heavier results requests) in
      let index = Queue.take queue in
      rank.(index) <- step;
      bytes := !bytes - weights.(index)
    done;
    let after drop =
      { rolled with observations = List.filteri (fun i _ -> rank.(i) > drop) rolled.observations }
    in
    let rec first_fit lo hi =
      if lo = hi then after lo
      else
        let mid = lo + (hi - lo) / 2 in
        if fits (after mid) then first_fit lo mid else first_fit (mid + 1) hi
    in
    let candidate = first_fit 0 count in
    if fits candidate then candidate
    else
      let with_intent bytes =
        { candidate with active_intent = truncate_intent_to_budget candidate.active_intent bytes }
      in
      let rec fit_intent lo hi =
        if lo = hi then with_intent lo
        else
          let mid = lo + (hi - lo + 1) / 2 in
          if fits (with_intent mid) then fit_intent mid hi else fit_intent lo (mid - 1)
      in
      fit_intent 0 (String.length candidate.active_intent)
;;

(* --- Secret redaction at the compaction storage boundary --- *)

let strip_trailing_slashes path =
  let rec loop len =
    if len > 1 && path.[len - 1] = '/' then loop (len - 1) else len
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len
;;

let base_path_of_masc_subdir dir =
  let rec walk current =
    let cleaned = strip_trailing_slashes current in
    if String.equal (Filename.basename cleaned) ".masc"
    then Some (Filename.dirname cleaned)
    else (
      let parent = Filename.dirname cleaned in
      if String.equal parent cleaned then None else walk parent)
  in
  walk dir
;;

let default_redact_for_keepers_dir ~keepers_dir ~keeper_id =
  match base_path_of_masc_subdir keepers_dir with
  | Some base_path ->
    Keeper_secret_redaction.snapshot ~base_path ~keeper_name:keeper_id
  | None -> Keeper_secret_redaction.empty
;;

let resolve_redact ?redact ~keepers_dir ~keeper_id () =
  match redact with
  | Some r -> Keeper_secret_redaction.copy_for_current_domain r
  | None -> default_redact_for_keepers_dir ~keepers_dir ~keeper_id
;;

let rec redact_content_block redact (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.Text s ->
    Agent_core.Types.Text (Keeper_secret_redaction.redact_text redact s)
  | Thinking t ->
    Thinking { t with content = Keeper_secret_redaction.redact_text redact t.content }
  | RedactedThinking s ->
    RedactedThinking (Keeper_secret_redaction.redact_text redact s)
  | ToolUse tu ->
    ToolUse { tu with input = Keeper_secret_redaction.redact_json redact tu.input }
  | ToolResult tr ->
    ToolResult
      { tr with
        content = Keeper_secret_redaction.redact_text redact tr.content
      ; json = Option.map (Keeper_secret_redaction.redact_json redact) tr.json
      ; content_blocks = Option.map (List.map (redact_content_block redact)) tr.content_blocks
      }
  | (ToolReference _ | ReasoningDetails _ | Image _ | Document _ | Audio _) as unchanged ->
    unchanged
;;

let redact_message redact (msg : Agent_core.Types.message) =
  { msg with content = List.map (redact_content_block redact) msg.content }
;;

let redact_anchor redact (a : compaction_anchor) =
  let redact = Keeper_secret_redaction.redact_text redact in
  { a with
    active_intent = redact a.active_intent
  ; observations =
      List.map
        (fun (obs, name) -> Keeper_compaction_observation.redact redact obs, name)
        a.observations
  }
;;

(* --- Per-Keeper SQLite WAL store --- *)

let db_suffix = ".compaction.db"

let db_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ db_suffix)
;;

let sqlite_err db operation rc =
  Sqlite_error
    { operation
    ; detail = Printf.sprintf "%s: %s" (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db)
    }
;;

let exec_sql db operation sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_err db operation rc)
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Sqlite_error { operation; detail })
;;

let with_stmt db operation sql f =
  match Sqlite3.prepare db sql with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Sqlite_error { operation; detail })
  | stmt ->
    Fun.protect
      ~finally:(fun () ->
        try ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t) with
        | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
      (fun () ->
         try f stmt with
         | Sqlite3.Error detail | Sqlite3.SqliteError detail ->
           Error (Sqlite_error { operation; detail }))
;;

let bind_values db operation stmt values =
  let rec loop idx = function
    | [] -> Ok ()
    | v :: rest ->
      let rc = Sqlite3.bind stmt idx v in
      if Sqlite3.Rc.is_success rc then loop (idx + 1) rest
      else Error (sqlite_err db operation rc)
  in
  loop 1 values
;;

let table_exists db table_name =
  with_stmt db "check_table"
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1"
    (fun stmt ->
       let* () = bind_values db "bind_table_name" stmt [ Sqlite3.Data.TEXT table_name ] in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then Ok true
       else if rc = Sqlite3.Rc.DONE
       then Ok false
       else Error (sqlite_err db "check_table" rc))
;;

let read_user_version db =
  with_stmt db "read_user_version" "PRAGMA user_version" (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW
    then Ok (Sqlite3.column_int64 stmt 0)
    else Error (sqlite_err db "read_user_version" rc))
;;

(* [`Absent] when the file holds no compaction tables yet. *)
let schema_state db ~path =
  let* present = table_exists db "compaction_epochs" in
  if not present
  then Ok `Absent
  else
    let* found = read_user_version db in
    if Int64.equal found schema_version
    then Ok `Current
    else Error (Schema_not_current { path; found })
;;

let create_schema_in_tx db ~path =
  let* state = schema_state db ~path in
  match state with
  | `Current -> Ok ()
  | `Absent ->
    let* () =
      exec_sql
        db
        "create_epochs"
        "CREATE TABLE compaction_epochs (\
         epoch_id INTEGER PRIMARY KEY, \
         frame TEXT NOT NULL CHECK (frame IN ('message_history', 'canonical_turns')), \
         anchor_json TEXT NOT NULL, \
         trigger_json TEXT NOT NULL, \
         previous_epoch_id INTEGER)"
    in
    let* () =
      exec_sql
        db
        "create_archived_atoms"
        "CREATE TABLE archived_atoms (\
         epoch_id INTEGER NOT NULL, \
         sequence_ord INTEGER NOT NULL, \
         atom_json TEXT NOT NULL, \
         messages_json TEXT NOT NULL, \
         PRIMARY KEY (epoch_id, sequence_ord), \
         FOREIGN KEY(epoch_id) REFERENCES compaction_epochs(epoch_id))"
    in
    exec_sql
      db
      "set_user_version"
      (Printf.sprintf "PRAGMA user_version=%Ld;" schema_version)
;;

let init_schema db ~path =
  let* () = exec_sql db "pragma_busy" "PRAGMA busy_timeout=5000;" in
  let* () = exec_sql db "pragma_fk" "PRAGMA foreign_keys=ON;" in
  let* () = exec_sql db "pragma_sync" "PRAGMA synchronous=NORMAL;" in
  let* state = schema_state db ~path in
  match state with
  | `Current -> Ok ()
  | `Absent ->
    (* journal_mode cannot change inside a transaction. The tables and the
       version are written under one write lock, so a second process never
       reads the tables at version 0. *)
    let* () = exec_sql db "pragma_wal" "PRAGMA journal_mode=WAL;" in
    let* () = exec_sql db "begin_schema_tx" "BEGIN IMMEDIATE;" in
    let rollback () =
      ignore (exec_sql db "rollback_schema_tx" "ROLLBACK;" : (unit, store_error) result)
    in
    (match create_schema_in_tx db ~path with
     | Ok () -> exec_sql db "commit_schema_tx" "COMMIT;"
     | Error _ as err ->
       rollback ();
       err
     | exception exn ->
       rollback ();
       raise exn)
;;

let sqlite_companions_absent path =
  let rec check = function
    | [] -> Ok true
    | suffix :: rest ->
      (match Unix.lstat (path ^ suffix) with
       | _ -> Ok false
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> check rest
       | exception Unix.Unix_error (code, fn, arg) ->
         Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
  in
  check
    [ Common.sqlite_journal_suffix
    ; Common.sqlite_wal_suffix
    ; Common.sqlite_shm_suffix
    ]
;;

let ensure_dir_result dir =
  try
    Fs_compat.mkdir_p dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error (Sqlite_error { operation = "mkdir_p"; detail })
  | Unix.Unix_error (code, fn, arg) ->
    Error
      (Sqlite_error
         { operation = "mkdir_p"
         ; detail = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
         })
;;

(* [f] runs against a store at {!schema_version}. A read of a file with no
   compaction tables is [Ok None], like a missing file. *)
let with_db ~create ~keepers_dir ~keeper_id f =
  let path = db_path ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let should_open =
      if create
      then
        let* () = ensure_dir_result keepers_dir in
        Ok true
      else (
        match Unix.lstat path with
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
        | exception Unix.Unix_error (code, fn, arg) ->
          Error
            (Sqlite_error
               { operation = "lstat"
               ; detail = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
               })
        | { Unix.st_size = 0; _ } ->
          (match sqlite_companions_absent path with
           | Ok true -> Ok false
           | Ok false ->
             Error
               (Sqlite_error
                  { operation = "db_open"
                  ; detail = "empty compaction database with present sqlite companions"
                  })
           | Error detail -> Error (Sqlite_error { operation = "lstat_companion"; detail }))
        | _ -> Ok true)
    in
    let* open_now = should_open in
    if not open_now
    then Ok None
    else (
      match
        if create
        then Sqlite3.db_open path
        else Sqlite3.db_open ~mode:`READONLY path
      with
      | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
        Error (Sqlite_error { operation = "db_open"; detail })
      | db ->
        Fun.protect
          ~finally:(fun () ->
            try ignore (Sqlite3.db_close db : bool) with
            | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
          (fun () ->
             if create
             then
               let* () = init_schema db ~path in
               f db
             else
               let* () = exec_sql db "pragma_busy_ro" "PRAGMA busy_timeout=5000;" in
               let* state = schema_state db ~path in
               match state with
               | `Absent -> Ok None
               | `Current -> f db)))
;;

let decode_anchor_string ~context raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error (Corrupt_record { context; detail })
  | json ->
    anchor_of_json json
    |> Result.map_error (fun detail -> Corrupt_record { context; detail })
;;

let encode_messages (msgs : Agent_core.Types.message list) =
  Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json msgs))
;;

let select_latest_anchor db ~operation =
  with_stmt
    db
    operation
    "SELECT anchor_json FROM compaction_epochs ORDER BY epoch_id DESC LIMIT 1"
    (fun stmt ->
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then (
         let raw = Sqlite3.column_text stmt 0 in
         let* anchor = decode_anchor_string ~context:operation raw in
         Ok (Some (anchor, String.length raw)))
       else if rc = Sqlite3.Rc.DONE
       then Ok None
       else Error (sqlite_err db operation rc))
;;

let latest_anchor ~keepers_dir ~keeper_id =
  with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
    let* latest = select_latest_anchor db ~operation:"latest_anchor" in
    Ok (Option.map fst latest))
;;

type stats =
  { present : bool
  ; epoch_count : int
  ; latest_anchor : compaction_anchor option
  ; archived_atom_count : int
  ; anchor_bytes : int
  }

let query_count db ~op ~sql =
  with_stmt db op sql (fun stmt ->
    let rc = Sqlite3.step stmt in
    if rc = Sqlite3.Rc.ROW
    then Ok (Int64.to_int (Sqlite3.column_int64 stmt 0))
    else if rc = Sqlite3.Rc.DONE
    then Ok 0
    else Error (sqlite_err db op rc))
;;

let inspect_stats ~keepers_dir ~keeper_id =
  let* res =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      let* epoch_count =
        query_count db ~op:"count_compaction_epochs" ~sql:"SELECT COUNT(*) FROM compaction_epochs"
      in
      let* archived_atom_count =
        query_count db ~op:"count_archived_atoms" ~sql:"SELECT COUNT(*) FROM archived_atoms"
      in
      let* latest = select_latest_anchor db ~operation:"inspect_stats" in
      Ok
        (Some
           { present = true
           ; epoch_count
           ; latest_anchor = Option.map fst latest
           ; archived_atom_count
           ; anchor_bytes = Option.fold ~none:0 ~some:snd latest
           }))
  in
  match res with
  | Some s -> Ok s
  | None ->
    Ok
      { present = false
      ; epoch_count = 0
      ; latest_anchor = None
      ; archived_atom_count = 0
      ; anchor_bytes = 0
      }
;;

(* Stream-extract ONLY live blob/media references (plus any malformed refs so
   sweep fails closed) from each SQLite JSON row and discard the full row AST
   immediately, avoiding O(entire-archive) RAM allocation. *)
let history_tool_payload_key fields =
  match List.assoc_opt "type" fields with
  | Some (`String "tool_use") -> Some "input"
  | Some (`String "tool_result") -> Some "tool_result_json"
  | _ -> None
;;

let rec extract_blob_refs_from_json ~history_media ~seen ~acc_rev (json : Yojson.Safe.t) =
  match json with
  | `String text ->
    (match Tool_output.decode_any_handle text with
     | Tool_output.Not_marker -> ()
     | Tool_output.Decoded ref_ ->
       let key = "s:" ^ ref_.sha256 ^ ":" ^ ref_.mime ^ ":" ^ text in
       if not (Hashtbl.mem seen key)
       then (
         Hashtbl.add seen key ();
         acc_rev := `String text :: !acc_rev)
     | Tool_output.Invalid_marker _ ->
       (* Preserve invalid markers so Tool_blob_maintenance still fails closed. *)
       acc_rev := `String text :: !acc_rev)
  | `Assoc fields ->
    (match Tool_output.normalized_artifact_ref_of_json json with
     | Tool_output.Decoded_normalized_artifact_ref ref_ ->
       let key = "a:" ^ ref_.sha256 ^ ":" ^ ref_.mime in
       if not (Hashtbl.mem seen key)
       then (
         Hashtbl.add seen key ();
         acc_rev := json :: !acc_rev)
     | Tool_output.Invalid_normalized_artifact_ref _ -> acc_rev := json :: !acc_rev
     | Tool_output.Not_normalized_artifact_ref ->
       let media_decoded =
         if history_media
         then Agent_core_base.History.stored_source_of_json json
         else Agent_core_base.History.Not_stored_source
       in
       (match media_decoded with
        | Agent_core_base.History.Decoded_stored_source { stored; media_type = _ } ->
          let key = "m:" ^ stored.sha256 in
          if not (Hashtbl.mem seen key)
          then (
            Hashtbl.add seen key ();
            acc_rev := json :: !acc_rev)
        | Agent_core_base.History.Invalid_stored_source _ -> acc_rev := json :: !acc_rev
        | Agent_core_base.History.Not_stored_source ->
          let skipped_media_key = if history_media then history_tool_payload_key fields else None in
          List.iter
            (fun (k, v) ->
               let child_media =
                 history_media
                 &&
                 match skipped_media_key with
                 | Some skip -> not (String.equal k skip)
                 | None -> true
               in
               extract_blob_refs_from_json ~history_media:child_media ~seen ~acc_rev v)
            fields))
  | `List items ->
    List.iter (extract_blob_refs_from_json ~history_media ~seen ~acc_rev) items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> ()
;;

let stream_blob_refs_from_column db ~operation ~sql ~seen ~acc_rev =
  with_stmt db operation sql (fun stmt ->
    let rec loop () =
      let rc = Sqlite3.step stmt in
      if rc = Sqlite3.Rc.ROW
      then (
        let raw = Sqlite3.column_text stmt 0 in
        match Yojson.Safe.from_string raw with
        | json ->
          extract_blob_refs_from_json ~history_media:true ~seen ~acc_rev json;
          loop ()
        | exception Yojson.Json_error detail ->
          Error (Corrupt_record { context = operation; detail }))
      else if rc = Sqlite3.Rc.DONE
      then Ok ()
      else Error (sqlite_err db operation rc)
    in
    loop ())
;;

let decode_live_blob_references_json path =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
    | { Unix.st_size = 0; _ } ->
      (match sqlite_companions_absent path with
       | Ok true -> Ok None
       | Error reason -> Error reason
       | Ok false -> Error "empty compaction database with present sqlite companions")
    | _ ->
      (match Sqlite3.db_open ~mode:`READONLY path with
       | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
         Error (Printf.sprintf "compaction sqlite db_open failed: %s" detail)
       | db ->
         Fun.protect
           ~finally:(fun () ->
             try ignore (Sqlite3.db_close db : bool) with
             | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
           (fun () ->
              let res =
                let* () = exec_sql db "pragma_busy_ro" "PRAGMA busy_timeout=5000;" in
                let* () = exec_sql db "begin_read_tx" "BEGIN DEFERRED;" in
                let rollback () =
                  ignore (exec_sql db "rollback_read_tx" "ROLLBACK;" : (unit, store_error) result)
                in
                let work () =
                  let* state = schema_state db ~path in
                  match state with
                  | `Absent ->
                    let* () = exec_sql db "commit_read_tx" "COMMIT;" in
                    Ok None
                  | `Current ->
                    let seen = Hashtbl.create 32 in
                    let acc_rev = ref [] in
                    let* () =
                      stream_blob_refs_from_column
                        db
                        ~operation:"scan_epochs"
                        ~sql:"SELECT anchor_json FROM compaction_epochs ORDER BY epoch_id ASC"
                        ~seen
                        ~acc_rev
                    in
                    let* () =
                      stream_blob_refs_from_column
                        db
                        ~operation:"scan_archived_atoms"
                        ~sql:
                          "SELECT messages_json FROM archived_atoms \
                           ORDER BY epoch_id ASC, sequence_ord ASC"
                        ~seen
                        ~acc_rev
                    in
                    let* () = exec_sql db "commit_read_tx" "COMMIT;" in
                    (match List.rev !acc_rev with
                     | [] -> Ok None
                     | non_empty -> Ok (Some (`List non_empty)))
                in
                match work () with
                | Ok _ as ok -> ok
                | Error _ as err ->
                  rollback ();
                  err
                | exception exn ->
                  rollback ();
                  raise exn
              in
              Result.map_error store_error_to_string res)))
;;

let insert_epoch_and_atoms_in_tx db ~frame ~trigger ~anchor ~(archived : archived_atom list) =
  let previous_epoch =
    if anchor.epoch_id > 1
    then Sqlite3.Data.INT (Int64.of_int (anchor.epoch_id - 1))
    else Sqlite3.Data.NULL
  in
  let* () =
    with_stmt
      db
      "insert_epoch"
      "INSERT INTO compaction_epochs \
       (epoch_id, frame, anchor_json, trigger_json, previous_epoch_id) \
       VALUES (?1, ?2, ?3, ?4, ?5)"
      (fun stmt ->
         let* () =
           bind_values
             db
             "bind_epoch"
             stmt
             [ Sqlite3.Data.INT (Int64.of_int anchor.epoch_id)
             ; Sqlite3.Data.TEXT (Keeper_compaction_atom.frame_to_string frame)
             ; Sqlite3.Data.TEXT (Yojson.Safe.to_string (anchor_to_json anchor))
             ; Sqlite3.Data.TEXT (Yojson.Safe.to_string (trigger_to_json trigger))
             ; previous_epoch
             ]
         in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.DONE
         then Ok ()
         else Error (sqlite_err db "insert_epoch" rc))
  in
  with_stmt
    db
    "insert_archived_atom"
    "INSERT INTO archived_atoms (epoch_id, sequence_ord, atom_json, messages_json) \
     VALUES (?1, ?2, ?3, ?4)"
    (fun stmt ->
       let rec insert_all ord = function
         | [] -> Ok ()
         | (atom : archived_atom) :: rest ->
           let* () =
             bind_values
               db
               "bind_archived_atom"
               stmt
               [ Sqlite3.Data.INT (Int64.of_int anchor.epoch_id)
               ; Sqlite3.Data.INT (Int64.of_int ord)
               ; Sqlite3.Data.TEXT
                   (Yojson.Safe.to_string (Keeper_compaction_atom.name_to_json atom.name))
               ; Sqlite3.Data.TEXT (encode_messages atom.messages)
               ]
           in
           let rc = Sqlite3.step stmt in
           if rc = Sqlite3.Rc.DONE
           then (
             let rc = Sqlite3.reset stmt in
             if Sqlite3.Rc.is_success rc
             then insert_all (ord + 1) rest
             else Error (sqlite_err db "reset_archived_atom" rc))
           else Error (sqlite_err db "insert_archived_atom" rc)
       in
       insert_all 0 archived)
;;

let default_anchor_message_bytes (msg : Agent_core.Types.message) =
  List.fold_left
    (fun acc -> function
      | Agent_core.Types.Text s -> acc + String.length s
      | Thinking { content; _ } -> acc + String.length content
      | RedactedThinking s -> acc + String.length s
      | ToolResult { content; _ } -> acc + String.length content
      | ToolUse { name; input; _ } ->
        acc + String.length name + String.length (Yojson.Safe.to_string input)
      | ToolReference { tool_name; _ } -> acc + String.length tool_name
      | ReasoningDetails _ | Image _ | Document _ | Audio _ -> acc)
    0
    msg.content
;;

let prefix_eviction_of_window ~offered ~windowed =
  let drop_preamble =
    List.filter (fun msg -> not (Runtime_model_input_tail_window.is_synthetic_preamble msg))
  in
  let offered = drop_preamble offered in
  let _, offered_atoms = Runtime_model_input_tail_window.annotate offered in
  let _, kept_atoms = Runtime_model_input_tail_window.annotate (drop_preamble windowed) in
  offered, Int.max 0 (offered_atoms - kept_atoms)
;;

let effective_anchor_budget ?max_anchor_bytes trigger =
  (* Always bound the committed anchor even when the provider omits a token
     limit; convert provider token limits to bytes via
     [compaction_bytes_of_tokens] before applying the structural window
     ratio. *)
  match max_anchor_bytes with
  | Some n -> max 0 n
  | None ->
    (match trigger with
     | Explicit_hard_limit { capacity_bytes; _ } ->
       anchor_budget_for_window ~capacity_bytes ~reserved_bytes:0
     | Provider_context_overflow { provider_limit_tokens = Some tok }
     | Provider_counted_window { limit_tokens = tok; used_tokens = _ } ->
       let capacity_bytes = compaction_bytes_of_tokens tok in
       anchor_budget_for_window ~capacity_bytes ~reserved_bytes:0
     | Provider_context_overflow { provider_limit_tokens = None } -> default_anchor_max_bytes)
;;

let latest_anchor_in_tx db =
  let* latest = select_latest_anchor db ~operation:"latest_anchor_tx" in
  Ok (Option.map fst latest)
;;

(* The coverage of the latest epoch committed over [frame]. Names are counted
   inside one list, so a producer carries on only its own kind: coverage
   written over the other kind would claim atoms its list holds differently
   or never held. *)
let latest_coverage_in_frame db ~frame =
  let operation = "latest_coverage_in_frame" in
  with_stmt
    db
    operation
    "SELECT anchor_json FROM compaction_epochs WHERE frame = ?1 \
     ORDER BY epoch_id DESC LIMIT 1"
    (fun stmt ->
       let* () =
         bind_values
           db
           "bind_frame"
           stmt
           [ Sqlite3.Data.TEXT (Keeper_compaction_atom.frame_to_string frame) ]
       in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then (
         let* anchor =
           decode_anchor_string ~context:operation (Sqlite3.column_text stmt 0)
         in
         Ok (Some anchor.coverage))
       else if rc = Sqlite3.Rc.DONE
       then Ok None
       else Error (sqlite_err db operation rc))
;;

let latest_coverages db =
  let* message_history =
    latest_coverage_in_frame db ~frame:Keeper_compaction_atom.Message_history
  in
  let* canonical_turns =
    latest_coverage_in_frame db ~frame:Keeper_compaction_atom.Canonical_turns
  in
  Ok { Keeper_compaction_atom.message_history; canonical_turns }
;;

let compact_evicted_messages
      ?redact
      ?max_anchor_bytes
      ?(measure_message_bytes = default_anchor_message_bytes)
      ?on_epoch_committed
      ~keepers_dir
      ~keeper_id
      ~trigger
      ~frame
      ~messages
      ~(eviction : Keeper_compaction_atom.eviction)
      ()
  =
  match eviction with
  | { prefix = 0; later = [] } -> Ok None
  | { prefix = _; later = _ } ->
    let atoms = Keeper_compaction_atom.atoms_of_messages messages in
    let budget = effective_anchor_budget ?max_anchor_bytes trigger in
    (* Read the latest anchor, decide the new atoms, fold, and commit inside
       ONE [BEGIN IMMEDIATE] transaction off-domain, so concurrent callers
       serialize on the write lock and never fold onto a stale anchor. *)
    let* committed =
      with_db ~create:true ~keepers_dir ~keeper_id (fun db ->
        let effective_redact = resolve_redact ?redact ~keepers_dir ~keeper_id () in
        let* () = exec_sql db "begin_tx" "BEGIN IMMEDIATE;" in
        let rollback () =
          ignore (exec_sql db "rollback_tx" "ROLLBACK;" : (unit, store_error) result)
        in
        let work () =
          (* The latest epoch of either kind carries the summary on; only an
             epoch over this kind of list says which atoms are archived. *)
          let* previous = latest_anchor_in_tx db in
          let* latest = latest_coverages db in
          let* step =
            Keeper_compaction_atom.advance
              ~previous:(Keeper_compaction_atom.latest_over frame latest)
              atoms
              eviction
            |> Result.map_error (fun detail -> Invalid_eviction detail)
          in
          match step with
          | None ->
            let* () = exec_sql db "commit_noop_tx" "COMMIT;" in
            Ok None
          | Some { coverage; fresh } ->
            (* An atom at or before the front either kind has reached is
               archived for this kind but stays out of the summary: the
               summary already passed its turn, and folding it again would
               put an older turn after newer ones. *)
            let summarized_end =
              Keeper_compaction_atom.furthest_covered_end ~frame latest atoms
            in
            let archived =
              List.map
                (fun index ->
                   let (atom : Keeper_compaction_atom.atom) = atoms.(index) in
                   ( index
                   , { name = atom.name
                     ; messages = List.map (redact_message effective_redact) atom.messages
                     } ))
                fresh
            in
            let unsummarized =
              List.filter_map
                (fun (index, atom) -> if index > summarized_end then Some atom else None)
                archived
            in
            let anchor =
              fold_anchor ~previous ~coverage ~fresh:unsummarized
              |> redact_anchor effective_redact
              |> bound_anchor_to_budget ~measure_message_bytes ~max_anchor_bytes:budget
            in
            let* () =
              insert_epoch_and_atoms_in_tx
                db
                ~frame
                ~trigger
                ~anchor
                ~archived:(List.map snd archived)
            in
            let* () = exec_sql db "commit_tx" "COMMIT;" in
            Ok (Some anchor)
        in
        match work () with
        | Ok _ as ok -> ok
        | Error _ as err ->
          rollback ();
          err
        | exception exn ->
          rollback ();
          raise exn)
    in
    (match committed with
     | None -> Ok None
     | Some anchor ->
       notify_global_epoch_committed ~keepers_dir ~keeper_id anchor;
       Option.iter (fun cb -> cb anchor) on_epoch_committed;
       Ok (Some anchor))
;;

let messages_after_front ~latest messages =
  (* Cut past the later of the last inline compaction anchor message and the
     furthest front the latest epochs cover, so a stale inline anchor from an
     earlier epoch never hides a newer persisted boundary. *)
  let _, inline_pos =
    List.fold_left
      (fun (position, last) msg ->
         ( position + 1
         , if Runtime_model_input_tail_window.is_compaction_anchor msg then position else last ))
      (0, -1)
      messages
  in
  let atoms = Keeper_compaction_atom.atoms_of_messages messages in
  let covered =
    Keeper_compaction_atom.furthest_covered_end
      ~frame:Keeper_compaction_atom.Message_history
      latest
      atoms
  in
  let covered_pos = if covered < 0 then -1 else atoms.(covered).last_position in
  let cut_pos = Int.max inline_pos covered_pos in
  if cut_pos < 0
  then messages
  else List.filteri (fun pos _ -> pos > cut_pos) messages
;;

let live_history_after_latest_anchor ~keepers_dir ~keeper_id messages =
  (* The two reads run outside a transaction, so they may straddle a commit.
     Each still returns the boundary of a committed epoch, so the furthest of
     the two is a front some epoch covered. *)
  let* latest =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      let* latest = latest_coverages db in
      Ok (Some latest))
  in
  match latest with
  | None | Some { Keeper_compaction_atom.message_history = None; canonical_turns = None } ->
    Ok messages
  | Some ({ Keeper_compaction_atom.message_history = Some _; canonical_turns = _ } as latest)
  | Some ({ Keeper_compaction_atom.message_history = None; canonical_turns = Some _ } as latest)
    ->
    Ok (messages_after_front ~latest messages)
;;
