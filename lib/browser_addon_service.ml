module W = Browser_addon_wire
module Owner = Browser_addon_owner
module Server = Mcp_protocol_eio.Server
module S = Mcp_protocol.Mcp_types

let refusal disposition message = W.Service_refusal {disposition;message}
let decode text =
  match Yojson.Safe.from_string text with
  | value -> W.of_json value
  | exception Yojson.Json_error message -> Error message
let handle owner raw =
  match decode raw with
  | Error message -> refusal W.Not_started message
  | Ok request ->
    match Owner.dispatch owner request with
    | reply -> reply
    | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
    | exception exn ->
      (* At the process edge an unexpected exception may follow browser input.
         It cannot establish a pre-effect refusal or authorize replay. *)
      Printf.eprintf "browser addon request failed: %s\n%!" (Printexc.to_string exn);
      refusal W.Outcome_unknown "browser worker request failed; outcome unknown"
let check_path socket_path =
  let parent = Filename.dirname socket_path in
  if Filename.is_relative socket_path ||
     not (String.equal (Unix.realpath parent) parent) ||
     not (String.equal (Filename.concat parent (Filename.basename socket_path)) socket_path)
  then invalid_arg "browser socket must have an absolute canonical path";
  let info = Unix.lstat parent in
  if info.Unix.st_kind <> Unix.S_DIR || info.Unix.st_uid <> Unix.geteuid () || info.Unix.st_perm <> 0o700 then
    invalid_arg "browser socket parent must be worker-owned with mode 0700";
  match Unix.lstat socket_path with
  | _ -> invalid_arg "browser socket path already exists"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let serve ~net ~owner ~socket_path ~max_message_bytes =
  Eio.Switch.run (fun sw ->
  if max_message_bytes <= 0 || max_message_bytes >= Sys.max_string_length then
    invalid_arg "invalid browser transport bound";
  check_path socket_path;
  Eio.Switch.check sw;
  let socket = Eio.Net.listen ~sw ~backlog:(Int32.to_int Int32.max_int) net (`Unix socket_path) in
  let on_error exn = Printf.eprintf "browser addon connection failed: %s\n%!" (Printexc.to_string exn) in
  while true do
    Eio.Switch.check sw;
    Eio.Net.accept_fork ~sw socket ~on_error (fun flow _address ->
      let reader = Eio.Buf_read.of_flow flow ~initial_size:(min 4096 (max_message_bytes+1))
        ~max_size:(max_message_bytes+1) in
      let reply = match Eio.Buf_read.line reader with
        | raw when String.length raw <= max_message_bytes -> handle owner raw
        | _ -> refusal W.Not_started "browser request exceeds installation transport bound"
        | exception Eio.Buf_read.Buffer_limit_exceeded ->
          refusal W.Not_started "browser request exceeds installation transport bound"
        | exception End_of_file -> refusal W.Not_started "incomplete browser request" in
      let text = Yojson.Safe.to_string (W.reply_to_json reply) in
      let text = if String.length text <= max_message_bytes then text else
        Yojson.Safe.to_string (W.reply_to_json (refusal W.Outcome_unknown
          "browser reply exceeds installation transport bound; outcome unknown")) in
      if String.length text <= max_message_bytes then
        Eio.Flow.copy_string (text ^ "\n") flow)
  done)
let mcp owner =
  let model_ports server =
    if not (Owner.models_enabled owner) then server else
    let add server name command = Server.tool name
      ~description:"Private model host broker; never export to a model."
      ~input_schema:(`Assoc ["type",`String "object"]) (fun _context _name arguments ->
        let command=command (Option.value ~default:(`Assoc []) arguments) in
        match Owner.dispatch owner {W.incarnation=Owner.incarnation owner;command} with
        | W.Model_reply value -> Ok {S.content=[];is_error=Some false;structured_content=Some value;_meta=None}
        | W.Service_refusal {message;_} -> Error message
        | Snapshot_result _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> Error "unexpected model broker reply") server in
    add server Lane_addon_types.host_requests_tool (fun _ -> W.Model_requests)
    |> fun server -> add server Lane_addon_types.host_result_tool (fun arguments -> W.Model_result arguments) in
  let schema = `Assoc ["type",`String "object";"properties",`Assoc [
    "binding",`Assoc ["type",`String "object"];
    "sources",`Assoc ["type",`String "array"]]] in
  Server.create ~name:"masc-browser-addon" ~version:"0.1.0" ()
  |> model_ports
  |> Server.add_tool Browser_addon_tool.definition (fun _context _name arguments ->
    Ok (Browser_addon_tool.invoke ~owner ~principal:Lane_addon_call_context.Anonymous
      (Option.value ~default:(`Assoc []) arguments)))
  |> Server.tool Lane_addon_call_context.tool_name
    ~description:"Private host caller-context port; never export it to a model."
    ~input_schema:Lane_addon_call_context.input_schema (fun _context _name arguments ->
      let call=match arguments with None -> Error "host caller context is required"
        | Some arguments -> Lane_addon_call_context.of_json arguments in
      match call with
      | Ok call when call.tool=Browser_addon_tool.definition.name && Option.is_none call.controller ->
          Ok (Browser_addon_tool.invoke ~owner ~principal:call.principal call.arguments)
      | Ok _|Error _ -> Ok (Browser_addon_tool.invoke ~owner ~principal:Lane_addon_call_context.Anonymous (`Assoc [])))
  |> Server.tool "lane_observe" ~description:"Read the browser worker's connection and input activity snapshot."
    ~input_schema:schema (fun _context _name _arguments ->
      match Browser_addon_observation.of_snapshot ~observed_at:(Time_compat.now ()) (Owner.snapshot owner) with
      | Error detail -> Error detail
      | Ok output -> Ok {S.content=[];is_error=Some false;
          structured_content=Some (Lane_addon_types.output_to_json output);_meta=None})
