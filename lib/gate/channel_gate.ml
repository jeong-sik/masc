(** Channel_gate -- deterministic router for external chat platforms.
    See [channel_gate.mli] for the full contract.

    This module owns dedup state and metrics recording.
    Types come from {!Gate_protocol}.
    Keeper dispatch is injected via [dispatch_fn]. *)

(* ── Re-exported types from Gate_protocol ────────────────────── *)

type inbound_message = Gate_protocol.inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

type turn_stats = Gate_protocol.turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

type outbound_message = Gate_protocol.outbound_message = {
  keeper_name : string;
  content : string;
  structured : Yojson.Safe.t option;
  turn_stats : turn_stats option;
  message_request : Gate_protocol.message_request option;
}

type validation_error = Gate_protocol.validation_error =
  | Empty_content
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

type gate_error = Gate_protocol.gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Accepted_keeper_error of string
  | Dispatch_unavailable
  | Internal of string

type inbound_error_notice =
  | Offline_notice
  | Retry_notice
  | Accepted_failure_notice
  | No_notice

type dispatch_fn =
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result

type streaming_dispatch_fn =
  on_text_snapshot:(string -> unit) ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result

(* ── Configuration ──────────────────────────────────────────── *)

let max_content_length () = 4000

let dedup_ttl_sec () =
  Env_config_core.get_int ~default:3600 "MASC_CHANNEL_GATE_DEDUP_TTL_SEC"
  |> max 1
  |> float_of_int

(* ── Deduplication (TTL hashtable, Eio-guarded mutex) ───────── *)

let dedup_table : (string, float) Hashtbl.t = Hashtbl.create 256

let dedup_mutex = Eio.Mutex.create ()

let dedup_max_entries = 10_000

let with_dedup_lock f = Eio_guard.with_mutex dedup_mutex f

let dedup_check key =
  with_dedup_lock (fun () ->
    let now = Unix.gettimeofday () in
    let result =
      match Hashtbl.find_opt dedup_table key with
      | Some ts when now -. ts < dedup_ttl_sec () -> true
      | Some _ ->
          Hashtbl.remove dedup_table key;
          false
      | None -> false
    in
    if not result then begin
      if Hashtbl.length dedup_table >= dedup_max_entries then begin
        let oldest_key = ref "" in
        let oldest_ts = ref Float.max_float in
        Hashtbl.iter (fun k ts ->
          if ts < !oldest_ts then begin oldest_key := k; oldest_ts := ts end
        ) dedup_table;
        if !oldest_key <> "" then Hashtbl.remove dedup_table !oldest_key
      end;
      Hashtbl.replace dedup_table key now
    end;
    result)

let dedup_cleanup ~now =
  with_dedup_lock (fun () ->
    let ttl = dedup_ttl_sec () in
    let to_remove =
      Hashtbl.fold
        (fun k ts acc -> if now -. ts >= ttl then k :: acc else acc)
        dedup_table []
    in
    List.iter (Hashtbl.remove dedup_table) to_remove)

let dedup_table_size () =
  with_dedup_lock (fun () -> Hashtbl.length dedup_table)

let dedup_release key =
  with_dedup_lock (fun () -> Hashtbl.remove dedup_table key)

(* Register dedup_table_size callback to break cycle *)
let () = Channel_gate_metrics.register_dedup_size_fn dedup_table_size

(* ── Pulse consumer for periodic dedup cleanup ─────────────── *)

(* [dedup_cleanup] exists in the .mli and is documented as "Called
   periodically", but no production code path wired it to a timer
   or Pulse consumer — only the test suite invoked it. Without a
   periodic sweep, TTL-expired entries never leave the table until
   it hits [dedup_max_entries] (default 10_000), at which point
   every subsequent insert falls into the O(n) "evict the oldest"
   branch in [dedup_check] while holding the lock. This consumer
   restores the intended behavior: each beat calls [dedup_cleanup]
   so stale entries are reclaimed before the cap is reached. *)
