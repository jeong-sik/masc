type mode =
  | Auto
  | Yolo
[@@deriving enumerate]

let mode_to_string = function
  | Auto -> "auto"
  | Yolo -> "yolo"

let mode_of_string s = List.find_opt (fun v -> String.equal (mode_to_string v) s) all_of_mode

(* Overrides only, oldest set first. An operator watches a handful of
   keepers, so a linear list is the whole cost — the same sizing argument as
   the approval registry's waiter list.

   Readers and writers reach the registry differently. [resolve] runs on every
   keeper turn and the dashboard lists the overrides per request, so they read
   one immutable [state] from an [Atomic.t] and never wait for a writer. A
   writer ([set], [bind]) holds [writer] while it reads and rewrites the store
   file, and publishes the next [state] with one [Atomic.set], so a reader sees
   the overrides and the restore error of the same write, never one of each.

   [writer] is a [Cross_context_mutex], not a [Stdlib.Mutex]: a writer suspends
   inside its critical section, because [Fs_compat] runs the store read and the
   atomic replacement on a worker thread, and the fibers of a domain share one
   thread. A [Stdlib.Mutex] held across that suspension raises
   [Sys_error "Mutex.lock: Resource deadlock avoided"] for the next fiber that
   locks it instead of making it wait. The cross-context lock makes a fiber
   wait cooperatively, and system threads and other domains still block on the
   underlying mutex. *)
type state =
  { overrides : (string * mode) list
  ; restore_error : string option
  }

type t =
  { state : state Atomic.t
  ; writer : Cross_context_mutex.t
  }

let create () =
  { state = Atomic.make { overrides = []; restore_error = None }
  ; writer = Cross_context_mutex.create ()
  }
;;

(* Created at load, so a stance set over HTTP and a gate consulting it cannot
   see two different registries. *)
let shared_registry = create ()
let shared () = shared_registry

let resolve t ~keeper_name =
  match List.assoc_opt keeper_name (Atomic.get t.state).overrides with
  | Some mode -> mode
  | None -> Auto
;;

let overrides t = (Atomic.get t.state).overrides
let last_restore_error t = (Atomic.get t.state).restore_error

(* One row per keeper an operator has moved off [Auto]. [actor] and
   [changed_at] follow the Keeper_gate_mode override convention: the file
   is small, so it doubles as the change record. *)
type override_row =
  { keeper_name : string
  ; mode : mode
  ; actor : string
  ; changed_at : string
  }

