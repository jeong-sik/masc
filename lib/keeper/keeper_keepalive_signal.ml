(* keeper_keepalive_signal — gRPC client refs, FSM guard identity helpers,
   interruptible sleep, wakeup dispatch, board-reactive wakeup filtering,
   stage_timing type, event dispatch helpers.

   Extracted from keeper_keepalive.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution

module Board_wake = Keeper_world_observation_board_signal

type grpc_heartbeat_starter_fn = {
  f : 'a. ctx:'a context -> m:keeper_meta -> stop:bool Atomic.t -> (unit -> unit) option;
}

let grpc_heartbeat_starter_fn : grpc_heartbeat_starter_fn Atomic.t =
  Atomic.make { f = (fun ~ctx:_ ~m:_ ~stop:_ -> None) }

let register_grpc_heartbeat_starter (f : grpc_heartbeat_starter_fn) =
  Atomic.set grpc_heartbeat_starter_fn f
;;

let grpc_heartbeat_starter ~ctx ~m ~stop =
  (Atomic.get grpc_heartbeat_starter_fn).f ~ctx ~m ~stop

let record_wake_payload_callback
    : (keeper_name:string ->
       trace_id:string ->
       turn_index:int ->
       model_id:string ->
       context_window:int ->
       approx_body_bytes:int ->
       system_prompt_bytes:int ->
       tool_defs_bytes:int ->
       messages_bytes:int ->
       message_count:int ->
       role_counts:(string * int) list ->
       tool_count:int ->
       has_compact_happened:bool ->
       unit)
      Atomic.t
  =
  Atomic.make
    (fun ~keeper_name:_
      ~trace_id:_
      ~turn_index:_
      ~model_id:_
      ~context_window:_
      ~approx_body_bytes:_
      ~system_prompt_bytes:_
      ~tool_defs_bytes:_
      ~messages_bytes:_
      ~message_count:_
      ~role_counts:_
      ~tool_count:_
      ~has_compact_happened:_ -> ())

let record_wake_payload
    ~keeper_name
    ~trace_id
    ~turn_index
    ~model_id
    ~context_window
    ~approx_body_bytes
    ~system_prompt_bytes
    ~tool_defs_bytes
    ~messages_bytes
    ~message_count
    ~role_counts
    ~tool_count
    ~has_compact_happened
  =
  (Atomic.get record_wake_payload_callback)
    ~keeper_name
    ~trace_id
    ~turn_index
    ~model_id
    ~context_window
    ~approx_body_bytes
    ~system_prompt_bytes
    ~tool_defs_bytes
    ~messages_bytes
    ~message_count
    ~role_counts
    ~tool_count
    ~has_compact_happened
;;

let register_record_wake_payload f = Atomic.set record_wake_payload_callback f

let record_tool_skipped_callback
    : (keeper_name:string -> tool_name:string -> reason_code:string -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~tool_name:_ ~reason_code:_ -> ())

let record_tool_skipped ~keeper_name ~tool_name ~reason_code =
  (Atomic.get record_tool_skipped_callback) ~keeper_name ~tool_name ~reason_code
;;

let register_record_tool_skipped f = Atomic.set record_tool_skipped_callback f

let record_execute_output_callback
    : (keeper_name:string ->
       task_id:string option ->
       stdout:string ->
       stderr:string ->
       status:Yojson.Safe.t ->
       streamed:bool ->
       unit)
      Atomic.t
  =
  Atomic.make
    (fun ~keeper_name:_ ~task_id:_ ~stdout:_ ~stderr:_ ~status:_ ~streamed:_ -> ())

let record_execute_output ~keeper_name ~task_id ~stdout ~stderr ~status ~streamed =
  (Atomic.get record_execute_output_callback)
    ~keeper_name
    ~task_id
    ~stdout
    ~stderr
    ~status
    ~streamed
;;

let register_record_execute_output f = Atomic.set record_execute_output_callback f

let record_execute_stream_chunk_callback
    : (keeper_name:string -> stream:[ `Stdout | `Stderr ] -> string -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~stream:_ _chunk -> ())

let record_execute_stream_chunk ~keeper_name ~stream chunk =
  (Atomic.get record_execute_stream_chunk_callback) ~keeper_name ~stream chunk
;;

let register_record_execute_stream_chunk f =
  Atomic.set record_execute_stream_chunk_callback f

let record_execute_stream_start_callback
    : (keeper_name:string -> task_id:string option -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~task_id:_ -> ())

let record_execute_stream_start ~keeper_name ~task_id =
  (Atomic.get record_execute_stream_start_callback) ~keeper_name ~task_id
;;

let register_record_execute_stream_start f =
  Atomic.set record_execute_stream_start_callback f

let record_execute_stream_end_callback
    : (keeper_name:string -> task_id:string option -> status:Yojson.Safe.t -> unit) Atomic.t
  =
  Atomic.make (fun ~keeper_name:_ ~task_id:_ ~status:_ -> ())

let record_execute_stream_end ~keeper_name ~task_id ~status =
  (Atomic.get record_execute_stream_end_callback) ~keeper_name ~task_id ~status
;;

let register_record_execute_stream_end f = Atomic.set record_execute_stream_end_callback f

(* Skip log throttle removed with manual_reconcile blocker — no more
   sticky reconcile state means no flood of "reconcile pending" skip logs. *)

let format_since_last_scheduled_autonomous = function
  | Some s when s = max_int -> "never"
  | Some s -> string_of_int s
  | None -> "-"

(* ── KeeperHeartbeat.tla spec-action runtime guards (Cycle 43) ────────

   Identity helpers carrying [@@fsm_guard] payloads that mirror the
   honest actions of [specs/keeper-state-machine/KeeperHeartbeat.tla].
   Each helper is wrapped at the call site by
   [Keeper_fsm_guard_runtime.wrap_unit], so an [Assert_failure] from a
   PPX-injected guard increments the Otel_metric_store violation counter and
   re-raises. The bug-action [MissedWakeup] is
   intentionally NOT instrumented — it is the failure mode these guards
   are designed to detect, not to enforce. *)

(* Heartbeat turn lifecycle flag, mirroring KeeperHeartbeat.tla's
   [turn_state] in the {"idle", "running"} alphabet. Read inside
   identity helpers; written by the caller around [run_heartbeat_loop]
   and the dispatch sites. Single-fiber by construction — only the
   keeper's own heartbeat loop touches its [turn_running] ref. *)
let pre_turn_complete_heartbeat ~(turn_running : bool ref) = ignore turn_running
  [@@fsm_guard "!turn_running = true"]

let post_turn_complete_heartbeat ~(turn_running : bool ref) = ignore turn_running
  [@@fsm_guard "!turn_running = false"]

(* WakeupSignal: external code sets the wakeup atomic to TRUE. Spec
   says the post-condition is [wakeup_signaled = TRUE]. The OCaml
   [Atomic.set] is idempotent so the assert is trivially true on the
   honest path; the guard catches a regression where someone replaces
   [Atomic.set ... true] with [Atomic.set ... false] or forgets the
   set entirely. *)
let post_wakeup_signal ~(wakeup : bool Atomic.t) = ignore wakeup
  [@@fsm_guard "Atomic.get wakeup = true"]

(* SubmitTask (KeeperTaskAcquisition.tla, Cycle 44): an external
   producer (operator directive in this case) attaches a task_id to the
   keeper's [current_task_id]. The post-action invariant is that the
   meta carries the assigned id after [persist_directive_meta_update]
   returns. The honest path is trivially true; the guard catches a
   regression where someone updates [persist_directive_meta_update] to
   skip the [current_task_id] field or persist a different id. *)
let post_submit_task ~(meta : keeper_meta) ~(task_id : Keeper_id.Task_id.t) =
  ignore meta; ignore task_id
  [@@fsm_guard "meta.current_task_id = Some task_id"]

(* HeartbeatTick: the [compare_and_set wakeup true false] in
   [interruptible_sleep] succeeded — wakeup transitioned TRUE -> FALSE
   and the sleep returned so the loop can dispatch. Spec post-condition
   is [wakeup_signaled = FALSE]. False-positive risk: a producer that
   re-sets the atomic to TRUE between the CAS and this read would make
   the guard fire. The [interruptible_sleep] body is single-fiber and
   the only producer is external, so the window is one tick and the
   counter signal is operationally meaningful — a non-zero count means
   producers are racing the consumer, which is itself a bug class. *)
let post_heartbeat_tick ~(wakeup : bool Atomic.t) = ignore wakeup
  [@@fsm_guard "Atomic.get wakeup = false"]

type sleep_outcome =
  | Stopped
  | Woken
  | Timeout

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
let interruptible_sleep ~clock ~stop ~wakeup duration : sleep_outcome =
  let chunk_sec = Env_config.KeeperKeepalive.sleep_chunk_sec in
  let rec wait remaining =
    if Atomic.get stop
    then Stopped
    else if (* Spec: KeeperHeartbeat.tla HeartbeatTick action — wakeup is
              consumed (TRUE -> FALSE) and the caller proceeds to dispatch.
              Returning [Woken] lets [run_smart_heartbeat_gate] honour
              the spec's [turn_state' = "running"] postcondition; without
              the discriminator the [Skip_idle] branch would consume the
              CAS and then skip the cycle (the [MissedWakeup] bug-action). *)
            Atomic.compare_and_set wakeup true false
    then (
      (* Cycle 43: post-action guard mirrors the spec's [wakeup_signaled =
         FALSE] postcondition. The [@@fsm_guard] PPX routes the
         assertion through [wrap_unit ~stage:"guard"] automatically. *)
      post_heartbeat_tick ~wakeup;
      Woken)
    else if remaining <= 0.0
    then Timeout
    else (
      let chunk = Float.min chunk_sec remaining in
      Eio.Time.sleep clock chunk;
      wait (remaining -. chunk))
  in
  wait duration
