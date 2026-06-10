(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read","source":"dashboard"} v}

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
  role : string;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_call_id : string option;
  tool_call_name : string option;
  source : string option;
  speaker : speaker option;
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

let encode_line ~role ~content ~ts ?attachments ?tool_call_id ?tool_call_name
    ?source ?speaker () : string =
  let base_fields = [
    ("role", `String role);
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  let attachment_fields =
    match attachments with
    | None | Some [] -> []
    | Some atts ->
        let att_json = List.map (fun att ->
          `Assoc [
            ("id", `String att.id);
            ("type", `String att.att_type);
            ("name", `String att.name);
            ("size", `Int att.size);
            ("mime_type", `String att.mime_type);
            ("data", `String att.data);
          ]
        ) atts in
        [("attachments", `List att_json)]
  in
  let all_fields =
    base_fields
    @ attachment_fields
    @ opt_string_field "tool_call_id" tool_call_id
    @ opt_string_field "tool_call_name" tool_call_name
    @ opt_string_field "source" source
    @ speaker_fields speaker
  in
  Yojson.Safe.to_string (`Assoc all_fields)

(* Tool calls with empty accumulated arguments are normalised to "{}" so
   every persisted line keeps a non-empty [content] (the read-side
   validity check and the dashboard history mapping both require it). *)
let normalize_tool_args args =
  if String.trim args = "" then "{}" else args

let normalize_tool_call_id ~position call_id =
  if String.trim call_id = "" then Printf.sprintf "tc-%d" position else call_id

let append_turn ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ?(tool_calls = []) ?source ?speaker
    ~(assistant_content : string) () =
  try
    ensure_dir_once ~base_dir;
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    (* Speaker identity belongs to the user line only: tool and
       assistant lines are the keeper's own output. *)
    let user_line =
      encode_line ~role:"user" ~content:user_content ~ts
        ~attachments:user_attachments ?source ?speaker ()
    in
    let tool_lines =
      List.mapi
        (fun position tc ->
          encode_line ~role:"tool"
            ~content:(normalize_tool_args tc.args)
            ~ts
            ~tool_call_id:(normalize_tool_call_id ~position tc.call_id)
            ~tool_call_name:tc.call_name
            ?source ())
        tool_calls
    in
    let asst_line =
      encode_line ~role:"assistant" ~content:assistant_content ~ts ?source ()
    in
    let payload =
      String.concat "\n" ((user_line :: tool_lines) @ [ asst_line ]) ^ "\n"
    in
    Fs_compat.append_file path payload
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn)

let parse_line ~file_path (line : string) : chat_message option =
  try
    let json = Yojson.Safe.from_string line in
    let role = Json_util.get_string_with_default json ~key:"role" ~default:"" in
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    let ts =
      (try Some ((match Json_util.assoc_member_opt "ts" json with Some (`Float f) -> f | _ -> 0.0))
       with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None) in
    let opt_string key =
      match Json_util.assoc_member_opt key json with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None
    in
    let tool_call_id = opt_string "tool_call_id" in
    let tool_call_name = opt_string "tool_call_name" in
    let source = opt_string "source" in
    let speaker =
      let speaker_id = opt_string "speaker_id" in
      let speaker_name = opt_string "speaker_name" in
      match opt_string "speaker_authority" with
      | Some label -> (
          match authority_of_label label with
          | Some speaker_authority ->
              Some { speaker_id; speaker_name; speaker_authority }
          | None ->
              (* Unknown authority label: surface it instead of guessing
                 a class; the row itself stays valid. *)
              report_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path:file_path
                ~detail:
                  (Printf.sprintf "unknown speaker_authority %S" label);
              None)
      | None ->
          (match speaker_id, speaker_name with
           | None, None -> ()
           | _ ->
               (* id/name without an authority class never comes from our
                  writer; report so the producer gets fixed. *)
               report_persistence_read_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path:file_path
                 ~detail:"speaker_id/speaker_name without speaker_authority");
          None
    in
    let attachments =
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
    in
    if role = "" || content = "" then (
      report_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
        ~path:file_path
        ~detail:"chat row missing non-empty role/content";
      None)
    else if role = "tool" && tool_call_name = None then (
      report_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
        ~path:file_path
        ~detail:"tool chat row missing non-empty tool_call_name";
      None)
    else
      Some
        { role; content; ts; attachments; tool_call_id; tool_call_name;
          source; speaker }
  with Yojson.Json_error detail ->
    report_persistence_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path:file_path
      ~detail;
    None

(* Window bounds for [load]. [max_history] counts user/assistant
   messages only, so tool lines never shrink the visible conversation
   depth. [max_total_lines] is the absolute guard (tool lines included)
   against a pathological tool-spam turn blowing up the payload. *)
let max_history = 100
let max_total_lines = 400

let is_tool_message (msg : chat_message) = String.equal msg.role "tool"

(* A turn is persisted as user, tool*, assistant. Evicting the front of
   the window can leave tool lines whose owning user line is gone;
   render-wise they are orphans, so trim them. *)
let rec drop_leading_tool_messages = function
  | msg :: rest when is_tool_message msg -> drop_leading_tool_messages rest
  | messages -> messages

let load ~base_dir ~keeper_name : chat_message list =
  let path = chat_path ~base_dir ~keeper_name in
  if not (Sys.file_exists path) then []
  else
  try
    let content = Fs_compat.load_file path in
    let lines = String.split_on_char '\n' content in
    (* Single pass: keep a running window of the last [max_history]
       user/assistant messages plus their tool lines. *)
    let q = Queue.create () in
    let primary_count = ref 0 in
    let pop_front () =
      let popped = Queue.pop q in
      if not (is_tool_message popped) then decr primary_count
    in
    List.iter
      (fun line ->
        let trimmed = String.trim line in
        if trimmed <> "" then
          match parse_line ~file_path:path trimmed with
          | Some msg ->
              Queue.push msg q;
              if not (is_tool_message msg) then incr primary_count;
              while
                !primary_count > max_history
                || Queue.length q > max_total_lines
              do
                pop_front ()
              done
          | None -> ())
      lines;
    Queue.fold (fun acc msg -> msg :: acc) [] q
    |> List.rev
    |> drop_leading_tool_messages
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
              @ opt_string_field "tool_call_id" m.tool_call_id
              @ opt_string_field "tool_call_name" m.tool_call_name
              @ opt_string_field "source" m.source
              @ speaker_fields m.speaker
              @ (match m.attachments with
                 | None | Some [] -> []
                 | Some atts ->
                     let att_json = List.map (fun att ->
                       `Assoc [
                         ("id", `String att.id);
                         ("type", `String att.att_type);
                         ("name", `String att.name);
                         ("size", `Int att.size);
                         ("mime_type", `String att.mime_type);
                         ("data", `String att.data);
                       ]
                     ) atts in
                     [("attachments", `List att_json)])))
       messages)
