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
[@@deriving show, eq]

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

(* Rule 4: bijection on execution_id between Tool_result_ready events and
   joined tool rows. *)
let tool_rows_mismatch entries rows =
  let journal_ids =
    List.filter_map
      (fun (entry : Journal.journaled_event) ->
         match entry.event with
         | Events.Tool_result_ready { execution_id; _ } -> Some execution_id
         | _ -> None)
      entries
  in
  let store_ids =
    List.filter_map (fun (row : Store.chat_message) -> row.execution_id) rows
  in
  let missing_from_store =
    List.exists
      (fun id ->
         not (List.exists (fun row_id -> Ids.Execution_id.equal row_id id) store_ids))
      journal_ids
  in
  let missing_from_journal =
    List.exists
      (fun row_id ->
         not (List.exists (fun id -> Ids.Execution_id.equal row_id id) journal_ids))
      store_ids
  in
  missing_from_store || missing_from_journal
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

let read_journal_entries journal =
  try `Entries (Journal.read_journal journal) with
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

let audit_operation ~base_dir ~keeper_name ~operation_id =
  let journal = Journal.open_journal ~base_dir ~keeper_name ~operation_id () in
  match read_journal_entries journal with
  | `Missing -> Journal_missing
  | `Corrupt detail -> Journal_corrupt detail
  | `Entries entries ->
    let all = Store.load_all ~base_dir ~keeper_name in
    compare entries (join_rows ~operation_id entries all)
;;

let sweep ~base_dir ~window_sec () =
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
         List.filter_map
           (fun file ->
              if not (Filename.check_suffix file ".jsonl")
              then None
              else begin
                let path = Filename.concat dir file in
                let fresh =
                  try
                    let stats = Unix.stat path in
                    now -. stats.st_mtime <= window_sec
                  with
                  | Unix.Unix_error _ -> false
                in
                if not fresh
                then None
                else begin
                  let operation_id = Filename.remove_extension file in
                  let verdict =
                    try audit_operation ~base_dir ~keeper_name ~operation_id with
                    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
                    | exn -> Journal_corrupt (Printexc.to_string exn)
                  in
                  Some (keeper_name, operation_id, verdict)
                end
              end)
           files)
      keeper_names
  end
;;
