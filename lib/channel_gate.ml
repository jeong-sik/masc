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
  channel_room_id : string;
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
  turn_stats : turn_stats option;
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
  | Dispatch_unavailable
  | Internal of string

type dispatch_fn =
  channel:string ->
  channel_user_id:string ->
  keeper_name:string ->
  content:string ->
  Gate_protocol.dispatch_result

(* ── Configuration ──────────────────────────────────────────── *)

let default_max_content_length = 4000

let max_content_length () =
  match Sys.getenv_opt "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH" with
  | Some s -> (try max 100 (min 16000 (int_of_string s)) with Eio.Cancel.Cancelled _ as e -> raise e | _ -> default_max_content_length)
  | None -> default_max_content_length

let dedup_ttl_sec () =
  match Sys.getenv_opt "MASC_CHANNEL_GATE_DEDUP_TTL_SEC" with
  | Some s -> (try max 10.0 (min 3600.0 (float_of_string s)) with Eio.Cancel.Cancelled _ as e -> raise e | _ -> 300.0)
  | None -> 300.0

(* ── Deduplication (TTL hashtable, Eio-guarded mutex) ───────── *)

let dedup_table : (string, float) Hashtbl.t = Hashtbl.create 256

let dedup_mutex = Eio.Mutex.create ()

let dedup_max_entries =
  match Sys.getenv_opt "MASC_CHANNEL_GATE_DEDUP_MAX_ENTRIES" with
  | Some s -> (try max 100 (min 100_000 (int_of_string s)) with Eio.Cancel.Cancelled _ as e -> raise e | _ -> 10_000)
  | None -> 10_000

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

(* Register dedup_table_size callback to break cycle *)
let () = Channel_gate_metrics.register_dedup_size_fn dedup_table_size

(* ── Delegated helpers ───────────────────────────────────────── *)

let validation_error_to_string = Gate_protocol.validation_error_to_string
let gate_error_to_string = Gate_protocol.gate_error_to_string
let inbound_of_json = Gate_protocol.inbound_of_json
let outbound_to_json = Gate_protocol.outbound_to_json
let error_json = Gate_protocol.error_json

(* ── Validation (uses local dedup) ───────────────────────────── *)

let validate (msg : inbound_message) =
  Gate_protocol.validate
    ~max_content_length:(max_content_length ())
    ~dedup_check
    msg

(* ── Dispatch ────────────────────────────────────────────────── *)

let handle_inbound ~dispatch (msg : inbound_message) =
  let channel = msg.channel in
  match validate msg with
  | Error e ->
      Channel_gate_metrics.record_attempt
        ~channel
        ~room_id:msg.channel_room_id
        ~keeper:(String.trim msg.keeper_name)
        ~duration_ms:0
        (match e with
         | Duplicate_message _ -> Channel_gate_metrics.Duplicate
         | _ ->
             Channel_gate_metrics.Validation_error
               (validation_error_to_string e));
      Error (Validation e)
  | Ok () ->
      let keeper = String.trim msg.keeper_name in
      let result =
        dispatch
          ~channel
          ~channel_user_id:msg.channel_user_id
          ~keeper_name:keeper
          ~content:(String.trim msg.content)
      in
      (match result with
       | Gate_protocol.Reply { content = reply; stats } ->
           let duration_ms = match stats with
             | Some s -> s.duration_ms
             | None -> 0
           in
           Channel_gate_metrics.record_attempt
             ~channel
             ~room_id:msg.channel_room_id
             ~keeper
             ~duration_ms
             Channel_gate_metrics.Success;
           Ok { keeper_name = keeper; content = reply; turn_stats = stats }
       | Gate_protocol.Keeper_error_result err ->
           Channel_gate_metrics.record_attempt
             ~channel
             ~room_id:msg.channel_room_id
             ~keeper
             ~duration_ms:0
             (Channel_gate_metrics.Keeper_error err);
           Error (Keeper_error err)
       | Gate_protocol.Unavailable_result ->
           Channel_gate_metrics.record_attempt
             ~channel
             ~room_id:msg.channel_room_id
             ~keeper
             ~duration_ms:0
             Channel_gate_metrics.Dispatch_unavailable;
           Error Dispatch_unavailable)