let make_dedup_cleanup_consumer () : (module Pulse.Consumer) =
  (module struct
    let name = "channel-gate-dedup-cleanup"
    let should_act _beat = true
    let on_beat _beat =
      try
        dedup_cleanup ~now:(Unix.gettimeofday ());
        Ok ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Error
            (Printf.sprintf "dedup_cleanup failed: %s"
               (Printexc.to_string exn))
  end)

(* ── Delegated helpers ───────────────────────────────────────── *)

let validation_error_to_string = Gate_protocol.validation_error_to_string
let gate_error_to_string = Gate_protocol.gate_error_to_string
let inbound_of_json = Gate_protocol.inbound_of_json
let outbound_to_json = Gate_protocol.outbound_to_json
let error_json = Gate_protocol.error_json

let inbound_error_notice = function
  | Dispatch_unavailable -> Offline_notice
  | Keeper_error _ -> Retry_notice
  | Accepted_keeper_error _ -> Accepted_failure_notice
  | Validation _ | Internal _ -> No_notice

(* ── Validation (uses local dedup) ───────────────────────────── *)

let validate (msg : inbound_message) =
  Gate_protocol.validate
    ~max_content_length:(max_content_length ())
    ~dedup_check
    msg

(* ── Dispatch ────────────────────────────────────────────────── *)

let handle_inbound_with ~dispatch (msg : inbound_message) =
  let channel = msg.channel in
  match validate msg with
  | Error e ->
      Channel_gate_metrics.record_attempt
        ~channel
        ~workspace_id:msg.channel_workspace_id
        ~keeper:(String.trim msg.keeper_name)
        ~duration_ms:0
        (match e with
         | Duplicate_message _ -> Channel_gate_metrics.Duplicate
         | Empty_content
         | Content_too_long _
         | Empty_keeper_name
         | Empty_channel_user_id
         | Empty_idempotency_key ->
             Channel_gate_metrics.Validation_error
               (validation_error_to_string e));
      Error (Validation e)
  | Ok () ->
      let keeper = String.trim msg.keeper_name in
      let result =
        dispatch
          ~channel
          ~channel_user_id:msg.channel_user_id
          ~channel_user_name:msg.channel_user_name
          ~channel_workspace_id:msg.channel_workspace_id
          ~keeper_name:keeper
          ~idempotency_key:msg.idempotency_key
          ~metadata:msg.metadata
          ~content:(String.trim msg.content)
      in
      (match result with
       | Gate_protocol.Reply { content = reply; structured; stats; message_request } ->
           let duration_ms = match stats with
             | Some s -> s.duration_ms
             | None -> 0
           in
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms
             Channel_gate_metrics.Success;
           Ok
             { keeper_name = keeper
             ; content = reply
             ; structured
             ; turn_stats = stats
             ; message_request
             }
       | Gate_protocol.Keeper_error_result err ->
           (* Validation reserves the external idempotency key before dispatch.
              A keeper-side failure did not accept the message, so release the
              reservation: a connector replay of the same event may retry
              instead of being silently discarded as a duplicate. *)
           dedup_release msg.idempotency_key;
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms:0
             (Channel_gate_metrics.Keeper_error err);
           Error (Keeper_error err)
       | Gate_protocol.Accepted_keeper_error_result err ->
           (* The durable inbound transcript committed before the turn failed.
              Keep the idempotency reservation so a connector retry cannot
              append the same external message twice. *)
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms:0
             (Channel_gate_metrics.Keeper_error err);
           Error (Accepted_keeper_error err)
       | Gate_protocol.Unavailable_result ->
           dedup_release msg.idempotency_key;
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms:0
             Channel_gate_metrics.Dispatch_unavailable;
           Error Dispatch_unavailable)

let handle_inbound ~dispatch msg =
  handle_inbound_with ~dispatch msg

let handle_inbound_streaming ~dispatch ~on_text_snapshot msg =
  handle_inbound_with ~dispatch:(dispatch ~on_text_snapshot) msg
