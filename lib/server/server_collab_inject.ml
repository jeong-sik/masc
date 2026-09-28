type prompt_error =
  | Prompt_empty
  | Prompt_continuation_failed of string
  | Prompt_submit_failed of string

let prompt_error_to_string = function
  | Prompt_empty -> "empty prompt"
  | Prompt_continuation_failed detail ->
    "continuation channel refused the keeper: " ^ detail
  | Prompt_submit_failed detail -> "prompt submit failed: " ^ detail
;;

let channel = "collab"

let room_b64 room =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet room
;;

let submit_prompt ~base_dir ~keeper ~room ~peer ~label ~text =
  let message = String.trim text in
  if String.equal message ""
  then Error Prompt_empty
  else (
    let room_id = room_b64 room in
    let user_id = Printf.sprintf "guest-%d" peer in
    let user_name =
      match label with
      | None -> ""
      | Some name -> String.trim name
    in
    let operation_id = Random_id.prefixed ~prefix:"collab-" ~bytes:8 in
    match
      Keeper_chat_operation.Operation_id.of_string operation_id
    with
    | Error detail -> Error (Prompt_submit_failed detail)
    | Ok operation_id -> (
      match Keeper_continuation_channel.collab ~room:room_id ~user_id with
      | Error detail -> Error (Prompt_continuation_failed detail)
      | Ok continuation_channel ->
        let surface =
          Surface_ref.Gate
            { label = channel
            ; address = [ "room", room_id; "peer", string_of_int peer ]
            }
        in
        (match
           Keeper_chat_operation_payload.source_to_json
             ~submitted_by:
               (Gate_keeper_backend.agent_name_for_channel_actor
                  ~channel
                  ~channel_workspace_id:room_id
                  ~channel_user_id:user_id)
             ~thread_id:("keeper:" ^ keeper)
             ~continuation_channel
             ~surface
             ~channel
             ~channel_user_id:user_id
             ~channel_user_name:user_name
             ~channel_workspace_id:room_id
             ~conversation_id:(Some ("collab:" ^ room_id))
             ~external_message_id:
               (Some (Keeper_chat_operation.Operation_id.to_string operation_id))
             ~workspace_id:(Some room_id)
             ~extra_mentions:[]
             (* A connector person, never a Keeper: guest prompts are
                external speech, like Slack and Discord arrivals. *)
             ~sender_keeper:None
             ~user_row_origin:Keeper_chat_store.Needs_append
         with
         | Error detail -> Error (Prompt_submit_failed detail)
         | Ok source ->
           let input =
             Keeper_chat_operation_payload.input_to_json
               ~message
               ~user_blocks:[]
               ~turn_instructions:None
               ~surface_context:None
               ~attachments:[]
           in
           (match
              Keeper_owner_registry.submit_operation
                ~base_path:base_dir
                ~keeper_name:keeper
                ~operation_id
                ~source
                ~input
            with
            | Error error ->
              Error
                (Prompt_submit_failed
                   (Keeper_owner_registry.command_error_to_string error))
            | Ok _ ->
              Ok (Keeper_chat_operation.Operation_id.to_string operation_id)))))
;;

type abort_outcome =
  | Aborted of string
  | Nothing_running
  | Abort_failed of string

let abort_current ~base_dir ~keeper ~latest_op =
  match latest_op with
  | None -> Nothing_running
  | Some op -> (
    match Keeper_chat_operation.Operation_id.of_string op with
    | Error detail -> Abort_failed ("tracked operation id refused: " ^ detail)
    | Ok operation_id -> (
      match
        Keeper_owner_registry.interrupt_running_operation
          ~base_path:base_dir
          ~keeper_name:keeper
          operation_id
      with
      | Error error ->
        Abort_failed (Keeper_owner_registry.command_error_to_string error)
      | Ok Keeper_owner.Operation_interrupt_signalled -> Aborted op
      | Ok (Keeper_owner.Operation_not_current _) -> Nothing_running
      | Ok Keeper_owner.Operation_settling -> Nothing_running
      | Ok Keeper_owner.Operation_maintenance_running ->
        Abort_failed "owner maintenance running; retry the abort"
      | Ok (Keeper_owner.Operation_interrupt_failed detail) ->
        Abort_failed detail))
;;

type transcript = {
  text : string;
  total_bytes : int;
  capped : bool;
}

let max_fetch_bytes = 1048576
let transcript_message_cap = 4096
let transcript_render_cap_bytes = 4194304

let render_message (msg : Keeper_chat_store.chat_message) =
  let role =
    String.uppercase_ascii (Keeper_chat_store.Role.to_label msg.role)
  in
  let who =
    match msg.role with
    | Keeper_chat_store.Role.User -> (
      match msg.speaker with
      | None -> ""
      | Some speaker -> (
        match speaker.speaker_name with
        | Some name when not (String.equal (String.trim name) "") ->
          "[" ^ String.trim name ^ "]"
        | _ -> (
          match speaker.speaker_id with
          | Some id when not (String.equal (String.trim id) "") ->
            "[" ^ String.trim id ^ "]"
          | _ -> "")))
    | Keeper_chat_store.Role.Tool -> (
      match msg.tool_call_name with
      | Some name -> "[" ^ name ^ "]"
      | None -> "")
    | Keeper_chat_store.Role.Assistant | Keeper_chat_store.Role.System -> ""
  in
  role ^ who ^ ": " ^ msg.content
;;

(* Newest [max_bytes] from a line boundary. *)
let tail_lines ~max_bytes rendered =
  let total = String.length rendered in
  if total <= max_bytes
  then rendered
  else (
    let start = total - max_bytes in
    let cut =
      match String.index_from_opt rendered start '\n' with
      | None -> start
      | Some nl -> nl + 1
    in
    if cut >= total then "" else String.sub rendered cut (total - cut))
;;

let fetch_transcript ~base_dir ~keeper ~max_bytes =
  let max_bytes = max 0 (min max_fetch_bytes max_bytes) in
  Eio_unix.run_in_systhread (fun () ->
      let rec walk ~before acc_messages acc_count =
        if acc_count >= transcript_message_cap
        then acc_messages, true
        else (
          let page =
            Keeper_chat_store.load_page ~base_dir ~keeper_name:keeper ?before
              ()
          in
          let messages = page.messages @ acc_messages in
          let count = acc_count + List.length page.messages in
          if not page.has_more
          then messages, false
          else (
            match page.messages with
            | [] -> messages, true
            | oldest :: _ -> walk ~before:(Some oldest.ts) messages count))
      in
      let messages, capped_by_count = walk ~before:None [] 0 in
      let rendered = String.concat "\n" (List.map render_message messages) in
      let rendered, capped_by_bytes =
        if String.length rendered > transcript_render_cap_bytes
        then
          ( tail_lines ~max_bytes:transcript_render_cap_bytes rendered,
            true )
        else rendered, false
      in
      let total_bytes = String.length rendered in
      { text = tail_lines ~max_bytes rendered
      ; total_bytes
      ; capped = capped_by_count || capped_by_bytes
      })
;;

type injector = {
  submit_prompt :
    base_dir:string
    -> keeper:string
    -> room:string
    -> peer:int
    -> label:string option
    -> text:string
    -> (string, prompt_error) result;
  abort_current :
    base_dir:string -> keeper:string -> latest_op:string option -> abort_outcome;
  fetch_transcript : base_dir:string -> keeper:string -> max_bytes:int -> transcript;
}

let default_injector : injector =
  { submit_prompt = submit_prompt
  ; abort_current = abort_current
  ; fetch_transcript = fetch_transcript
  }
;;
