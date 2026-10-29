module W = Browser_addon_wire
module Owner = Browser_addon_owner
module Server = Mcp_protocol_eio.Server
module S = Mcp_protocol.Mcp_types

let refusal disposition message = W.Service_refusal {disposition;message}
let decode text =
  match Yojson.Safe.from_string text with
  | value -> W.of_json value
  | exception Yojson.Json_error _ -> Error "invalid browser worker JSON"
let handle_dispatch ~dispatch request =
    match dispatch request with
    | reply -> reply
    | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
    | exception _ ->
      (* At the process edge an unexpected exception may follow browser input.
         It cannot establish a pre-effect refusal or authorize replay. *)
      Printf.eprintf "browser addon request failed; outcome unknown\n%!";
      refusal W.Outcome_unknown "browser worker request failed; outcome unknown"
(* Unlike [Buf_read.line], retain whether EOF arrived before the terminator.
   Unwatched requests keep the old EOF-terminated framing behaviour. *)
let read_frame reader =
  let raw = Eio.Buf_read.take_while (fun c -> c <> '\n') reader in
  match Eio.Buf_read.peek_char reader with
  | None -> raw, false
  | Some _ ->
    Eio.Buf_read.char '\n' reader;
    let length = String.length raw in
    let raw = if length > 0 && raw.[length - 1] = '\r'
      then String.sub raw 0 (length - 1) else raw in
    raw, true

type watched_decision = Finished of W.reply | Abandoned

let handle_watched_with_hook ~before_observation ~dispatch reader request =
  (* The branch that returns first decides. Both decide without yielding, on
     the same Eio domain. Completion checks bytes read by the watcher before it
     commits. Bytes not yet read from the kernel have no observed ordering. *)
  let decision =
    Eio.Fiber.first
      (fun () ->
        let reply = dispatch request in
        if Eio.Buf_read.buffered_bytes reader > 0 then Abandoned else Finished reply)
      (fun () ->
        (match Eio.Buf_read.peek_char reader with
         | None | Some _ -> ()
         | exception Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _) -> ());
        before_observation ();
        Abandoned)
  in
  match decision with
  | Finished reply -> Some reply
  | Abandoned -> None
let handle_watched ~dispatch reader request =
  handle_watched_with_hook ~before_observation:(fun () -> ()) ~dispatch reader request
let read_request ~dispatch ~reader ~max_message_bytes =
  match read_frame reader with
  | "", false -> Some (refusal W.Not_started "incomplete browser request")
  | raw, terminated when String.length raw <= max_message_bytes ->
    (match decode raw with
     | Error message -> Some (refusal W.Not_started message)
     | Ok request when W.ends_with_caller request.command ->
       if not terminated || Eio.Buf_read.buffered_bytes reader > 0 then None
       else handle_watched ~dispatch reader request
     | Ok request -> Some (dispatch request))
  | _ -> Some (refusal W.Not_started "browser request exceeds installation transport bound")
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
    Some (refusal W.Not_started "browser request exceeds installation transport bound")
  | exception End_of_file -> Some (refusal W.Not_started "incomplete browser request")

let check_path socket_path =
  let parent = Filename.dirname socket_path in
  if Filename.is_relative socket_path ||
     not (String.equal (Unix.realpath parent) parent) ||
     not (String.equal (Filename.concat parent (Filename.basename socket_path)) socket_path)
  then invalid_arg "browser socket must have an absolute canonical path";
  let info = Unix.lstat parent in
  (match Resource_requirement.check ~label:"browser socket parent"
           Resource_requirement.private_directory ~path:parent info with
   | Ok () -> ()
   | Error detail -> invalid_arg detail);
  match Unix.lstat socket_path with
  | _ -> invalid_arg "browser socket path already exists"
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let serve_with_dispatch ~net ~dispatch ~on_error ~before_write ~socket_path ~max_message_bytes =
  Eio.Switch.run (fun sw ->
  if max_message_bytes <= 0 || max_message_bytes > Sys.max_string_length - 2 then
    invalid_arg "invalid browser transport bound";
  check_path socket_path;
  Eio.Switch.check sw;
  let socket = Eio.Net.listen ~sw ~backlog:(Int32.to_int Int32.max_int) net (`Unix socket_path) in
  while true do
    Eio.Switch.check sw;
    Eio.Net.accept_fork ~sw socket ~on_error (fun flow _address ->
      (* The payload limit excludes the terminator; CRLF needs two bytes. *)
      let reader = Eio.Buf_read.of_flow flow ~initial_size:(min 4096 (max_message_bytes+2))
        ~max_size:(max_message_bytes+2) in
      let reply = read_request ~dispatch:(handle_dispatch ~dispatch) ~reader ~max_message_bytes in
      match reply with
      | None -> Printf.eprintf "browser addon caller left or violated framing; request cancelled\n%!"
      | Some reply ->
      before_write ();
      let text = Yojson.Safe.to_string (W.reply_to_json reply) in
      let text = if String.length text <= max_message_bytes then text else
        Yojson.Safe.to_string (W.reply_to_json (refusal W.Outcome_unknown
          "browser reply exceeds installation transport bound; outcome unknown")) in
      if String.length text <= max_message_bytes then
        Eio.Flow.copy_string (text ^ "\n") flow)
  done)
let serve ~net ~owner ~socket_path ~max_message_bytes =
  serve_with_dispatch ~net ~dispatch:(Owner.dispatch owner)
    ~on_error:(fun _ -> Printf.eprintf "browser addon connection failed\n%!")
    ~before_write:(fun () -> ())
    ~socket_path ~max_message_bytes

module For_testing = struct
  let read_request = read_request
  let handle_watched = handle_watched
  let handle_watched_with_hook = handle_watched_with_hook
  let handle_dispatch = handle_dispatch
  let serve_with_dispatch = serve_with_dispatch
end
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
        | Snapshot_result _|Extension_reply _|Download_reply _|Poll_result _|Receipt|Issue_result _ -> Error "unexpected model broker reply") server in
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
  |> Server.tool Lane_addon_types.operator_tool
    ~description:"Private operator input-reset assertion; never export to a model."
    ~input_schema:Owner.operator_schema (fun _context _name arguments ->
      match Owner.operator owner (Option.value ~default:(`Assoc []) arguments) with
      | Error _ -> Error "browser operator controls unavailable"
      | Ok value -> Ok {S.content=[];is_error=Some false;structured_content=Some value;_meta=None})
  |> Server.tool "lane_observe" ~description:"Read the browser worker's connection and input activity snapshot."
    ~input_schema:schema (fun _context _name _arguments ->
      match Browser_addon_observation.of_snapshot ~observed_at:(Time_compat.now ()) (Owner.snapshot owner) with
      | Error detail -> Error detail
      | Ok output -> Ok {S.content=[];is_error=Some false;
          structured_content=Some (Lane_addon_types.output_to_json output);_meta=None})
