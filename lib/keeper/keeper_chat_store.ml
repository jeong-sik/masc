(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read","source":"dashboard"} v}

    Connector rows may additionally carry opaque route coordinates:
    [conversation_id] for channel/thread grouping and [external_message_id]
    for the inbound platform message. The store does not interpret these
    values.

    @since 2.145.0 *)

let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let chat_dir base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "keeper_chat"

let chat_path ~base_dir ~keeper_name =
  Filename.concat (chat_dir base_dir) (sanitize_name keeper_name ^ ".jsonl")

let persistence_surface = "keeper_chat_store"

let record_persistence_read_drop ~reason () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)]
    ()

let report_persistence_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () -> record_persistence_read_drop ~reason ())
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let ensure_dir_once ~base_dir =
  ignore (Keeper_fs.ensure_dir (chat_dir base_dir))

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
}

type tool_call = {
  call_id : string;
  call_name : string;
  args : string;
}

type speaker_authority =
  | Owner
  | External

let authority_label = function
  | Owner -> "owner"
  | External -> "external"

let authority_of_label = function
  | "owner" -> Some Owner
  | "external" -> Some External
  | _ -> None

type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

type chat_message = {
  role : Keeper_chat_role.t;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_call_id : string option;
  tool_call_name : string option;
  source : string option;
  conversation_id : string option;
  external_message_id : string option;
  speaker : speaker option;
}

let redaction_for ~base_dir ~keeper_name =
  Keeper_secret_redaction.snapshot ~base_path:base_dir ~keeper_name

let redact_attachment redaction att =
  { att with data = Keeper_secret_redaction.redact_text redaction att.data }

let redact_tool_call redaction tc =
  { tc with args = Keeper_secret_redaction.redact_text redaction tc.args }

let redact_message redaction msg =
  let attachments =
    Option.map (List.map (redact_attachment redaction)) msg.attachments
  in
  { msg with
    content = Keeper_secret_redaction.redact_text redaction msg.content;
    attachments;
  }

let opt_string_field key = function
  | None -> []
  | Some value -> [ (key, `String value) ]

let speaker_fields = function
  | None -> []
  | Some sp ->
      opt_string_field "speaker_id" sp.speaker_id
      @ opt_string_field "speaker_name" sp.speaker_name
      @ [ ("speaker_authority", `String (authority_label sp.speaker_authority)) ]

