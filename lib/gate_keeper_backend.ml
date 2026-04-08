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

(* ── Dispatch ────────────────────────────────────────────────── *)

let dispatch ~sw ~clock ~proc_mgr ~net ~config
    ~channel ~channel_user_id ~keeper_name ~content =
  let agent_name = Printf.sprintf "gate:%s:%s" channel channel_user_id in
  let args =
    `Assoc [
      ("name", `String (String.trim keeper_name));
      ("message", `String (String.trim content));
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
  match Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args with
  | Some (true, body) ->
      let duration_ms =
        int_of_float ((Unix.gettimeofday () -. start_time) *. 1000.0)
      in
      let reply = extract_reply_text body in
      let stats = match extract_turn_stats body with
        | Some s -> Some { s with duration_ms }
        | None -> Some { Gate_protocol.model_used = ""; duration_ms; tokens_used = 0 }
      in
      Gate_protocol.Reply { content = reply; stats }
  | Some (false, err) ->
      Gate_protocol.Keeper_error_result err
  | None ->
      Gate_protocol.Unavailable_result
