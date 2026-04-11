(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.
    See [gate_keeper_backend.mli] for the full contract. *)

(* ── Keeper response parsing ─────────────────────────────────── *)

let extract_turn_stats (body : string) : Gate_protocol.turn_stats option =
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
    else Some { Gate_protocol.model_used = model; duration_ms = dur; tokens_used = tok }
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

let extract_reply_text (body : string) : string =
  try
    let json = Yojson.Safe.from_string body in
    let open Yojson.Safe.Util in
    match json |> member "reply" |> to_string_option with
    | Some r -> r
    | None ->
        (match json |> member "text" |> to_string_option with
         | Some t -> t
         | None -> body)
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> body

let extract_structured (body : string) : Yojson.Safe.t option =
  try
    let json = Yojson.Safe.from_string body in
    match Yojson.Safe.Util.member "structured" json with
    | `Null -> None
    | v -> Some v
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

(* ── Dispatch ────────────────────────────────────────────────── *)

let normalized_context_value value =
  value
  |> String.to_seq
  |> Seq.map (function
       | '\n' | '\r' | '\t' -> ' '
       | ch -> ch)
  |> String.of_seq
  |> String.trim

let normalized_or_unknown value =
  match normalized_context_value value with
  | "" -> "unknown"
  | trimmed -> trimmed

let agent_name_for_channel_actor ~channel ~channel_room_id ~channel_user_id =
  Printf.sprintf "gate:%s:%s:%s"
    (normalized_or_unknown channel)
    (normalized_or_unknown channel_room_id)
    (normalized_or_unknown channel_user_id)

let contextualize_message ~channel ~channel_user_id ~channel_user_name
    ~channel_room_id ~content =
  let safe_channel = normalized_or_unknown channel in
  let safe_user_id = normalized_or_unknown channel_user_id in
  let safe_user_name = normalized_or_unknown channel_user_name in
  let safe_room_id = normalized_or_unknown channel_room_id in
  let safe_content = String.trim content in
  String.concat "\n"
    [
      "[External channel context]";
      "channel: " ^ safe_channel;
      "room_id: " ^ safe_room_id;
      "user_id: " ^ safe_user_id;
      "user_name: " ^ safe_user_name;
      "";
      "[User message]";
      safe_content;
    ]

let dispatch ~sw ~clock ~proc_mgr ~net ~config
    ~channel ~channel_user_id ~channel_user_name ~channel_room_id
    ~keeper_name ~content =
  let agent_name =
    agent_name_for_channel_actor ~channel ~channel_room_id ~channel_user_id
  in
  let args =
    `Assoc [
      ("name", `String (String.trim keeper_name));
      ( "message",
        `String
          (contextualize_message ~channel ~channel_user_id ~channel_user_name
             ~channel_room_id ~content) );
      ("direct_reply", `Bool true);
    ]
  in
  let keeper_ctx : _ Tool_keeper.context = {
    config;
    agent_name;
    sw;
    clock;
    proc_mgr;
    net;
  } in
  let start_time = Unix.gettimeofday () in
  (* Channel gate needs the final keeper reply, not the async request ACK that
     plain [dispatch] returns for masc_keeper_msg. *)
  match
    Tool_keeper.dispatch_stream ~on_text_delta:(fun _ -> ()) keeper_ctx
      ~name:"masc_keeper_msg" ~args
  with
  | Some (true, body) ->
      let duration_ms =
        int_of_float ((Unix.gettimeofday () -. start_time) *. 1000.0)
      in
      let reply = extract_reply_text body in
      let structured = extract_structured body in
      let stats = match extract_turn_stats body with
        | Some s -> Some { s with duration_ms }
        | None -> Some { Gate_protocol.model_used = ""; duration_ms; tokens_used = 0 }
      in
      Gate_protocol.Reply { content = reply; structured; stats }
  | Some (false, err) ->
      Gate_protocol.Keeper_error_result err
  | None ->
      Gate_protocol.Unavailable_result