let encode_line ~(role : Keeper_chat_role.t) ~content ~ts ?attachments ?tool_call_id ?tool_call_name
    ?source ?conversation_id ?external_message_id ?speaker () : string =
  let base_fields = [
    ("role", `String (Keeper_chat_role.to_string role));
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  let attachment_fields = match attachments with
    | None -> []
    | Some atts ->
        let json_atts = List.map (fun a ->
          `Assoc [
            ("id", `String a.id);
            ("att_type", `String a.att_type);
            ("name", `String a.name);
            ("size", `Int a.size);
            ("mime_type", `String a.mime_type);
            ("data", `String a.data);
          ]) atts in
        [("attachments", `List json_atts)]
  in
  let all_fields =
    base_fields
    @ opt_string_field "tool_call_id" tool_call_id
    @ opt_string_field "tool_call_name" tool_call_name
    @ opt_string_field "source" source
    @ opt_string_field "conversation_id" conversation_id
    @ opt_string_field "external_message_id" external_message_id
    @ speaker_fields speaker
    @ attachment_fields
  in
  Yojson.Safe.to_string (`Assoc all_fields) ^ "\n"

let encode_line_json ~(role : Keeper_chat_role.t) ~content ~ts ?attachments ?tool_call_id ?tool_call_name
    ?source ?conversation_id ?external_message_id ?speaker () : Yojson.Safe.t =
  let base_fields = [
    ("role", `String (Keeper_chat_role.to_string role));
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  let attachment_fields = match attachments with
    | None -> []
    | Some atts ->
        let json_atts = List.map (fun a ->
          `Assoc [
            ("id", `String a.id);
            ("att_type", `String a.att_type);
            ("name", `String a.name);
            ("size", `Int a.size);
            ("mime_type", `String a.mime_type);
            ("data", `String a.data);
          ]) atts in
        [("attachments", `List json_atts)]
  in
  let all_fields =
    base_fields
    @ opt_string_field "tool_call_id" tool_call_id
    @ opt_string_field "tool_call_name" tool_call_name
    @ opt_string_field "source" source
    @ opt_string_field "conversation_id" conversation_id
    @ opt_string_field "external_message_id" external_message_id
    @ speaker_fields speaker
    @ attachment_fields
  in
  `Assoc all_fields

let append_json_line ~base_dir ~keeper_name json_line =
  let path = chat_path ~base_dir ~keeper_name in
  ensure_dir_once ~base_dir;
  let oc = open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 path in
  try
    let line_str = Yojson.Safe.to_string json_line ^ "\n" in
    output_string oc line_str;
    close_out oc
  with e ->
    close_out oc;
    raise e

let append_turn ~base_dir ~keeper_name ~(role : Keeper_chat_role.t) ~content ~ts
    ?attachments ?tool_call_id ?tool_call_name ?source ?conversation_id
    ?external_message_id ?speaker ?include_redacted () =
  let redaction =
    if include_redacted = Some true then None
    else Some (redaction_for ~base_dir ~keeper_name)
  in
  let apply_redaction line =
    match redaction with
    | None -> line
    | Some r -> redact_message r line
  in
  let line = {
    role;
    content;
    ts;
    attachments;
    tool_call_id;
    tool_call_name;
    source;
    conversation_id;
    external_message_id;
    speaker;
  } in
  let json_line = encode_line_json ~role ~content ~ts ?attachments ?tool_call_id ?tool_call_name
    ?source ?conversation_id ?external_message_id ?speaker () in
  append_json_line ~base_dir ~keeper_name (apply_redaction line |> fun _ -> json_line);
  line

let append_messages ~base_dir ~keeper_name messages =
  List.iter (fun (msg : chat_message) ->
    ignore (append_turn ~base_dir ~keeper_name ~role:msg.role ~content:msg.content ~ts:msg.ts
      ?attachments:msg.attachments ?tool_call_id:msg.tool_call_id
      ?tool_call_name:msg.tool_call_name ?source:msg.source
      ?conversation_id:msg.conversation_id ?external_message_id:msg.external_message_id
      ?speaker:msg.speaker ());
  ) messages

let parse_line line =
  let json = Yojson.Safe.from_string line in
  match json with
  | `Assoc fields ->
      let field name = List.assoc_opt name fields in
      let role_str = match field "role" with
        | Some (`String r) -> r
        | _ -> failwith "parse_line: missing or non-string role"
      in
      let role = match Keeper_chat_role.of_string role_str with
        | Some r -> r
        | None -> failwith ("parse_line: unknown role: " ^ role_str)
      in
      let content = match field "content" with
        | Some (`String c) -> c
        | _ -> ""
      in
      let ts = match field "ts" with
        | Some (`Float f) -> f
        | _ -> 0.0
      in
      let attachments = match field "attachments" with
        | Some (`List items) ->
            Some (List.map (fun item ->
              match item with
              | `Assoc att_fields ->
                  let att_field n = List.assoc_opt n att_fields in
                  {
                    id = (match att_field "id" with Some (`String s) -> s | _ -> "");
                    att_type = (match att_field "att_type" with Some (`String s) -> s | _ -> "");
                    name = (match att_field "name" with Some (`String s) -> s | _ -> "");
                    size = (match att_field "size" with Some (`Int i) -> i | _ -> 0);
                    mime_type = (match att_field "mime_type" with Some (`String s) -> s | _ -> "");
                    data = (match att_field "data" with Some (`String s) -> s | _ -> "");
                  }
              | _ -> failwith "parse_line: non-assoc attachment"
            ) items)
        | _ -> None
      in
      let tool_call_id = match field "tool_call_id" with
        | Some (`String s) -> Some s | _ -> None
      in
      let tool_call_name = match field "tool_call_name" with
        | Some (`String s) -> Some s | _ -> None
      in
      let source = match field "source" with
        | Some (`String s) -> Some s | _ -> None
      in
      let conversation_id = match field "conversation_id" with
        | Some (`String s) -> Some s | _ -> None
      in
      let external_message_id = match field "external_message_id" with
        | Some (`String s) -> Some s | _ -> None
      in
      let speaker = match field "speaker_id", field "speaker_name", field "speaker_authority" with
        | _, _, Some (`String auth) ->
            Some {
              speaker_id = (match field "speaker_id" with Some (`String s) -> Some s | _ -> None);
              speaker_name = (match field "speaker_name" with Some (`String s) -> Some s | _ -> None);
              speaker_authority = (match authority_of_label auth with Some a -> a | None -> External);
            }
        | _ -> None
      in
      {
        role;
        content;
        ts = Some ts;
        attachments;
        tool_call_id;
        tool_call_name;
        source;
        conversation_id;
        external_message_id;
        speaker;
      }
  | _ -> failwith "parse_line: expected JSON object"

let load_aux ~base_dir ~keeper_name ~f =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let rec loop acc =
      match try Some (input_line ic) with End_of_file -> None with
      | None -> close_in ic; List.rev acc
      | Some line when String.trim line = "" -> loop acc
      | Some line ->
          begin match try Some (parse_line line) with _ -> None with
          | Some msg -> loop (msg :: acc)
          | None -> loop acc
          end
    in
    loop []

let load ~base_dir ~keeper_name ?role_filter () =
  let messages = load_aux ~base_dir ~keeper_name ~f:(fun x -> x) in
  match role_filter with
  | None -> messages
  | Some filter ->
      List.filter (fun (msg : chat_message) ->
        Keeper_chat_role.RoleSet.mem msg.role filter
      ) messages

let load_page ~base_dir ~keeper_name ~page_size ~page ?role_filter () =
  let all_messages = load ~base_dir ~keeper_name ?role_filter () in
  let total = List.length all_messages in
  let start = (page - 1) * page_size in
  let page_messages =
    if start >= total then []
    else
      let take = min page_size (total - start) in
      let rec take_range acc i lst =
        if i >= start + take then List.rev acc
        else match lst with
          | [] -> List.rev acc
          | hd :: tl ->
              if i >= start then take_range (hd :: acc) (i + 1) tl
              else take_range acc (i + 1) tl
      in
      take_range [] 0 all_messages
  in
  {
    Keeper_chat_types.page_messages = page_messages;
    page_total = total;
    page_page = page;
    page_page_size = page_size;
    page_has_next = (start + page_size) < total;
  }