let override_row_json o =
  `Assoc
    [ "keeper_name", `String o.keeper_name
    ; "mode", `String (mode_to_string o.mode)
    ; "updated_by", `String o.actor
    ; "updated_at", `String o.changed_at
    ]
;;

let override_row_of_json = function
  | `Assoc fields ->
    let string_field key =
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None ->
        Error (Printf.sprintf "tool approval mode override is missing %s" key)
    in
    (match string_field "keeper_name" with
     | Error detail -> Error detail
     | Ok keeper_name ->
       (match List.assoc_opt "mode" fields with
        | None -> Error "tool approval mode override is missing mode"
        | Some (`String raw) ->
          (match mode_of_string raw with
           | None ->
             Error
               (Printf.sprintf
                  "tool approval mode override mode must be auto or yolo, got %S"
                  raw)
           | Some mode ->
             let or_unknown = function Ok value -> value | Error _ -> "" in
             Ok
               { keeper_name
               ; mode
               ; actor = or_unknown (string_field "updated_by")
               ; changed_at = or_unknown (string_field "updated_at")
               })
        | Some _ -> Error "tool approval mode override mode must be a string"))
  | _ -> Error "tool approval mode override must be an object"
;;

let file_schema = "masc.tool_approval_modes.v1"

let file_json rows =
  `Assoc
    [ "schema", `String file_schema
    ; "overrides", `List (List.map override_row_json rows)
    ]
;;

let rows_of_file_json = function
  | `Assoc fields ->
    (match List.assoc_opt "schema" fields with
     | Some (`String tag) when String.equal tag file_schema ->
       (match List.assoc_opt "overrides" fields with
        | None -> Error "tool approval mode store is missing overrides"
        | Some (`List rows) ->
          List.fold_left
            (fun acc row ->
               match acc, override_row_of_json row with
               | Error detail, _ -> Error detail
               | Ok _, Error detail -> Error detail
               | Ok kept, Ok parsed -> Ok (parsed :: kept))
            (Ok []) rows
          |> Result.map List.rev
        | Some _ -> Error "tool approval mode overrides must be a list")
     | Some (`String tag) ->
       Error
         (Printf.sprintf
            "tool approval mode store has unexpected schema %S (want %S)"
            tag
            file_schema)
     | Some _ | None -> Error "tool approval mode store is missing schema")
  | _ -> Error "tool approval mode store must be an object"
;;

(* An unreadable store is an error rather than an empty list. Reading it as
   "nobody was singled out" would silently fall back to the stricter [Auto]
   default without distinguishing a broken store from an empty one (same rule
   as [Keeper_gate_mode.keeper_overrides]). *)
let keeper_overrides ~base_path =
  let file = Keeper_gate_path.tool_approval_modes ~base_path in
  if not (Sys.file_exists file)
  then Ok []
  else
    match Safe_ops.read_json_file_safe file with
    | Error detail ->
      Error (Printf.sprintf "tool approval mode store read failed (%s): %s" file detail)
    | Ok json ->
      rows_of_file_json json
      |> Result.map_error (fun detail ->
           Printf.sprintf "tool approval mode store (%s): %s" file detail)
;;

type set_outcome =
  | Applied
  | Applied_audit_failed of string

(* The registry state a store that reads back as [rows] stands for. *)
let state_of_rows rows =
  { overrides = List.map (fun row -> row.keeper_name, row.mode) rows
  ; restore_error = None
  }
;;

let set t ~base_path ~actor ~keeper_name mode =
  (* The writer lock spans the whole read-modify-write, not just the memory
     part: the file and the registry are one logical state, so two in-process
     writers must not interleave read and write phases — the second would
     read the first's pre-image and clobber it. The lock is the durable
     variant: once a writer holds it, a cancellation waits until the rename
     and the memory publish are both done, so the file and the registry cannot
     disagree. The durable write still lands before memory for [Yolo], so a
     failed [set] holds neither. When revoking to [Auto], if the store cannot
     be read, the keeper's in-memory override is removed immediately so the
     operator can always fail closed to [Auto] even while the disk store
     awaits repair. The audit record is deliberately outside the lock: it must
     not hold the next writer up on event-bus latency, and a failed record
     does not change the durable answer. Readers take no lock, so none of this
     I/O makes [resolve] wait. *)
  let result =
    Cross_context_mutex.with_durable_lock t.writer (fun () ->
        match keeper_overrides ~base_path with
        | Error detail ->
          let current = Atomic.get t.state in
          let overrides, returned_error =
            match mode with
            | Auto ->
              ( List.filter
                  (fun (name, _) -> not (String.equal name keeper_name))
                  current.overrides
              , Printf.sprintf
                  "%s (revoked to auto in memory; repairing the store file without removing %s will restore its persisted row on restart)"
                  detail
                  keeper_name )
            | Yolo -> current.overrides, detail
          in
          Atomic.set t.state { overrides; restore_error = Some detail };
          Error returned_error
        | Ok rows ->
          let changed_at = Masc_domain.now_iso () in
          let without =
            List.filter
              (fun row -> not (String.equal row.keeper_name keeper_name))
              rows
          in
          (* Removing rather than storing a synonym for "no opinion": the
             file is then also the list of keepers an operator has actually
             singled out, and a screen showing it does not have to filter. *)
          let rows =
            match mode with
            | Auto -> without
            | Yolo -> without @ [ { keeper_name; mode; actor; changed_at } ]
          in
          (match
             try
               Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
               Ok ()
             with
             | Sys_error detail ->
               Error
                 (Printf.sprintf "tool approval mode store mkdir failed: %s" detail)
           with
           | Error _ as error -> error
           | Ok () ->
             match
               Fs_compat.save_file_atomic
                 (Keeper_gate_path.tool_approval_modes ~base_path)
                 (Yojson.Safe.pretty_to_string (file_json rows))
             with
             | Error detail ->
               Error
                 (Printf.sprintf "tool approval mode store write failed: %s" detail)
             | Ok () ->
               Atomic.set t.state (state_of_rows rows);
               Ok changed_at))
  in
  match result with
  | Error _ as error -> error
  | Ok changed_at ->
    (* The stance stands durably and in memory from here; if its companion
       audit record fails, report [Ok (Applied_audit_failed _)] rather than
       [Error _] so callers do not mistake an applied permission change for
       a rolled-back failure. *)
    (try
       Audit_log.log_action
         (Workspace.default_config base_path)
         ~agent_id:actor
         ~action:(Audit_log.Custom "keeper_tool_approval_mode_set")
         ~details:
           (`Assoc
              [ "keeper_name", `String keeper_name
              ; ( "mode"
                , match mode with
                  | Auto -> `Null
                  | Yolo -> `String "yolo" )
              ; "changed_at", `String changed_at
              ; "actor", `String actor
              ])
         ~outcome:Audit_log.Success
         ();
       Ok Applied
     with
     | Sys_error detail ->
       Ok
         (Applied_audit_failed
            (Printf.sprintf "tool approval mode audit failed: %s" detail))
     | Unix.Unix_error (code, operation, argument) ->
       (* The audit append creates its dated directory with [Unix.mkdir]
          ([Fs_compat.mkdir_p_unix]), which raises [Unix_error] rather than
          [Sys_error] when the store path is blocked (ENOTDIR) or unwritable. *)
       Ok
         (Applied_audit_failed
            (Printf.sprintf
               "tool approval mode audit failed: %s(%s): %s"
               operation
               argument
               (Unix.error_message code))))
;;

let bind ~base_path t =
  (* The replay reads the store and publishes under the writer lock. A replay
     that read the file before a concurrent [set] stored its row and published
     after that [set] updated memory would put the stale rows back. *)
  Cross_context_mutex.with_durable_lock t.writer (fun () ->
      match keeper_overrides ~base_path with
      | Ok rows ->
        Atomic.set t.state (state_of_rows rows);
        Ok ()
      | Error detail ->
        Atomic.set
          t.state
          { (Atomic.get t.state) with restore_error = Some detail };
        Error detail)
;;
