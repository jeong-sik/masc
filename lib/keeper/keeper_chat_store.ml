(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

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

type chat_message = {
  role : string;
  content : string;
  ts : float option;
  attachments : attachment list option;
}

let encode_line ~role ~content ~ts ?attachments () : string =
  let base_fields = [
    ("role", `String role);
    ("content", `String content);
    ("ts", `Float ts);
  ] in
  let all_fields =
    match attachments with
    | None | Some [] -> base_fields
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
        ("attachments", `List att_json) :: base_fields
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

let parse_line ~file_path (line : string) : chat_message option =
  try
    let json = Yojson.Safe.from_string line in
    let role = Json_util.get_string_with_default json ~key:"role" ~default:"" in
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    let ts =
      (try Some ((match Json_util.assoc_member_opt "ts" json with Some (`Float f) -> f | _ -> 0.0))
       with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None) in
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
    else Some { role; content; ts; attachments }
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
