(** RFC-0412 stage 2 consistency auditor. See the .mli for the contract; the
    comparison rules below encode the known dual-write skews (PLAN.md stage 2
    context) explicitly. *)

module Events = Keeper_chat_events
module Store = Keeper_chat_store
module Journal = Keeper_chat_event_log
module Delivery = Keeper_chat_delivery_identity

type mismatch_kind =
  | Terminal_outcome
  | Assistant_text
  | Tool_rows
  | Seq_gap
  | Missing_terminal_row
[@@deriving show, eq]

type verdict =
  | Match
  | Mismatch of mismatch_kind list
  | Journal_missing
  | Journal_truncated
  | Journal_corrupt of string
  | Store_unreadable of string
[@@deriving show, eq]

(* Bounded constructor name for metric labels: [show_verdict] embeds exception
   strings (paths, Unix_errors), which would make the label cardinality
   unbounded. The full detail stays in the log line. *)
let verdict_label = function
  | Match -> "match"
  | Mismatch _ -> "mismatch"
  | Journal_missing -> "journal_missing"
  | Journal_truncated -> "journal_truncated"
  | Journal_corrupt _ -> "journal_corrupt"
  | Store_unreadable _ -> "store_unreadable"
;;

let is_surface_post_row ~first_ts ~last_ts (row : Store.chat_message) =
  Store.Role.equal row.role Store.Role.Assistant
  && row.turn_ref = None
  && row.delivery_provenance = None
  && Float.compare row.ts first_ts >= 0
  && Float.compare row.ts last_ts <= 0
;;

let is_terminal_event = function
  | Events.Run_finished _ | Events.Event_error _ -> true
  | _ -> false
;;

let last_terminal_event entries =
  entries
  |> List.filter_map (fun (entry : Journal.journaled_event) ->
       if is_terminal_event entry.event then Some entry.event else None)
  |> List.rev
  |> function
  | event :: _ -> Some event
  | [] -> None
;;

let last_reply_details entries =
  entries
  |> List.filter_map (fun (entry : Journal.journaled_event) ->
       match entry.event with
       | Events.Reply_details details -> Some details
       | _ -> None)
  |> List.rev
  |> function
  | details :: _ -> Some details
  | [] -> None
;;

(* Rule 1: seqs must be exactly 0..n-1 in journal order. *)
let seqs_are_contiguous entries =
  let rec check expected = function
    | [] -> true
    | (entry : Journal.journaled_event) :: rest ->
      entry.seq = expected && check (expected + 1) rest
  in
  check 0 entries
;;

let lifecycle_terminal (row : Store.chat_message) =
  match row.stream_lifecycle with
  | Some events ->
    (match List.rev events with
     | last :: _ -> Some last
     | [] -> None)
  | None -> None
;;

let lifecycle_ends_run_error row =
  match lifecycle_terminal row with
  | Some Store.Run_error -> true
  | _ -> false
;;

let is_terminal_assistant_slot (row : Store.chat_message) =
  match row.delivery_provenance with
  | Some { Delivery.transcript_slot = Delivery.Terminal_assistant; _ } -> true
  | _ -> false
;;

let is_assistant_row (row : Store.chat_message) =
  Store.Role.equal row.role Store.Role.Assistant
;;

(* The store half of a turn: the exact [Terminal_assistant] slot when the
   append-once path persisted it, otherwise the last joined assistant row
   (utterance or typed transport-failure marker). *)
let terminal_assistant_row rows =
  let assistant_rows = List.filter is_assistant_row rows in
  match List.rev (List.filter is_terminal_assistant_slot assistant_rows) with
  | row :: _ -> Some row
  | [] ->
    (match List.rev assistant_rows with
     | row :: _ -> Some row
     | [] -> None)
;;

(* Rule 2: the journal's terminal event and the terminal row's durable
   lifecycle/kind must agree on how the turn ended. *)
let terminal_outcome_mismatch ~terminal_event rows =
  match terminal_event with
  | Events.Run_finished _ ->
    (match terminal_assistant_row rows with
     | Some row ->
       Store.Row_kind.equal row.kind Store.Row_kind.Transport_failure
       || lifecycle_ends_run_error row
     (* No assistant row: visible-reply absence is the Assistant_text check's
        call; a tool-calls-only continuation legitimately persists none. *)
     | None -> false)
  | Events.Event_error _ ->
    let failure_recorded =
      List.exists
        (fun (row : Store.chat_message) ->
           is_assistant_row row
           && (Store.Row_kind.equal row.kind Store.Row_kind.Transport_failure
               || lifecycle_ends_run_error row))
        rows
    in
    not failure_recorded
  | _ -> false
;;

(* Rule 3: the persisted terminal text is [Reply_details.reply]; both sides
   are already the redacted view. An empty reply with no assistant row is the
   tool-calls-only / no-visible-reply shape, not a divergence. *)
