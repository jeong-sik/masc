(** Channel_gate -- deterministic router for external chat platforms.
    See [channel_gate.mli] for the full contract. *)

(* ── Types ──────────────────────────────────────────────────── *)

type inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_room_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

type turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

type outbound_message = {
  keeper_name : string;
  content : string;
  turn_stats : turn_stats option;
}

type validation_error =
  | Empty_content
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

(* ── Configuration ──────────────────────────────────────────── *)

let max_content_length () =
  match Sys.getenv_opt "MASC_CHANNEL_GATE_MAX_CONTENT_LENGTH" with
  | Some s -> (try max 100 (min 16000 (int_of_string s)) with _ -> 4000)
  | None -> 4000

let dedup_ttl_sec () =
  match Sys.getenv_opt "MASC_CHANNEL_GATE_DEDUP_TTL_SEC" with
  | Some s -> (try max 10.0 (min 3600.0 (float_of_string s)) with _ -> 300.0)
  | None -> 300.0

(* ── Deduplication (TTL hashtable, Eio-guarded mutex) ───────── *)

(** Seen idempotency keys with their insertion timestamp. *)
let dedup_table : (string, float) Hashtbl.t = Hashtbl.create 256

let dedup_mutex = Eio.Mutex.create ()

(** Max dedup entries to prevent unbounded memory growth. *)
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
      (* Evict oldest if at capacity *)
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

(* ── Validation (pure) ──────────────────────────────────────── *)

let validation_error_to_string = function
  | Empty_content -> "content is required"
  | Content_too_long len ->
      Printf.sprintf "content too long: %d chars (max %d)" len (max_content_length ())
  | Empty_keeper_name -> "keeper_name is required"
  | Empty_channel_user_id -> "channel_user_id is required"
  | Empty_idempotency_key -> "idempotency_key is required"
  | Duplicate_message key ->
      Printf.sprintf "duplicate message (idempotency_key=%s)" key

type gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal of string

let gate_error_to_string = function
  | Validation e -> validation_error_to_string e
  | Keeper_error msg -> Printf.sprintf "keeper error: %s" msg
  | Dispatch_unavailable -> "keeper dispatch unavailable"
  | Internal _ -> "internal error"

let validate (msg : inbound_message) =
  let content = String.trim msg.content in
  let name = String.trim msg.keeper_name in
  if name = "" then Error Empty_keeper_name
  else if String.trim msg.channel_user_id = "" then Error Empty_channel_user_id
  else if String.trim msg.idempotency_key = "" then Error Empty_idempotency_key
  else if content = "" then Error Empty_content
  else
    let len = String.length content in
    if len > max_content_length () then Error (Content_too_long len)
    else if dedup_check msg.idempotency_key then
      Error (Duplicate_message msg.idempotency_key)
    else Ok ()

(* ── Dispatch ───────────────────────────────────────────────── *)

let extract_turn_stats (body : string) : turn_stats option =
  try
    let json = Yojson.Safe.from_string body in
    let open Yojson.Safe.Util in
    let model =
      json |> member "model_used" |> to_string_option
      |> Option.value
           ~default:
             (json |> member "model" |> to_string_option
              |> Option.value ~default:"")
    in
    let dur = json |> member "duration_ms" |> to_int_option
              |> Option.value ~default:0 in
    let tok = json |> member "total_tokens" |> to_int_option
              |> Option.value ~default:0 in
    if model = "" && dur = 0 && tok = 0 then None
    else Some { model_used = model; duration_ms = dur; tokens_used = tok }
  with _ -> None

let extract_reply_text (body : string) : string =
  try
    let json = Yojson.Safe.from_string body in
    let open Yojson.Safe.Util in
    (* keeper_msg returns {reply, ...} or plain text *)
    match json |> member "reply" |> to_string_option with
    | Some r -> r
    | None ->
        (match json |> member "text" |> to_string_option with
         | Some t -> t
         | None -> body)
  with _ -> body