;;

(** Wake up a specific keeper immediately, causing it to skip the rest of
    its sleep and run the next heartbeat cycle. Used by broadcast notification
    when a @mention targets a running keeper.

    When [?stimulus] is provided, the stimulus is appended to the keeper's
    Event Layer queue before the wakeup flag flips. Result-aware producers use
    [enqueue_stimulus_and_wakeup_hint_result] so a failed durable enqueue does
    not become a false wake success. This is RFC-0020 Rule 1 (enqueue is
    independent of policy) + the data-channel half of the layer split —
    [fiber_wakeup] remains the hint signal, the queue is the authoritative
    payload. *)
let enqueue_stimulus_and_wakeup_hint_result ~base_path ~keeper_name stimulus =
  match Keeper_registry_event_queue.enqueue_result ~base_path keeper_name stimulus with
  | Error _ as error -> error
  | Ok delivery ->
    Keeper_registry.wakeup ~base_path keeper_name;
    Ok delivery
;;

let enqueue_stimulus_and_wakeup_hint ~base_path ~keeper_name stimulus =
  match enqueue_stimulus_and_wakeup_hint_result ~base_path ~keeper_name stimulus with
  | Ok _ -> ()
  | Error msg ->
    Log.Keeper.warn
      "event-layer wake hint suppressed after durable enqueue failure keeper=%s: %s"
      keeper_name
      msg