let assistant_text_mismatch ~reply_details rows =
  match reply_details with
  | None -> false
  | Some (details : Events.reply_details) ->
    (match terminal_assistant_row rows with
     | Some row -> not (String.equal row.content details.reply)
     | None -> String.equal (String.trim details.reply) "" |> not)
;;

(* Rule 4: the sorted execution_id multisets of Tool_result_ready events and
   joined tool rows must be equal. A multiset, not subset-both-ways: a
   duplicated execution_id (the dual-write bug class this auditor exists to
   catch) must not pass silently. *)
let tool_rows_mismatch entries rows =
  let sorted_execution_ids ids =
    ids |> List.map Ids.Execution_id.to_string |> List.sort String.compare
  in
  let journal_ids =
    List.filter_map
      (fun (entry : Journal.journaled_event) ->
         match entry.event with
         | Events.Tool_result_ready { execution_id; _ } -> Some execution_id
         | _ -> None)
      entries
    |> sorted_execution_ids
  in
  let store_ids =
    List.filter_map (fun (row : Store.chat_message) -> row.execution_id) rows
    |> sorted_execution_ids
  in
  not (List.equal String.equal journal_ids store_ids)
;;

let compare entries rows =
  match entries with
  | [] -> Journal_truncated
  | _ ->
    let first_ts = (List.hd entries).Journal.ts in
    let last_ts = (List.hd (List.rev entries)).Journal.ts in
    let joined =
      List.filter
        (fun row -> not (is_surface_post_row ~first_ts ~last_ts row))
        rows
    in
    (match last_terminal_event entries with
     | None -> Journal_truncated
     | Some terminal_event ->
       let mismatches =
         (if seqs_are_contiguous entries then [] else [ Seq_gap ])
         @
         match joined with
         | [] -> [ Missing_terminal_row ]
         | _ ->
           (if terminal_outcome_mismatch ~terminal_event joined
            then [ Terminal_outcome ]
            else [])
           @ (if assistant_text_mismatch
                     ~reply_details:(last_reply_details entries)
                     joined
              then [ Assistant_text ]
              else [])
           @ if tool_rows_mismatch entries joined then [ Tool_rows ] else []
       in
       (match mismatches with
        | [] -> Match
        | _ :: _ -> Mismatch mismatches))
;;

(** {1 IO shell} *)

(* Read-only: [read_journal_path] creates nothing on disk, unlike
   [Journal.open_journal] whose mkdir would mint junk directories for ids
   whose sanitized path does not exist. *)
let read_journal_entries path =
  try `Entries (Journal.read_journal_path path) with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Sys_error _ -> `Missing
  | Invalid_argument detail -> `Corrupt detail
  | exn -> `Corrupt (Printexc.to_string exn)
;;

let operation_delivery_key operation_id =
  match Delivery.Request_id.of_string operation_id with
  | Ok request_id -> Some (Delivery.Operation request_id)
  | Error _ -> None
;;

let turn_ref_matches turn_ref (row : Store.chat_message) =
  match turn_ref, row.turn_ref with
  | Some turn_ref, Some row_ref -> Ids.Turn_ref.equal turn_ref row_ref
  | _ -> false
;;

let delivery_key_matches delivery_key (row : Store.chat_message) =
  match delivery_key, row.delivery_provenance with
  | Some delivery_key, Some provenance ->
    Delivery.delivery_key_equal provenance.delivery_key delivery_key
  | _ -> false
;;

let dedupe_by_id rows =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | (row : Store.chat_message) :: rest ->
      if List.mem row.id seen then loop seen acc rest else loop (row.id :: seen) (row :: acc) rest
  in
  loop [] [] rows
;;

(* Join the store rows that belong to this operation: the transcript join on
   [turn_ref] (user + assistant), any row carrying the operation's delivery
   key or [turn_ref] directly (tool rows), and the in-window key-less
   assistant rows so [compare] can apply the surface-post exclusion on the
   exact same window. *)
let join_rows ~operation_id entries all =
  let turn_ref =
    Option.map
      (fun (details : Events.reply_details) -> details.turn_ref)
      (last_reply_details entries)
  in
  let delivery_key = operation_delivery_key operation_id in
  let transcript_rows =
    match turn_ref with
    | Some turn_ref ->
      let transcript = Store.transcript_of_messages all ~turn_ref in
      transcript.user @ transcript.assistant
    | None -> []
  in
  let key_or_ref_rows =
    List.filter
      (fun row -> turn_ref_matches turn_ref row || delivery_key_matches delivery_key row)
      all
  in
  let window_rows =
    match entries with
    | [] -> []
    | _ ->
      let first_ts = (List.hd entries).Journal.ts in
      let last_ts = (List.hd (List.rev entries)).Journal.ts in
      List.filter (fun row -> is_surface_post_row ~first_ts ~last_ts row) all
  in
  dedupe_by_id (transcript_rows @ key_or_ref_rows @ window_rows)
