(** Tool_convo — Conversation (threaded discussion) handlers.

    Extracted from tool_inline_dispatch.ml.
    Handles: masc_convo_start, masc_convo_reply, masc_convo_conclude,
             masc_convo_get, masc_convo_list *)

type result = bool * string

type context = {
  config : Room.config;
  agent_name : string;
}

let get_string = Safe_ops.json_string
let get_int args key default = Safe_ops.json_int ~default key args
let get_float_opt args key = Safe_ops.json_float_opt key args
let get_string_opt args key =
  match Safe_ops.json_string_opt key args with
  | Some "" -> None
  | other -> other
let get_string_list args key = Safe_ops.json_string_list key args

let convo_config config =
  let current_room = Room.read_current_room config |> Option.value ~default:"default" in
  ({ Council.Conversation.base_path = config.Room.base_path; room = current_room }
    : Council.Conversation.config)

let handle_start ctx args =
  let topic = get_string ~default:"" "topic" args in
  let initiator = get_string ~default:ctx.agent_name "initiator" args in
  let initial_content = get_string ~default:"" "initial_content" args in
  let max_turns = get_int args "max_turns" 50 in
  let source_post_id = get_string_opt args "post_id" in
  let mentions = get_string_list args "mentions" in
  if topic = "" then (false, "topic required")
  else begin
    let cc = convo_config ctx.config in
    match Council.Conversation.start ~config:cc ~topic ~initiator
            ~max_turns ~initial_content ~mentions ?source_post_id () with
    | Ok thread ->
        let link_warning = match source_post_id with
          | Some pid ->
              (match Board_dispatch.set_thread_id
                ~post_id:pid ~thread_id:thread.Council.Conversation.id with
               | Ok () -> ""
               | Error e -> Printf.sprintf "\nBoard link failed: %s" (Board.show_board_error e))
          | None -> ""
        in
        let json = Council.Conversation.thread_to_yojson thread in
        (true, Printf.sprintf "Thread started: %s%s\n%s"
          thread.Council.Conversation.id link_warning (Yojson.Safe.pretty_to_string json))
    | Error e -> (false, e)
  end

let handle_reply ctx args =
  let thread_id = get_string ~default:"" "thread_id" args in
  let speaker = get_string ~default:ctx.agent_name "speaker" args in
  let content = get_string ~default:"" "content" args in
  let confidence = get_float_opt args "confidence" in
  let reply_to = get_string_opt args "reply_to" in
  let mentions = get_string_list args "mentions" in
  if thread_id = "" || content = "" then
    (false, "thread_id and content required")
  else if not (try Room.is_agent_joined ctx.config ~agent_name:speaker with Sys_error _ | Not_found -> false) then
    (false, Printf.sprintf "Speaker '%s' is not a member of this room" speaker)
  else begin
    let cc = convo_config ctx.config in
    match Council.Conversation.get ~config:cc ~thread_id with
    | None -> (false, Printf.sprintf "Thread not found: %s" thread_id)
    | Some thread ->
        let loop_check = Council.Loop_guard.check
          ~thread ~speaker ~content
          ~config:Council.Loop_guard.default_config
        in
        match Council.Loop_guard.to_error_message loop_check with
        | Some err -> (false, Printf.sprintf "Loop detected: %s" err)
        | None ->
            match Council.Conversation.reply ~config:cc ~thread_id
                    ~speaker ~content ?confidence ?reply_to ~mentions () with
            | Ok updated ->
                let json = Council.Conversation.thread_to_yojson updated in
                (true, Printf.sprintf "Reply added (turn %d)\n%s"
                  updated.Council.Conversation.current_turn
                  (Yojson.Safe.pretty_to_string json))
            | Error e -> (false, e)
  end

let handle_conclude ctx args =
  let thread_id = get_string ~default:"" "thread_id" args in
  let concluder = get_string ~default:ctx.agent_name "concluder" args in
  let conclusion = get_string ~default:"" "conclusion" args in
  if thread_id = "" || conclusion = "" then
    (false, "thread_id and conclusion required")
  else begin
    let cc = convo_config ctx.config in
    match Council.Conversation.conclude ~config:cc ~thread_id
            ~concluder ~conclusion () with
    | Ok thread ->
        let json = Council.Conversation.thread_to_yojson thread in
        (true, Printf.sprintf "Thread concluded: %s\n%s"
          thread.Council.Conversation.id (Yojson.Safe.pretty_to_string json))
    | Error e -> (false, e)
  end

let handle_get ctx args =
  let thread_id = get_string ~default:"" "thread_id" args in
  if thread_id = "" then (false, "thread_id required")
  else begin
    let cc = convo_config ctx.config in
    match Council.Conversation.get ~config:cc ~thread_id with
    | Some thread ->
        let json = Council.Conversation.thread_to_yojson thread in
        (true, Yojson.Safe.pretty_to_string json)
    | None -> (false, Printf.sprintf "Thread not found: %s" thread_id)
  end

let handle_list ctx _args =
  let cc = convo_config ctx.config in
  let threads = Council.Conversation.list_active ~config:cc in
  let json = `List (List.map (fun th ->
    `Assoc [
      ("id", `String th.Council.Conversation.id);
      ("topic", `String th.Council.Conversation.topic);
      ("status", `String (Council.Conversation.thread_status_to_string th.Council.Conversation.status));
      ("turns", `Int th.Council.Conversation.current_turn);
      ("participants", `List (List.map (fun p -> `String p) th.Council.Conversation.participants));
    ]
  ) threads) in
  (true, Printf.sprintf "Active threads: %d\n%s"
    (List.length threads) (Yojson.Safe.pretty_to_string json))

(* Dispatch *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_convo_start" -> Some (handle_start ctx args)
  | "masc_convo_reply" -> Some (handle_reply ctx args)
  | "masc_convo_conclude" -> Some (handle_conclude ctx args)
  | "masc_convo_get" -> Some (handle_get ctx args)
  | "masc_convo_list" -> Some (handle_list ctx args)
  | _ -> None