;;

let wakeup_keeper ?base_path ?stimulus name =
  Keeper_registry.all ?base_path ()
  |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
    if String.equal entry.name name
    then
      if entry.phase = Keeper_state_machine.Running
      then begin
        match stimulus with
        | Some s ->
          enqueue_stimulus_and_wakeup_hint
            ~base_path:entry.base_path
            ~keeper_name:name
            s
        | None -> Keeper_registry.wakeup ~base_path:entry.base_path name
      end
      else
        (* 비-Running 키퍼로의 stimulus는 배달하지 않는다(보수적 기본값 유지 —
           Paused를 강제 재개하지 않음). 단, 유실을 조용히 두지 않는다: payload가
           있는 wake가 여기서 떨어지면 발신자(예: fusion sink)는 배달됐다고 믿는데
           수신자는 아무것도 못 받는다. durable 표면(chat/board)이 사유를 따로
           나르지 않던 2026-07-01 fusion 사고에서 이 무로그 drop이 두 run의 결과를
           완전히 증발시켰다(fus-c9a63064/fus-46fce8a8 — 로그에 delivery 라인
           부재). *)
        Log.Keeper.info ~keeper_name:name
          "wakeup_keeper: dropped (keeper not Running, phase=%s) stimulus=%s"
          (Keeper_state_machine.phase_to_string entry.phase)
          (match stimulus with
           | None -> "none"
           | Some s -> Keeper_event_queue.payload_kind_label s.Keeper_event_queue.payload))