;;

(* Shared core: journal entries already read, store rows already loaded. The
   sweep calls this once per journal file against a per-keeper row list loaded
   once per pass. *)
let audit_entries ~operation_id ~entries ~rows =
  compare entries (join_rows ~operation_id entries rows)
;;

(* [Store.load_all] converts a read failure into [[]] after reporting it, so
   an empty load is ambiguous with a genuinely empty store. The stat heuristic
   separates them: a store file that exists with content yet loaded zero rows
   is unreadable for audit purposes (read error, or every line unparseable),
   not missing. *)
let store_unreadable_detail ~base_dir ~keeper_name =
  let path = Store.chat_path ~base_dir ~keeper_name in
  try
    let stats = Unix.stat path in
    if stats.st_size > 0
    then
      Some
        (Printf.sprintf
           "store file %s holds %d bytes but load_all returned zero rows"
           path
           stats.st_size)
    else None
  with
  | Unix.Unix_error _ -> None
;;

(* A terminal-event journal against an empty store load reports
   [Store_unreadable] when the store file is visibly non-empty; without a
   terminal event the [Journal_truncated] verdict stands on its own. *)
let audit_loaded ~base_dir ~keeper_name ~operation_id ~rows entries =
  match last_terminal_event entries, rows with
  | Some _, [] ->
    (match store_unreadable_detail ~base_dir ~keeper_name with
     | Some detail -> Store_unreadable detail
     | None -> audit_entries ~operation_id ~entries ~rows)
  | _ -> audit_entries ~operation_id ~entries ~rows
;;

let audit_operation ~base_dir ~keeper_name ~operation_id =
  let path = Journal.journal_path ~base_dir ~keeper_name ~operation_id in
  match read_journal_entries path with
  | `Missing -> Journal_missing
  | `Corrupt detail -> Journal_corrupt detail
  | `Entries entries ->
    let rows = Store.load_all ~base_dir ~keeper_name in
    audit_loaded ~base_dir ~keeper_name ~operation_id ~rows entries
;;

let stem_is_canonical stem =
  String.equal (Workspace_utils_backend_setup.sanitize_namespace_segment stem) stem
;;

let sweep ~base_dir ~window_sec ?(grace_sec = 600.) () =
  let root =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path:base_dir)
      "keeper_chat_events"
  in
  if not (Sys.file_exists root)
  then []
  else begin
    let now = Unix.gettimeofday () in
    let keeper_names =
      try
        Sys.readdir root
        |> Array.to_list
        |> List.filter (fun name ->
             try Sys.is_directory (Filename.concat root name) with
             | Sys_error _ -> false)
      with
      | Sys_error _ -> []
    in
    List.concat_map
      (fun keeper_name ->
         let dir = Filename.concat root keeper_name in
         let files =
           try Array.to_list (Sys.readdir dir) with
           | Sys_error _ -> []
         in
         (* One store load per keeper per pass, and only when that keeper has
            an auditable journal; auditing each file against its own load was
            O(files x store size). *)
         let rows = lazy (Store.load_all ~base_dir ~keeper_name) in
         List.filter_map
           (fun file ->
              if not (Filename.check_suffix file ".jsonl")
              then None
              else begin
                let operation_id = Filename.remove_extension file in
                (* [sanitize_namespace_segment] is not idempotent for
                   non-canonical stems (a second pass appends another digest),
                   so the filename stem cannot be re-derived into a path.
                   Non-canonical ids are outside the audit. *)
                if not (stem_is_canonical operation_id)
                then None
                else begin
                  let path = Filename.concat dir file in
                  let auditable =
                    try
                      let stats = Unix.stat path in
                      let age = now -. stats.st_mtime in
                      grace_sec <= age && age <= window_sec
                    with
                    | Unix.Unix_error _ -> false
                  in
                  if not auditable
                  then None
                  else begin
                    try
                      match read_journal_entries path with
                      | `Missing ->
                        (* Vanished between readdir and read (the retention
                           sweep raced us): never report [Journal_missing] for
                           a file that was visible on disk. *)
                        None
                      | `Corrupt detail ->
                        Some (keeper_name, operation_id, Journal_corrupt detail)
                      | `Entries entries ->
                        let verdict =
                          audit_loaded
                            ~base_dir
                            ~keeper_name
                            ~operation_id
                            ~rows:(Lazy.force rows)
                            entries
                        in
                        Some (keeper_name, operation_id, verdict)
                    with
                    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
                    | exn ->
                      Some
                        ( keeper_name
                        , operation_id
                        , Journal_corrupt (Printexc.to_string exn) )
                  end
                end
              end)
           files)
      keeper_names
  end
;;
