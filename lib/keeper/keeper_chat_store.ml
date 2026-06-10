(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Text line format:
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call line format:
    {v {"role":"tool_call","content":"","tool_calls":[{"tool_call_id":"call-1","name":"keeper_task_claim","arguments":"{}"}],"ts":1774000000.0} v}

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

type tool_call_data = {
  tool_call_id : string;
  name : string;
  arguments : string;
}

type chat_message = {
  role : string;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_calls : tool_call_data list option;
}

let encode_attachments atts =
  `List
    (List.map
       (fun att ->
         `Assoc
           [
             ("id", `String att.id);
             ("type", `String att.att_type);
             ("name", `String att.name);
             ("size", `Int att.size);
             ("mime_type", `String att.mime_type);
             ("data", `String att.data);
           ])
       atts)

let encode_tool_calls calls =
  `List
    (List.map
       (fun call ->
         `Assoc
           [
             ("tool_call_id", `String call.tool_call_id);
             ("name", `String call.name);
             ("arguments", `String call.arguments);
           ])
       calls)

let encode_line ~role ~content ~ts ?attachments ?tool_calls () : string =
  let base_fields = [
    ("role", `String role);
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  let all_fields =
    match attachments with
    | None | Some [] -> base_fields
    | Some atts -> ("attachments", encode_attachments atts) :: base_fields
  in
  let all_fields =
    match tool_calls with
    | None | Some [] -> all_fields
    | Some calls -> ("tool_calls", encode_tool_calls calls) :: all_fields
  in
  Yojson.Safe.to_string (`Assoc all_fields)

let append_pair ~base_dir ~keeper_name
    ~(user_content : string) ~(assistant_content : string) ~(user_attachments : attachment list) =
  try
    ensure_dir_once ~base_dir;
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let user_line = encode_line ~role:"user" ~content:user_content ~ts ~attachments:user_attachments () in
    let asst_line = encode_line ~role:"assistant" ~content:assistant_content ~ts () in
    Fs_compat.append_file path (user_line ^ "\n" ^ asst_line ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

let append_tool_call ~base_dir ~keeper_name ~(tool_call_id : string)
    ~(name : string) ~(arguments : string) =
  try
    ensure_dir_once ~base_dir;
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let call = { tool_call_id; name; arguments } in
    let line =
      encode_line ~role:"tool_call" ~content:"" ~ts
        ~tool_calls:[call] ()
    in
    Fs_compat.append_file path (line ^ "\n")
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: append_tool_call failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

let parse_tool_calls json =
  let from_tool_calls_array =
    match Json_util.assoc_member_opt "tool_calls" json with
    | Some (`List items) ->
        let parsed =
          List.filter_map
            (function
              | `Assoc _ as item ->
                  let tool_call_id =
                    Json_util.get_string_with_default item ~key:"tool_call_id" ~default:""
                  in
                  let name =
                    Json_util.get_string_with_default item ~key:"name" ~default:""
                  in
                  let arguments =
                    Json_util.get_string_with_default item ~key:"arguments" ~default:""
                  in
                  if tool_call_id = "" then None
                  else Some { tool_call_id; name; arguments }
              | _ -> None)
            items
        in
        if parsed = [] then None else Some parsed
    | _ -> None
  in
  match from_tool_calls_array with
  | Some _ as calls -> calls
  | None ->
      let tool_call_id =
        Json_util.get_string_with_default json ~key:"tool_call_id" ~default:""
      in
      if tool_call_id = "" then None
      else
        let name =
          Json_util.get_string_with_default json ~key:"name" ~default:""
        in
        let arguments =
          Json_util.get_string_with_default json ~key:"arguments" ~default:""
        in
        Some [{ tool_call_id; name; arguments }]

let parse_attachments json =
  match Json_util.assoc_member_opt "attachments" json with
  | Some (`List att_list) ->
      let atts = List.filter_map (fun att_json ->
        match att_json with
        | `Assoc _ ->
            (try
              let id = Json_util.get_string_with_default att_json ~key:"id" ~default:"" in
              let att_type = Json_util.get_string_with_default att_json ~key:"type" ~default:"" in
              let name = Json_util.get_string_with_default att_json ~key:"name" ~default:"" in
              let size = (match Json_util.assoc_member_opt "size" att_json with
                | Some (`Int i) -> i | _ -> 0) in
              let mime_type = Json_util.get_string_with_default att_json ~key:"mime_type" ~default:"" in
              let data = Json_util.get_string_with_default att_json ~key:"data" ~default:"" in
              if id = "" || data = "" then None
              else Some { id; att_type; name; size; mime_type; data }
            with _ -> None)
        | _ -> None
      ) att_list in
      if atts = [] then None else Some atts
  | _ -> None

let parse_line ~file_path (line : string) : chat_message option =
  try
    let json = Yojson.Safe.from_string line in
    let role = Json_util.get_string_with_default json ~key:"role" ~default:"" in
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    let tool_calls = parse_tool_calls json in
    let ts =
      (try Some ((match Json_util.assoc_member_opt "ts" json with Some (`Float f) -> f | _ -> 0.0))
       with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None) in
    let attachments = parse_attachments json in
    if role = "" || (content = "" && tool_calls = None) then (
      report_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
        ~path:file_path
        ~detail:"chat row missing non-empty role/content or tool_calls";
      None)
    else Some { role; content; ts; attachments; tool_calls }
  with Yojson.Json_error detail ->
    report_persistence_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path:file_path
      ~detail;
    None

let max_history = 100

let load ~base_dir ~keeper_name : chat_message list =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then []
  else
  try
    let content = Fs_compat.load_file path in
    let lines = String.split_on_char '\n' content in
    (* Single pass: keep a running window of last max_history entries *)
    let q = Queue.create () in
    List.iter
      (fun line ->
        let trimmed = String.trim line in
        if trimmed <> "" then
          match parse_line ~file_path:path trimmed with
          | Some msg ->
              Queue.push msg q;
              if Queue.length q > max_history then ignore (Queue.pop q)
          | None -> ())
      lines;
    Queue.fold (fun acc msg -> msg :: acc) [] q |> List.rev
  with
  | Sys_error detail ->
      report_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
        ~path
        ~detail;
      []
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ChatStoreFailures)
        ~labels:[("operation", Keeper_chat_store_operation.(to_label Load))]
        ();
      Log.Keeper.warn "keeper_chat_store: load failed for %s: %s"
        (sanitize_name keeper_name) (Printexc.to_string exn);
      []

let to_json_array (messages : chat_message list) : Yojson.Safe.t =
  `List
    (List.map
       (fun m ->
         `Assoc
           ([ ("role", `String m.role);
              ("content", `String m.content);
            ] @ (match m.ts with
                 | Some t -> [("ts", `Float t)]
                 | None -> [])
              @ (match m.attachments with
                 | None | Some [] -> []
                 | Some atts -> [("attachments", encode_attachments atts)])
              @ (match m.tool_calls with
                 | None | Some [] -> []
                 | Some calls -> [("tool_calls", encode_tool_calls calls)])))
       messages)