;;

(** Wake up all running keepers — used when a broadcast mentions @@all
    or when a system-wide event requires immediate attention.
    [None] preserves the legacy global wakeup behavior. *)
let wakeup_all_keepers ?base_path () =
  match base_path with
  | None -> Keeper_registry.wakeup_all ()
  | Some expected ->
      Keeper_registry.all ~base_path:expected ()
      |> List.iter (fun (entry : Keeper_registry.registry_entry) ->
           if entry.phase = Keeper_state_machine.Running then
             Keeper_registry.wakeup ~base_path:entry.base_path entry.name)

(* ── Board-reactive policy constants ── *)

let board_reactive_debounce_sec = 60.0

let board_reactive_wakeup_max =
  Keeper_config.int_of_env_default
    "MASC_KEEPER_BOARD_WAKEUP_MAX"
    ~default:4
    ~min_v:1
    ~max_v:64
;;

let take = List.take

(* RFC-0239 R4: collapse runs of whitespace and lowercase so trivial spacing
   or case differences do not split a re-post into a fresh dedup key. *)
let normalize_for_fingerprint s =
  let b = Buffer.create (String.length s) in
  let prev_space = ref true in
  String.iter
    (fun c ->
      match Char.lowercase_ascii c with
      | ' ' | '\t' | '\n' | '\r' ->
        if not !prev_space then Buffer.add_char b ' ';
        prev_space := true
      | c ->
        Buffer.add_char b c;
        prev_space := false)
    s;
  let r = Buffer.contents b in
  let n = String.length r in
  if n > 0 && r.[n - 1] = ' ' then String.sub r 0 (n - 1) else r
;;

(* RFC-0239 R4: a keeper that re-posts the same conclusion mints a fresh
   post_id every cycle, so the prior post_id-keyed debounce never matched
   across re-posts. Key the debounce on a fingerprint of normalized
   (author,title,content) so identical re-posts collapse into one peer wake per
   window. Empty title+content falls back to post_id so content-less signals
   keep their original per-post behaviour. *)
let board_wakeup_dedup_key ~post_id ~author ~title ~content =
  if String.trim (title ^ content) = "" then post_id
  else (
    let normalized = normalize_for_fingerprint (title ^ "\n" ^ content) in
    "cfp:" ^ Digest.to_hex (Digest.string (author ^ "\x00" ^ normalized)))
;;

let board_signal_wakeup_dedup_key (signal : Board_dispatch.board_signal) =
  let base =
    board_wakeup_dedup_key
      ~post_id:signal.post_id
      ~author:signal.author
      ~title:signal.title
      ~content:signal.content
  in
  match signal.kind with
  | Board_dispatch.Board_post_created | Board_dispatch.Board_comment_added -> base
  | Board_dispatch.Board_reaction_changed reaction ->
    let reaction_key =
      String.concat
        "\x00"
        [ Board.reaction_target_type_to_string reaction.target_type
        ; reaction.target_id
        ; reaction.user_id
        ; reaction.emoji
        ; string_of_bool reaction.reacted
        ]
    in
    base ^ ":reaction:" ^ Digest.to_hex (Digest.string reaction_key)
