let ( let* ) = Result.bind

type failure =
  | Did_not_start of Process_eio.spawn_refusal
  | Command_failed of string
  | Unreadable_output of string

type error =
  { argv : string list
  ; failure : failure
  }

let failure_to_string = function
  | Did_not_start refusal -> "did not start: " ^ Process_eio.spawn_refusal_to_string refusal
  | Command_failed detail -> detail
  | Unreadable_output detail -> "printed output MASC cannot read: " ^ detail
;;

(* Each command took 0.13 s on 2026-11-27 (muse 1.4.25, one plugin). The
   deadlines keep a host start from waiting forever on a hung command or an
   unbounded number of installed plugins. *)
let command_deadline_s = 30.0
let total_deadline_s = 60.0
let max_stdout_bytes = 1024 * 1024
let stderr_excerpt_bytes = 512
let stderr_capture_bytes = 4096
let max_plugins = 64

exception Output_too_large

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let parse_json text =
  match Yojson.Safe.from_string text with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error ("not JSON: " ^ detail)
;;

(* The first entry that does not read decides: one unreadable entry means the
   output is not the shape this module was checked against. *)
let read_each ~list_name read entries =
  let rec go index acc = function
    | [] -> Ok (List.rev acc)
    | entry :: rest ->
      (match read entry with
       | Ok value -> go (index + 1) (value :: acc) rest
       | Error detail -> Error (Printf.sprintf "%s[%d] %s" list_name index detail))
  in
  go 0 [] entries
;;

let non_empty_string = function
  | Some (`String text) when text <> "" -> Some text
  | Some
      ( `Null
      | `Bool _
      | `Int _
      | `Intlit _
      | `Float _
      | `String _
      | `Assoc _
      | `List _ )
  | None -> None
;;

let has_control_or_whitespace text =
  String.exists
    (fun c ->
       let code = Char.code c in
       code <= 0x20 || code = 0x7f)
    text
;;

let is_valid_plugin_id text =
  text <> "" && text.[0] <> '-' && not (has_control_or_whitespace text)
;;

let is_valid_capability_id text =
  text <> ""
  && not (String.contains text '=')
  && not (has_control_or_whitespace text)
;;

let list_field name json =
  match field name json with
  | Some (`List entries) -> Ok entries
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) | None ->
    Error (name ^ " is not a list")
;;

let plugin_ids_of_list text =
  let* json = parse_json text in
  let* plugins = list_field "plugins" json in
  read_each
    ~list_name:"plugins"
    (fun plugin ->
       match Option.bind (field "record" plugin) (fun record -> non_empty_string (field "id" record)) with
       | None -> Error "has no non-empty string id"
       | Some id when not (is_valid_plugin_id id) -> Error "has invalid plugin id"
       | Some id -> Ok id)
    plugins
;;

let capability_ids_of_inspect text =
  let* json = parse_json text in
  let* capabilities = list_field "runtime_capabilities" json in
  read_each
    ~list_name:"runtime_capabilities"
    (fun capability ->
       match
         Option.bind (field "candidate" capability) (fun candidate ->
           non_empty_string (field "stable_id" candidate))
       with
       | None -> Error "has no non-empty string id"
       | Some id when not (is_valid_capability_id id) -> Error "has invalid capability stable_id"
       | Some id -> Ok id)
    capabilities
;;

let exit_status_to_string = function
  | `Exited code -> Printf.sprintf "exited with status %d" code
  | `Signaled signal -> Printf.sprintf "ended by signal %d" signal
;;

let read_stdout_bounded ~max_bytes flow =
  let buf = Buffer.create 4096 in
  let chunk = Cstruct.create 4096 in
  let rec loop () =
    match Eio.Flow.single_read flow chunk with
    | n ->
      if Buffer.length buf + n > max_bytes then raise Output_too_large;
      Buffer.add_string buf (Cstruct.to_string ~off:0 ~len:n chunk);
      loop ()
    | exception End_of_file -> Buffer.contents buf
  in
  loop ()
;;