let handle_inbound ~sw ~clock ~proc_mgr ~net ~config (msg : inbound_message) =
  match validate msg with
  | Error e ->
      Channel_gate_metrics.record_attempt
        ~channel:(Agent_identity.normalize_channel_label msg.channel)
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
      let args =
        `Assoc [
          ("name", `String (String.trim msg.keeper_name));
          ("message", `String (String.trim msg.content));
        ]
      in
      let keeper_ctx : _ Tool_keeper.context = {
        config;
        agent_name =
          Printf.sprintf "gate:%s:%s"
            (Agent_identity.normalize_channel_label msg.channel)
            msg.channel_user_id;
        sw;
        clock;
        proc_mgr;
        net;
      } in
      let start_time = Unix.gettimeofday () in
      match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args with
      | Some (true, body) ->
          let duration_ms =
            int_of_float ((Unix.gettimeofday () -. start_time) *. 1000.0)
          in
          let ch = Agent_identity.normalize_channel_label msg.channel in
          let keeper = String.trim msg.keeper_name in
          Channel_gate_metrics.record_attempt
            ~channel:ch
            ~room_id:msg.channel_room_id
            ~keeper
            ~duration_ms
            Channel_gate_metrics.Success;
          let reply = extract_reply_text body in
          let stats = match extract_turn_stats body with
            | Some s -> Some { s with duration_ms }
            | None -> Some { model_used = ""; duration_ms; tokens_used = 0 }
          in
          Ok { keeper_name = keeper; content = reply; turn_stats = stats }
      | Some (false, err) ->
          let duration_ms =
            int_of_float ((Unix.gettimeofday () -. start_time) *. 1000.0)
          in
          Channel_gate_metrics.record_attempt
            ~channel:(Agent_identity.normalize_channel_label msg.channel)
            ~room_id:msg.channel_room_id
            ~keeper:(String.trim msg.keeper_name)
            ~duration_ms
            (Channel_gate_metrics.Keeper_error err);
          Error (Keeper_error err)
      | None ->
          Channel_gate_metrics.record_attempt
            ~channel:(Agent_identity.normalize_channel_label msg.channel)
            ~room_id:msg.channel_room_id
            ~keeper:(String.trim msg.keeper_name)
            ~duration_ms:0
            Channel_gate_metrics.Dispatch_unavailable;
          Error Dispatch_unavailable

(* ── JSON helpers ───────────────────────────────────────────── *)

let error_json msg =
  `Assoc [ ("ok", `Bool false); ("error", `String msg) ]

let outbound_to_json out =
  let stats_json = match out.turn_stats with
    | None -> `Null
    | Some s ->
        `Assoc [
          ("model_used", `String s.model_used);
          ("duration_ms", `Int s.duration_ms);
          ("tokens_used", `Int s.tokens_used);
        ]
  in
  `Assoc [
    ("ok", `Bool true);
    ("keeper_name", `String out.keeper_name);
    ("reply", `String out.content);
    ("turn_stats", stats_json);
  ]

let inbound_of_json json =
  let open Yojson.Safe.Util in
  try
    let str key = json |> member key |> to_string_option
                  |> Option.value ~default:"" in
    let channel = str "channel" |> Agent_identity.normalize_channel_label in
    let metadata =
      match json |> member "metadata" with
      | `Assoc pairs ->
          List.filter_map (fun (k, v) ->
            match v with `String s -> Some (k, s) | _ -> None
          ) pairs
      | _ -> []
    in
    Ok {
      channel;
      channel_user_id = str "channel_user_id";
      channel_user_name = str "channel_user_name";
      channel_room_id = str "channel_room_id";
      keeper_name = str "keeper_name";
      content = str "content";
      idempotency_key = str "idempotency_key";
      metadata;
    }
  with
  | Yojson.Json_error e -> Error ("invalid json: " ^ e)
  | exn -> Error ("parse error: " ^ Printexc.to_string exn)