;;

let board_reactive_wakeup_allowed
      ~base_path
      ~keeper_name
      ~(signal : Board_dispatch.board_signal)
  =
  Keeper_registry.board_wakeup_allowed
    ~base_path
    keeper_name
    ~dedup_key:(board_signal_wakeup_dedup_key signal)
    ~debounce_sec:board_reactive_debounce_sec
;;

(* ── Connector-reactive policy (RFC-connector-ambient-attention-wake P4) ── *)

let connector_reactive_debounce_sec = 60.0

(* Throttle ambient connector wakes with the SAME proven primitive as
   board-reactive: the RFC-0246 tombstone gate (a latched no-progress keeper is
   not re-woken) plus a per-key debounce. Keyed per channel, so a chatty channel
   wakes the keeper at most once per window; the keeper then sees every
   accumulated message in its chat history (RFC-0226) and decides whether to
   reply. The dedup_key is namespaced ("connector-ambient:") so it never collides
   with board dedup keys in the shared per-keeper wakeup map. A dedicated
   [Connector_reactive] tombstone origin is a follow-up — [Board_reactive]'s
   suppression is already correct here: a latched keeper must not wake on
   connector chatter either. *)
let connector_reactive_wakeup_allowed ~base_path ~keeper_name ~channel_id =
  Keeper_registry.board_wakeup_allowed
    ~base_path
    keeper_name
    ~dedup_key:("connector-ambient:" ^ channel_id)
    ~debounce_sec:connector_reactive_debounce_sec
;;

(* RFC-0020: select which keepers wake for a board signal from typed
   [Board_wake.wake_reason] candidates. Explicit mentions short-circuit and
   wake unconditionally; thread-reply/reaction/read-error followups compete for
   [total_limit] slots in candidate order. [None] reasons are dropped (the
   structural reactive pipeline found no deterministic address for that keeper).
   Semantic relatedness is intentionally not a wake reason here: it must enter
   through an LLM/Judge attention boundary, not goal-keyword matching in the
   board publish hook. *)
let select_board_wakeup_candidates
    ?(total_limit = board_reactive_wakeup_max)
    candidates =
  let explicit =
    candidates
    |> List.filter_map (fun (item, reason) ->
      match reason with
      | Some Board_wake.Explicit_mention -> Some (item, Board_wake.Explicit_mention)
      | Some
          ( Board_wake.Thread_reply_after_self_comment
          | Board_wake.Reaction_after_self_activity
          | Board_wake.Board_comment_read_error _ )
      | None -> None)
  in
  match explicit with
  | _ :: _ -> explicit, 0
  | [] ->
    let non_explicit =
      List.filter_map
        (fun (item, reason) ->
           match reason with
           | None -> None
           | Some r -> Some (item, r))
        candidates
    in
    let selected = take total_limit non_explicit in
    let dropped = List.length non_explicit - List.length selected in
    selected, dropped
;;

(* RFC-0020: enqueue the board signal as a typed [stimulus_payload] (PR-1).
   [reason] is the typed {!Board_wake.wake_reason} that selected this keeper;
   here it only picks urgency (explicit mentions are [Immediate]). It is not
   carried in the payload — the next prompt re-derives board context from the
   typed [Board_signal] payload, not from a wake-reason string. *)
let queue_reaction_target_of_board = function
  | Board.Reaction_post -> Keeper_event_queue.Reaction_post
  | Board.Reaction_comment -> Keeper_event_queue.Reaction_comment
;;

let queue_reaction_change_of_board
      (reaction : Board_dispatch.board_reaction_change)
  : Keeper_event_queue.board_reaction_change
  =
  { target_type = queue_reaction_target_of_board reaction.target_type
  ; target_id = reaction.target_id
  ; user_id = reaction.user_id
  ; emoji = reaction.emoji
  ; reacted = reaction.reacted
  }
