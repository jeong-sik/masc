(** Keeper_coordination — Room presence, compaction policy, checkpoint persistence, and error logging for keeper agents. MASC coordination domain. *)

open Keeper_types
open Keeper_memory [@@warning "-33"]

(** Log a keeper error with [UNEXPECTED] tag for unrecognized exceptions.
    Known IO/parse exceptions get a plain log; anything else is tagged for triage.
    No re-raise — side-effect-only patterns must not change control flow. *)
let log_keeper_exn ~label exn =
  let tag = match exn with
    | Sys_error _ | Failure _ | Not_found
    | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ""
    | _ -> "[UNEXPECTED] "
  in
  Log.Keeper.info "%s%s: %s" tag label (Printexc.to_string exn)

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
  let latest_ckpt =
    try Context_manager.load_latest_checkpoint session
    with ex ->
      Log.Keeper.error "keeper:%s checkpoint load failed: %s"
        trace_id
        (Printexc.to_string ex);
      None
  in
  match latest_ckpt with
  | None -> (session, None)
  | Some ckpt ->
      (try
         let ctx =
           Context_manager.restore_checkpoint ckpt
             ~max_tokens:primary_model_max_tokens
         in
         (session, Some ctx)
       with ex ->
         Log.Keeper.error "keeper:%s checkpoint restore failed: %s"
           trace_id
           (Printexc.to_string ex);
         (session, None))

let save_checkpoint session (ctx : Context_manager.working_context) ~generation =
  let ckpt = Context_manager.create_checkpoint ctx ~generation in
  Context_manager.save_checkpoint session ckpt;
  ckpt

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  (meta.compaction_ratio_gate, meta.compaction_message_gate, meta.compaction_token_gate)

let compact_if_needed
    ~(meta : keeper_meta)
    ~(now_ts : float)
    (ctx : Context_manager.working_context) :
    Context_manager.working_context * string option * string =
  let ratio = Context_manager.context_ratio ctx in
  let message_count = List.length ctx.messages in
  let token_count = ctx.token_count in
  let ratio_gate, message_gate, token_gate = compaction_policy_of_keeper meta in
  let cooldown = Float.of_int meta.continuity_compaction_cooldown_sec in
  let last_reflection_ts = max meta.last_continuity_update_ts meta.last_proactive_ts in
  let reflection_ready =
    last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown
  in
  let hold_s =
    if cooldown <= 0.0 then 0.0
    else if last_reflection_ts <= 0.0 then
      Float.of_int meta.continuity_compaction_cooldown_sec
    else
      max
        0.0
        (Float.of_int meta.continuity_compaction_cooldown_sec
       -. (now_ts -. last_reflection_ts))
  in
  let trigger_reason =
    if not reflection_ready then
      Some
        (Printf.sprintf
           "skipped:continuity_reflection(%0.0fs<%ds)"
           hold_s meta.continuity_compaction_cooldown_sec)
    else if ratio >= ratio_gate then
      Some (Printf.sprintf "ratio(%.4f>=%.4f)" ratio ratio_gate)
    else if message_gate > 0 && message_count >= message_gate then
      Some (Printf.sprintf "messages(%d>=%d)" message_count message_gate)
    else if token_gate > 0 && token_count >= token_gate then
      Some (Printf.sprintf "tokens(%d>=%d)" token_count token_gate)
    else None
  in
  match trigger_reason with
  | None -> (ctx, None, "blocked:below_thresholds")
  | Some reason ->
      if String.starts_with ~prefix:"skipped:" reason then
        (ctx, None, reason)
      else
        let compacted_ctx =
          Context_manager.compact ctx
            Context_manager.[
              PruneToolOutputs;
              MergeContiguous;
              DropLowImportance;
              SummarizeOld;
            ]
        in
        (compacted_ctx, Some reason, "applied:" ^ reason)

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.int 99999 in
  Printf.sprintf "trace-%d-%05d" ts rnd

let keeper_board_write_tool_names =
  [ "keeper_board_post"; "keeper_board_comment"; "keeper_board_vote" ]

let keeper_write_done tool_names =
  List.exists (fun name -> List.mem name keeper_board_write_tool_names) tool_names

let keeper_action_kind_of_tool_names tool_names =
  if List.mem "keeper_board_post" tool_names then "post"
  else if List.mem "keeper_board_comment" tool_names then "comment"
  else if List.mem "keeper_board_vote" tool_names then "vote"
  else "none"

let effective_model_labels_for_turn
    (m : keeper_meta)
    ~(inline_models : string list) : string list =
  if inline_models <> [] then
    inline_models
  else
    match Keeper_exec_status.active_model_of_meta m with
    | "" ->
        let pool = dedupe_keep_order (m.allowed_models @ m.models) in
        if pool = [] then m.models else pool
    | model -> [ model ]

let room_cursor_for meta room_id =
  meta.last_seen_seq_by_room
  |> List.find_map (fun (rid, seq) -> if rid = room_id then Some seq else None)
  |> Option.value ~default:0

let set_room_cursor meta room_id seq =
  let kept =
    meta.last_seen_seq_by_room
    |> List.filter (fun (rid, _) -> rid <> room_id)
  in
  {
    meta with
    last_seen_seq_by_room = dedupe_keep_order ((room_id, seq) :: kept);
  }

let room_ids_for_meta config (meta : keeper_meta) : string list =
  match Keeper_contract.room_scope_of_string meta.room_scope with
  | Keeper_contract.All ->
      let open Yojson.Safe.Util in
      let listed =
        match Room.rooms_list config |> member "rooms" with
        | `List rooms ->
            rooms
            |> List.filter_map (fun room ->
                   match room |> member "id" with
                   | `String room_id when validate_name room_id -> Some room_id
                   | _ -> None)
        | _ -> []
      in
      let current = Room.current_room_id config in
      dedupe_keep_order (current :: listed)
  | Keeper_contract.Current -> [ Room.current_room_id config ]

let ensure_keeper_room_presence config (meta : keeper_meta) : keeper_meta =
  let room_ids = room_ids_for_meta config meta in
  let successful_rooms =
    List.fold_left
      (fun acc room_id ->
        try
          if
            not
              (Room.is_agent_joined_in_room config ~room_id
                 ~agent_name:meta.agent_name)
          then
            ignore
              (Room.join_in_room config ~room_id ~agent_name:meta.agent_name
                 ~capabilities:[ "keeper" ] ());
          ignore
            (Room.heartbeat_in_room config ~room_id ~agent_name:meta.agent_name);
          room_id :: acc
        with exn ->
          log_keeper_exn ~label:(Printf.sprintf "room presence sync failed for %s in %s" meta.name room_id) exn;
          acc)
      [] room_ids
  in
  { meta with joined_room_ids = List.rev successful_rooms }
