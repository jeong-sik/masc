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
   deadline only keeps a host start from waiting forever on a hung command. *)
let command_deadline_s = 30.0
let stderr_excerpt_bytes = 512

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
       | Some value -> go (index + 1) (value :: acc) rest
       | None -> Error (Printf.sprintf "%s[%d] has no non-empty string id" list_name index))
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
    (fun plugin -> Option.bind (field "record" plugin) (fun record -> non_empty_string (field "id" record)))
    plugins
;;

let capability_ids_of_inspect text =
  let* json = parse_json text in
  let* capabilities = list_field "runtime_capabilities" json in
  read_each
    ~list_name:"runtime_capabilities"
    (fun capability ->
       Option.bind (field "candidate" capability) (fun candidate ->
         non_empty_string (field "stable_id" candidate)))
    capabilities
;;

let exit_status_to_string = function
  | `Exited code -> Printf.sprintf "exited with status %d" code
  | `Signaled signal -> Printf.sprintf "ended by signal %d" signal
;;

(* stdout and stderr are copied by fibers of the inner switch, so both
   buffers are complete once [Switch.run] returns. A deadline cancels that
   switch, which ends the child. Any other exception the run raises (a
   reaper failure re-raised by [await], several fibers failing at once) is a
   failed command, so the host start returns it instead of raising;
   cancellation and the other reserved exceptions still propagate. *)
let run ~proc_mgr ~clock ?cwd ~env argv =
  let stdout = Buffer.create 4096 in
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
  match
    Eio.Time.with_timeout clock command_deadline_s (fun () ->
      Eio.Switch.run (fun sw ->
        match
          Process_eio.spawn_child
            ~sw
            proc_mgr
            ?cwd
            ~stdin:(Eio.Flow.string_source "")
            ~stdout:(Eio.Flow.buffer_sink stdout)
            ~stderr:(Eio.Flow.buffer_sink stderr)
            ~env
            argv
        with
        | Error refusal -> Ok (Error refusal)
        | Ok child -> Ok (Ok (Eio.Process.await child))))
  with
  | Ok (Ok (`Exited 0)) -> Ok (Buffer.contents stdout)
  | Ok (Ok ((`Exited _ | `Signaled _) as status)) -> failed (exit_status_to_string status)
  | Ok (Error refusal) -> Error { argv; failure = Did_not_start refusal }
  | Error `Timeout -> failed (Printf.sprintf "still running after %.0f s" command_deadline_s)
  | exception exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    failed (Printexc.to_string exn)
;;

let read_output argv parse output =
  Result.map_error (fun detail -> { argv; failure = Unreadable_output detail }) (parse output)
;;

let installed_capability_ids ~proc_mgr ~clock ?cwd ~env ~cli_path () =
  let run = run ~proc_mgr ~clock ?cwd ~env in
  let list_argv = [ cli_path; "plugins"; "list"; "--json" ] in
  let* listed = run list_argv in
  let* plugin_ids = read_output list_argv plugin_ids_of_list listed in
  let rec inspect_each acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | plugin_id :: rest ->
      let inspect_argv = [ cli_path; "plugins"; "inspect"; plugin_id; "--json" ] in
      let* inspected = run inspect_argv in
      let* ids = read_output inspect_argv capability_ids_of_inspect inspected in
      inspect_each (ids :: acc) rest
  in
  inspect_each [] plugin_ids
;;