;;

let board_signal_stimulus
      ~(reason : Board_wake.wake_reason)
      (signal : Board_dispatch.board_signal)
  =
  let payload : Keeper_event_queue.stimulus_payload =
    Keeper_event_queue.Board_signal
      { kind =
          (match signal.kind with
           | Board_dispatch.Board_post_created -> Keeper_event_queue.Post_created
           | Board_dispatch.Board_comment_added -> Keeper_event_queue.Comment_added
           | Board_dispatch.Board_reaction_changed reaction ->
             Keeper_event_queue.Reaction_changed (queue_reaction_change_of_board reaction))
      ; author = signal.author
      ; title = signal.title
      ; content = signal.content
      ; mention_ids = List.map Board.Mention_id.to_string signal.mention_ids
      ; hearth = signal.hearth
      ; updated_at = signal.updated_at
      }
  in
  { Keeper_event_queue.post_id = signal.post_id
  ; urgency =
      (match reason with
       | Board_wake.Explicit_mention -> Keeper_event_queue.Immediate
       | Board_wake.Thread_reply_after_self_comment
       | Board_wake.Reaction_after_self_activity
       | Board_wake.Board_comment_read_error _ ->
         Keeper_event_queue.Normal)
  ; arrived_at = Time_compat.now ()
  ; payload
  }
;;

let board_signal_entry_is_wakeup_candidate (entry : Keeper_registry.registry_entry) =
  match entry.phase with
  | Keeper_state_machine.Running | Keeper_state_machine.Paused -> true
  | _ -> false
;;

