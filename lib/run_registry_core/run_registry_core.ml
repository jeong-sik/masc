module Json = struct
  let object_fields = function
    | `Assoc fields -> Ok fields
    | json ->
      Error
        (Printf.sprintf
           "expected object, got %s"
           (Yojson.Safe.to_string json))
  ;;

  let exact_fields ~required ?(optional = []) fields =
    let expected = List.sort_uniq String.compare (required @ optional) in
    let actual = List.map fst fields in
    let unique_actual = List.sort_uniq String.compare actual in
    let missing = List.filter (fun key -> not (List.mem key unique_actual)) required in
    let unknown = List.filter (fun key -> not (List.mem key expected)) unique_actual in
    let duplicate_count = List.length actual - List.length unique_actual in
    match missing, unknown, duplicate_count with
    | [], [], 0 -> Ok ()
    | _ ->
      Error
        (Printf.sprintf
           "object fields mismatch (missing=[%s], unknown=[%s], duplicates=%d)"
           (String.concat "," missing)
           (String.concat "," unknown)
           duplicate_count)
  ;;

  let field name fields =
    match List.assoc_opt name fields with
    | Some json -> Ok json
    | None -> Error (Printf.sprintf "missing field %s" name)
  ;;

  let string_field name fields =
    match field name fields with
    | Error _ as error -> error
    | Ok (`String value) -> Ok value
    | Ok json ->
      Error
        (Printf.sprintf
           "field %s expected string, got %s"
           name
           (Yojson.Safe.to_string json))
  ;;

  let float_field name fields =
    match field name fields with
    | Error _ as error -> error
    | Ok (`Float value) -> Ok value
    | Ok (`Int value) -> Ok (float_of_int value)
    | Ok json ->
      Error
        (Printf.sprintf
           "field %s expected float, got %s"
           name
           (Yojson.Safe.to_string json))
  ;;

  let optional_string_field name fields =
    match List.assoc_opt name fields with
    | None -> Ok None
    | Some (`String value) -> Ok (Some value)
    | Some json ->
      Error
        (Printf.sprintf
           "field %s expected string when present, got %s"
           name
           (Yojson.Safe.to_string json))
  ;;
end

module type Payload = sig
  type registration
  type completion

  val name : string
  val registration_to_yojson : registration -> Yojson.Safe.t
  val registration_of_yojson : Yojson.Safe.t -> (registration, string) result
  val completion_to_yojson : completion -> Yojson.Safe.t
  val completion_of_yojson : Yojson.Safe.t -> (completion, string) result
  val running_noun : string
  val restart_reason : string
  val replayed_running_completion
    : (started_at:float -> registration -> completion) option
  val completed_retention : [ `All | `Latest of int ]
  val retention_group : (registration -> string) option
end

type persistence_state =
  | Not_persisted
  | Durability_unknown

type persistence_failure =
  { detail : string
  ; state : persistence_state
  }

type cut_report =
  { lines_read : int
  ; malformed_lines : int
  ; retained_entries : int
  ; reached_end : bool
  ; rewritten : bool
  }

module Make (Payload : Payload) = struct
  type status =
    | Running
    | Completed of Payload.completion

  type entry =
    { id : string
    ; started_at : float
    ; registration : Payload.registration
    ; status : status
    }

  type t =
    { entries : entry list Atomic.t
    ; path : string option
    ; mutation_mutex : Cross_context_mutex.t
    }

  type event =
    | Register of
        { id : string
        ; started_at : float
        ; registration : Payload.registration
        }
    | Complete of
        { id : string
        ; completion : Payload.completion
        }

  let ( let* ) = Result.bind
  let max_completed_retained =
    match Payload.completed_retention with
    | `Latest count when count > 0 -> count
    | `Latest count ->
      invalid_arg
        (Printf.sprintf "%s completed retention must be positive, got %d" Payload.name count)
    | `All -> max_int
  ;;

  let is_running entry =
    match entry.status with
    | Running -> true
    | Completed _ -> false
  ;;

  let prune entries =
    match Payload.completed_retention with
    | `All -> entries
    | `Latest _ ->
      let running, completed = List.partition is_running entries in
      let newest_first =
        List.sort
          (fun left right -> Float.compare right.started_at left.started_at)
          completed
      in
      let recent_completed =
        match Payload.retention_group with
        | None ->
          List.filteri (fun index _ -> index < max_completed_retained) newest_first
        | Some group_of ->
          (* Per-group bound: count within each group while preserving the
             global newest-first order, so a busy group cannot evict a quiet
             one's history. *)
          let seen : (string, int) Hashtbl.t = Hashtbl.create 8 in
          List.filter
            (fun entry ->
               let group = group_of entry.registration in
               let kept = Option.value (Hashtbl.find_opt seen group) ~default:0 in
               if kept < max_completed_retained
               then (
                 Hashtbl.replace seen group (kept + 1);
                 true)
               else false)
            newest_first
      in
      running @ recent_completed
  ;;

  let create ?path () =
    { entries = Atomic.make []
    ; path
    ; mutation_mutex = Cross_context_mutex.create ()
    }

  let event_to_yojson = function
    | Register { id; started_at; registration } ->
      `Assoc
        [ "event", `String "register"
        ; "id", `String id
        ; "started_at", `Float started_at
        ; "registration", Payload.registration_to_yojson registration
        ]
    | Complete { id; completion } ->
      `Assoc
        [ "event", `String "complete"
        ; "id", `String id
        ; "completion", Payload.completion_to_yojson completion
        ]
  ;;

  let event_of_yojson json =
    let* fields = Json.object_fields json in
    let* event = Json.string_field "event" fields in
    match event with
    | "register" ->
      let* () =
        Json.exact_fields
          ~required:[ "event"; "id"; "started_at"; "registration" ]
          fields
      in
      let* id = Json.string_field "id" fields in
      let* started_at = Json.float_field "started_at" fields in
      let* registration_json =
        match List.assoc_opt "registration" fields with
        | Some value -> Ok value
        | None -> Error "missing field registration"
      in
      let* registration = Payload.registration_of_yojson registration_json in
      Ok (Register { id; started_at; registration })
    | "complete" ->
      let* () =
        Json.exact_fields ~required:[ "event"; "id"; "completion" ] fields
      in
      let* id = Json.string_field "id" fields in
      let* completion_json =
        match List.assoc_opt "completion" fields with
        | Some value -> Ok value
        | None -> Error "missing field completion"
      in
      let* completion = Payload.completion_of_yojson completion_json in
      Ok (Complete { id; completion })
    | label -> Error (Printf.sprintf "unknown %s event %S" Payload.name label)
  ;;

  let append_event_result t event =
    match t.path with
    | None -> Ok ()
    | Some path ->
      let suffix = Yojson.Safe.to_string (event_to_yojson event) ^ "\n" in
      (match Fs_compat.append_private_jsonl_durable_locked_result path suffix with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         Error
           { detail =
               Printf.sprintf
                 "%s: durable append raised for %s: %s"
                 Payload.name
                 path
                 (Printexc.to_string exn)
           ; state = Durability_unknown
           }
       | Private_file_succeeded () -> Ok ()
       | Private_file_succeeded_with_cleanup_failure
           { value = (); cleanup_failure } ->
         Log.Misc.error
           "%s: durable append committed for %s but descriptor settlement failed: %s"
           Payload.name
           path
           (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
         Ok ()
       | Private_file_failed error ->
         let state =
           match error with
           | Durable_jsonl_append_failed { rollback_failures = _ :: _; _ } ->
             Durability_unknown
           | Incomplete_jsonl_tail
           | Invalid_jsonl_suffix
           | Negative_expected_end_offset _
           | End_offset_mismatch _
           | Durable_jsonl_append_failed { rollback_failures = []; _ } ->
             Not_persisted
         in
         Error
           { detail =
               Printf.sprintf
                 "%s: durable append failed for %s: %s"
                 Payload.name
                 path
                 (Fs_compat.private_jsonl_append_error_to_string error)
           ; state
           }
       | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
         let state =
           match error with
           | Durable_jsonl_append_failed { rollback_failures = _ :: _; _ } ->
             Durability_unknown
           | Incomplete_jsonl_tail
           | Invalid_jsonl_suffix
           | Negative_expected_end_offset _
           | End_offset_mismatch _
           | Durable_jsonl_append_failed { rollback_failures = []; _ } ->
             Not_persisted
         in
         Error
           { detail =
               Printf.sprintf
                 "%s: durable append failed for %s: %s; descriptor settlement failed: %s"
                 Payload.name
                 path
                 (Fs_compat.private_jsonl_append_error_to_string error)
                 (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
           ; state
           })
  ;;

  let append_event_exn t event =
    match append_event_result t event with
    | Ok () -> ()
    | Error failure -> raise (Sys_error failure.detail)
  ;;

  let replace_entry_locked t entry =
    let current = Atomic.get t.entries in
    let without_same_id =
      List.filter (fun existing -> not (String.equal existing.id entry.id)) current
    in
    let next = prune (entry :: without_same_id) in
    Atomic.set t.entries next
  ;;

  let register t ~id ~started_at ~registration =
    let entry = { id; started_at; registration; status = Running } in
    (* Memory publication and JSONL append are one ordered mutation. Without
       this registry-local lock, a completion on another domain can observe the
       new row after the CAS and append [Complete] before this [Register]
       reaches the path-level append lock. Replay then skips the completion as
       unknown and drops the trailing register as stale Running.

       [Cross_context_mutex], not [Stdlib.Mutex]: the critical section performs
       a durable JSONL append, which suspends the fiber. A raw pthread mutex
       held across that suspension is still held by the *same OS thread* when
       the scheduler runs another fiber on this domain, so the second fiber's
       lock attempt is a recursive acquisition and raises
       [Sys_error "Mutex.lock: Resource deadlock avoided"]. Measured on the
       live fleet: 218 occurrences on 2026-08-11 and 37 on 2026-08-10, most
       swallowed by worker handlers and one fatal in
       [Completion_authority_agent.process_task_once], which took the server
       down. The Eio gate makes a waiting fiber yield instead; the durable
       variant keeps cancellation out of the committed transaction. *)
    Cross_context_mutex.with_durable_lock t.mutation_mutex (fun () ->
      append_event_exn t (Register { id; started_at; registration });
      replace_entry_locked t entry)
  ;;

  let complete t ~id ~completion =
    Cross_context_mutex.with_durable_lock t.mutation_mutex (fun () ->
      let current = Atomic.get t.entries in
      if not (List.exists (fun entry -> String.equal entry.id id) current)
      then (
        Log.Misc.warn "%s: completion for unknown id %s" Payload.name id;
        `Unknown)
      else (
        let next =
          current
          |> List.map (fun entry ->
            if String.equal entry.id id
            then { entry with status = Completed completion }
            else entry)
          |> prune
        in
        match append_event_result t (Complete { id; completion }) with
        | Error detail -> `Persistence_failed detail
        | Ok () ->
          Atomic.set t.entries next;
          `Completed))
  ;;

  let list_entries t =
    Atomic.get t.entries
    |> List.sort (fun left right -> Float.compare right.started_at left.started_at)
  ;;

  let get t ~id =
    List.find_opt (fun entry -> String.equal entry.id id) (Atomic.get t.entries)
  ;;

  let parse_event_line ~path ~line_no line =
    match String.trim line with
    | "" -> Ok None
    | line ->
      (match
         try Ok (Yojson.Safe.from_string line) with
         | Yojson.Json_error message -> Error ("invalid JSON: " ^ message)
       with
       | Error _ as error -> error
       | Ok json -> Result.map Option.some (event_of_yojson json))
      |> Result.map_error (fun message ->
        Printf.sprintf "%s:%d: %s" path line_no message)
  ;;

  let apply_event entries = function
    | Register { id; started_at; registration } ->
      let entry = { id; started_at; registration; status = Running } in
      entry :: List.filter (fun existing -> not (String.equal existing.id id)) entries
    | Complete { id; completion } ->
      if List.exists (fun entry -> String.equal entry.id id) entries
      then
        List.map
          (fun entry ->
             if String.equal entry.id id
             then { entry with status = Completed completion }
             else entry)
          entries
      else (
        Log.Misc.warn "%s: replay skipped completion for unknown id %s" Payload.name id;
        entries)
  ;;

  let events_of_entry entry =
    let register =
      Register
        { id = entry.id
        ; started_at = entry.started_at
        ; registration = entry.registration
        }
    in
    match entry.status with
    | Running -> [ register ]
    | Completed completion -> [ register; Complete { id = entry.id; completion } ]
  ;;

  let settle_replayed_running entries =
    let running, completed = List.partition is_running entries in
    match running, Payload.replayed_running_completion with
    | [], _ -> completed
    | stale, None ->
      Log.Misc.warn
        "%s: dropped %d replayed running %s; %s"
        Payload.name
        (List.length stale)
        Payload.running_noun
        Payload.restart_reason;
      completed
    | stale, Some completion_of ->
      Log.Misc.warn
        "%s: settled %d replayed running %s as terminal; %s"
        Payload.name
        (List.length stale)
        Payload.running_noun
        Payload.restart_reason;
      List.map
           (fun entry ->
              { entry with
                status =
                  Completed
                    (completion_of
                       ~started_at:entry.started_at
                       entry.registration)
              })
           stale
      @ completed
  ;;

  let compact_replay_log path entries =
    let content =
      entries
      |> List.sort (fun left right -> Float.compare left.started_at right.started_at)
      |> List.concat_map events_of_entry
      |> List.map (fun event -> Yojson.Safe.to_string (event_to_yojson event) ^ "\n")
      |> String.concat ""
    in
    try
      match Fs_compat.save_file_atomic path content with
      | Ok () ->
        (* [save_file_atomic] replaces the inode. Drop any writer cached by an
           earlier in-process registry instance so the first post-replay append
           cannot continue writing to the unlinked pre-compaction file. *)
        Fs_compat.invalidate_cached_writer path
      | Error message ->
        Log.Misc.warn
          "%s: replay compaction failed for %s: %s"
          Payload.name
          path
          message
    with
    | exn ->
      Log.Misc.warn
        "%s: replay compaction raised for %s: %s"
        Payload.name
        path
        (Printexc.to_string exn)
  ;;

  let fold_replay_entries path =
    if not (Fs_compat.file_exists path)
    then [], [], false, 0
    else (
      try
        let (entries, malformed, line_no), boundary =
          Fs_compat.fold_appended_lines
            ~path
            ~from:0
            ~init:([], [], 1)
            ~f:(fun (entries, malformed, line_no) line ->
              match parse_event_line ~path ~line_no line with
              | Ok None -> entries, malformed, line_no + 1
              | Ok (Some event) ->
                let entries = apply_event entries event in
                entries, malformed, line_no + 1
              | Error message -> entries, message :: malformed, line_no + 1)
        in
        let reached_end =
          match Fs_compat.file_size path with
          | Some size when boundary < size ->
            Log.Misc.warn
              "%s: replay left unterminated tail in %s (%d/%d bytes consumed)"
              Payload.name
              path
              boundary
              size;
            false
          | Some _ -> true
          | None ->
            Log.Misc.warn "%s: replay stat failed after streaming %s" Payload.name path;
            false
        in
        let entries = settle_replayed_running entries |> prune in
        entries, List.rev malformed, reached_end, line_no - 1
      with
      | exn ->
        Log.Misc.warn
          "%s: replay stream failed for %s: %s"
          Payload.name
          path
          (Printexc.to_string exn);
        [], [], false, 0)
  ;;

  let replay path =
    let entries, malformed, reached_end, _lines_read = fold_replay_entries path in
    (match malformed with
     | [] -> ()
     | first :: _ as errors ->
       Log.Misc.warn
         "%s: skipped %d malformed replay line(s); first=%s"
         Payload.name
         (List.length errors)
         first);
    if reached_end && malformed = [] && Payload.completed_retention <> `All
    then compact_replay_log path entries;
    { entries = Atomic.make entries
    ; path = Some path
    ; mutation_mutex = Cross_context_mutex.create ()
    }
  ;;

  (* A row the current decoder refuses can never be read again: the field it
     carries was hard cut, and production holds no compatibility reader for it.
     [replay] will not compact while such a row is on disk, and the row only
     leaves through compaction — so the store stays poisoned and its retention
     bound stops applying to it.

     The cut breaks that by rewriting from the rows that do decode. It drops
     what the operator can see it is dropping, which is why it is a deliberate
     deployment step and not something [replay] does on its own. The
     unterminated-tail guard still holds: a partial read must not become a
     truncating rewrite. *)
  let cut_replay_log ~execute path =
    let entries, malformed, reached_end, lines_read = fold_replay_entries path in
    let rewritten = execute && reached_end in
    if rewritten then compact_replay_log path entries;
    { lines_read
    ; malformed_lines = List.length malformed
    ; retained_entries = List.length entries
    ; reached_end
    ; rewritten
    }
  ;;
end

module Global (Registry : sig
    type t

    val initial : t
  end) = struct
  type t = Registry.t
  type install_error = Already_installed

  type state =
    | Awaiting_install of t
    | Installed of t

  let state = Atomic.make (Awaiting_install Registry.initial)

  let current () =
    match Atomic.get state with
    | Awaiting_install registry | Installed registry -> registry
  ;;

  let rec install registry =
    let observed = Atomic.get state in
    match observed with
    | Installed _ -> Error Already_installed
    | Awaiting_install _ ->
      if Atomic.compare_and_set state observed (Installed registry)
      then Ok ()
      else install registry
  ;;
end