let drain_stderr_into ~capture_bytes buf flow =
  let chunk = Cstruct.create 4096 in
  let rec loop () =
    match Eio.Flow.single_read flow chunk with
    | n ->
      let remaining = capture_bytes - Buffer.length buf in
      if remaining > 0
      then Buffer.add_string buf (Cstruct.to_string ~off:0 ~len:(Int.min n remaining) chunk);
      loop ()
    | exception End_of_file -> ()
  in
  loop ()
;;

(* stdout and stderr are drained concurrently under the inner switch with
   bounded memory so a chatty child cannot exhaust memory or block on a full
   stderr pipe. A deadline cancels that switch, which ends the child. Any
   other exception the run raises (a reaper failure re-raised by [await],
   several fibers failing at once) is a failed command, so the host start
   returns it instead of raising; cancellation and the other reserved
   exceptions still propagate. *)
let run ~proc_mgr ~clock ?cwd ~env ~deadline_s argv =
  let stderr = Buffer.create 256 in
  let failed detail =
    let detail =
      match String.trim (Buffer.contents stderr) with
      | "" -> detail
      | text ->
        Printf.sprintf
          "%s; stderr: %s"
          detail
          (String_util.utf8_prefix ~max_bytes:stderr_excerpt_bytes text)
    in
    Error { argv; failure = Command_failed detail }
  in
  if deadline_s <= 0.0
  then failed (Printf.sprintf "still running after %.0f s" total_deadline_s)
  else
    match
      Eio.Time.with_timeout clock deadline_s (fun () ->
        Eio.Switch.run (fun sw ->
          match Process_eio.spawn_piped_child ~sw proc_mgr ?cwd ~env argv with
          | Error refusal -> Ok (Error refusal)
          | Ok child ->
            Eio.Flow.close child.to_stdin;
            let stdout_text, () =
              Eio.Fiber.pair
                (fun () ->
                   read_stdout_bounded ~max_bytes:max_stdout_bytes child.from_stdout)
                (fun () ->
                   drain_stderr_into ~capture_bytes:stderr_capture_bytes stderr child.from_stderr)
            in
            Ok (Ok (Eio.Process.await child.process, stdout_text))))
    with
    | Ok (Ok (`Exited 0, stdout_text)) -> Ok stdout_text
    | Ok (Ok (((`Exited _ | `Signaled _) as status), _)) -> failed (exit_status_to_string status)
    | Ok (Error refusal) -> Error { argv; failure = Did_not_start refusal }
    | Error `Timeout -> failed (Printf.sprintf "still running after %.0f s" deadline_s)
    | exception Output_too_large ->
      failed (Printf.sprintf "stdout exceeded %d bytes" max_stdout_bytes)
    | exception exn ->
      Llm_provider.Reserved_exn.reraise_if_reserved exn;
      failed (Printexc.to_string exn)
;;

let read_output argv parse output =
  Result.map_error (fun detail -> { argv; failure = Unreadable_output detail }) (parse output)
;;

let installed_capability_ids ~proc_mgr ~clock ?cwd ~env ~cli_path () =
  let deadline_at = Eio.Time.now clock +. total_deadline_s in
  let remaining_deadline () =
    Float.min command_deadline_s (deadline_at -. Eio.Time.now clock)
  in
  let run_bounded argv =
    run ~proc_mgr ~clock ?cwd ~env ~deadline_s:(remaining_deadline ()) argv
  in
  let list_argv = [ cli_path; "plugins"; "list"; "--json" ] in
  let* listed = run_bounded list_argv in
  let* plugin_ids = read_output list_argv plugin_ids_of_list listed in
  let* () =
    if List.length plugin_ids > max_plugins
    then
      Error
        { argv = list_argv
        ; failure =
            Unreadable_output
              (Printf.sprintf
                 "plugins list exceeded %d entries (%d)"
                 max_plugins
                 (List.length plugin_ids))
        }
    else Ok ()
  in
  let rec inspect_each acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | plugin_id :: rest ->
      let inspect_argv = [ cli_path; "plugins"; "inspect"; plugin_id; "--json" ] in
      let* inspected = run_bounded inspect_argv in
      let* ids = read_output inspect_argv capability_ids_of_inspect inspected in
      inspect_each (ids :: acc) rest
  in
  inspect_each [] plugin_ids
;;