let record_board_attention_candidate
      ~(config : Workspace.config)
      ~(signal_kind_label : string)
      ~(meta : keeper_meta)
      (signal : Board_dispatch.board_signal)
  =
  let candidate =
    Keeper_board_attention_candidate.of_board_signal
      ~keeper_name:meta.name
      ~recorded_at:(Time_compat.now ())
      signal
  in
  match Keeper_board_attention_candidate.record ~base_path:config.base_path candidate with
  | `Recorded ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string BoardSignalAttentionCandidateTotal)
      ~labels:
        [ ("keeper", meta.name)
        ; ("kind", signal_kind_label)
        ; ( "attention_authority"
          , Keeper_board_attention_candidate.attention_authority_to_string
              candidate.attention_authority )
        ; ( "wake_authority"
          , Keeper_board_attention_candidate.wake_authority_to_string
              candidate.wake_authority )
        ]
      ()
  | `Duplicate _ -> ()
  | `Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string KeepaliveSignalFailures)
      ~labels:[ ("keeper", meta.name); ("phase", "board_attention_candidate_record") ]
      ();
    Log.Keeper.warn
      "board attention candidate record failed: keeper=%s post=%s error=%s"
      meta.name
      signal.post_id
      err
;;

let paused_meta_allows_board_auto_resume (meta : keeper_meta) =
  meta.paused
  && Option.is_some
       (Keeper_supervisor_types.paused_meta_effective_auto_resume_after_sec meta)
;;

let board_signal_wake_paused_keeper
      ~(config : Workspace.config)
      ~(stimulus : Keeper_event_queue.stimulus)
      (meta : keeper_meta)
  =
  let resumed_meta =
    { meta with paused = false; latched_reason = None; updated_at = now_iso () }
  in
  match
    write_meta_with_merge
      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
      config
      resumed_meta
  with
  | Ok () ->
    Keeper_registry.update_meta ~base_path:config.base_path meta.name resumed_meta;
    Keeper_registry.dispatch_event_unit
      ~base_path:config.base_path
      resumed_meta.name
      Keeper_state_machine.Operator_resume;
    (match
       enqueue_stimulus_and_wakeup_hint_result
         ~base_path:config.base_path
         ~keeper_name:resumed_meta.name
         stimulus
     with
     | Ok _ -> Ok ()
     | Error err ->
       Error
         (Printf.sprintf
            "failed to enqueue board wake stimulus after auto-resume: %s"
            err))
  | Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WriteMetaFailures)
      ~labels:[ ("keeper", meta.name); ("phase", "board_signal_resume_sync") ]
      ();
    Error (Printf.sprintf "failed to write resumed meta: %s" err)
;;

let board_signal_wake_keeper
      ~(config : Workspace.config)
      ~(reason : Board_wake.wake_reason)
      ~(signal : Board_dispatch.board_signal)
      (meta : keeper_meta)
  =
  let stimulus = board_signal_stimulus ~reason signal in
  if meta.paused
  then
    if paused_meta_allows_board_auto_resume meta
    then board_signal_wake_paused_keeper ~config ~stimulus meta
    else Ok ()
  else (
    match
      enqueue_stimulus_and_wakeup_hint_result
        ~base_path:config.base_path
        ~keeper_name:meta.name
        stimulus
    with
    | Ok _ -> Ok ()
    | Error err ->
      Error (Printf.sprintf "failed to enqueue board wake stimulus: %s" err))
;;

let wakeup_relevant_keeper_for_board_signal
      ~(config : Workspace.config)
      (signal : Board_dispatch.board_signal)
  =
  let registry_entries =
    Keeper_registry.all ~base_path:config.base_path ()
    |> List.filter board_signal_entry_is_wakeup_candidate
  in
  let signal_kind_label =
    match signal.kind with
    | Board_dispatch.Board_post_created -> "post_created"
    | Board_dispatch.Board_comment_added -> "comment_added"
    | Board_dispatch.Board_reaction_changed _ -> "reaction_changed"
  in
  (* Yield meter: scanning all running keepers' meta files is CPU-bound
     when many keepers share a domain.  Yield every ~1000 iterations. *)
  let board_ym = Eio_guard.create_yield_meter () in
  let candidates =
    registry_entries
    |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
      let result =
        match read_meta config entry.name with
        | Ok (Some meta) ->
          let wake_reason =
            Keeper_world_observation.board_signal_wake_reason
              ~continuity_summary:meta.continuity_summary
              ~meta
              ~signal
          in
          (* Visibility for the REPO_WAKE_UP audit finding: a [None]
             wake_reason means the running keeper had no explicit mention
             match and (for comments) no external reply after its own comment.
             Without this counter, operators cannot distinguish between a
             board post that legitimately had no deterministic addressee and
             one that was silently dropped by a keeper whose mention_targets
             configuration is too narrow. *)
          (match wake_reason, entry.phase with
           | None, Keeper_state_machine.Running ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string BoardSignalNoWakeTotal)
               ~labels:[
                 ("keeper", meta.name);
                 ("kind", signal_kind_label);
               ]
               ();
             record_board_attention_candidate ~config ~signal_kind_label ~meta signal
           | None, _ | Some _, _ -> ());
          (match entry.phase, wake_reason with
           | Keeper_state_machine.Paused, Some Board_wake.Explicit_mention
             when paused_meta_allows_board_auto_resume meta ->
             Some (meta, wake_reason)
           | Keeper_state_machine.Paused, _ -> None
           | Keeper_state_machine.Running, _ -> Some (meta, wake_reason)
           | _ -> None)
        | _ -> None
      in
      Eio_guard.yield_step board_ym;
      result)
  in
  let wake_meta (meta : keeper_meta) reason =
    if
      board_reactive_wakeup_allowed
        ~base_path:config.base_path
        ~keeper_name:meta.name
        ~signal
    then (
      match board_signal_wake_keeper ~config ~reason ~signal meta with
      | Ok () ->
        Log.Keeper.info
          "board signal wakeup: keeper=%s reason=%s post=%s paused_auto_resume=%b"
          meta.name
          (Board_wake.wake_reason_label reason)
          signal.post_id
          meta.paused
      | Error err ->
        Log.Keeper.warn
          "board signal wakeup failed: keeper=%s reason=%s post=%s error=%s"
          meta.name
          (Board_wake.wake_reason_label reason)
          signal.post_id
          err)
  in
  let selected, dropped = select_board_wakeup_candidates candidates in
  let yield_meter = Eio_guard.create_yield_meter ~interval:1 () in
  selected
  |> List.iter (fun (meta, reason) ->
         wake_meta meta reason;
         Eio_guard.yield_step yield_meter);
  if dropped > 0 then begin
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string BoardSignalWakeupCappedTotal)
      ~labels:[ "kind", signal_kind_label ]
      ~delta:(float_of_int dropped)
      ();
    Log.Keeper.info
      "board signal wakeup capped by configured fanout: dropped=%d post=%s \
       total_limit=%d"
      dropped
      signal.post_id
      board_reactive_wakeup_max
  end
;;

(* Per-stage timing accumulator for Phase 0 profiling.
   In-memory ring of last 100 cycles. Flushed as aggregate at snapshot cadence.
   No additional file I/O — appended to existing snapshot JSON. *)
type stage_timing =
  { presence_ms : float
  ; snapshot_ms : float
  ; board_ms : float
  ; turn_ms : float
  ; recurring_ms : float
  }

let stage_timing_ring_size () =
  Runtime_params.get Governance_registry.keeper_stage_timing_ring_size
;;

let percentile arr p =
  let n = Array.length arr in
  if n = 0
  then 0.0
  else (
    let sorted = Array.copy arr in
    Array.sort Float.compare sorted;
    let idx = Float.to_int (Float.round (float_of_int (n - 1) *. p)) in
    sorted.(min idx (n - 1)))
;;

let stage_timing_to_json ~ring ~count =
  let n = min count (Array.length ring) in
  if n = 0
  then `Null
  else (
    let extract field =
      let arr = Array.init n (fun i -> field ring.(i)) in
      `Assoc
        [ "p50", `Float (percentile arr 0.5)
        ; "p95", `Float (percentile arr 0.95)
        ; "max", `Float (percentile arr 1.0)
        ; "samples", `Int n
        ]
    in
    `Assoc
      [ "presence", extract (fun t -> t.presence_ms)
      ; "snapshot", extract (fun t -> t.snapshot_ms)
      ; "board", extract (fun t -> t.board_ms)
      ; "turn", extract (fun t -> t.turn_ms)
      ; "recurring", extract (fun t -> t.recurring_ms)
      ])
;;

let keepalive_entry_accepts_late_event ~(ctx : _ context) ~(keeper_name : string) =
  match Keeper_registry.get_phase ~base_path:ctx.config.base_path keeper_name with
  | None -> true
  | Some (Keeper_state_machine.Stopped | Keeper_state_machine.Dead) -> false
  | Some _ -> true

let dispatch_keepalive_event ~(ctx : _ context) ~(keeper_name : string) event =
  if keepalive_entry_accepts_late_event ~ctx ~keeper_name then
    Keeper_registry.dispatch_event_unit
      ~base_path:ctx.config.base_path keeper_name event

let dispatch_keepalive_event_with_audit
      ~(ctx : _ context)
      ~(keeper_name : string)
      ~snapshot
      ~events_fired
      ~selected_event
      event
  =
  if keepalive_entry_accepts_late_event ~ctx ~keeper_name then
    (match Keeper_registry.dispatch_event_with_audit_and_log
       ~base_path:ctx.config.base_path
       ~snapshot
       ~events_fired
       ~selected_event
       keeper_name
       event
     with
     | Ok _ -> ()
     | Error err ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string KeepaliveSignalFailures)
           ~labels:[("keeper", keeper_name); ("site", "late_event_rejected")]
           ();
         Log.Keeper.warn
           "%s: keepalive late-event dispatch rejected: %s"
           keeper_name
           (Keeper_state_machine.transition_error_to_string err))
