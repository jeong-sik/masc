(** The four spawn tools.

    RFC spawn-a-process-that-outlives-the-call §3.6. [Spawn_registry] holds the
    processes; this is the surface a caller reaches them through.

    Every failure here is a value, not an exception, and every message says
    what to do next in the sense [Subset_rewrite] established: a handle that
    names nothing says the process is gone, not that something went wrong. *)

type context = {
  registry : Spawn_registry.t;
  sw : Eio.Switch.t;
}

let ( let* ) = Result.bind

let ok ~tool_name ~start_time data = Tool_result.make_ok ~tool_name ~start_time ~data ()

let workflow_error ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let runtime_error ~tool_name ~start_time message =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:(Tool_args.error_assoc [ "message", `String message ])
    message
;;

let required_string args key =
  match Json_util.get_string args key with
  | Some value ->
    (match String_util.trim_nonempty value with
     | Some value -> Ok value
     | None -> Error (Printf.sprintf "%s must not be blank" key))
  | None -> Error (Printf.sprintf "%s is required" key)
;;

let required_number args key =
  match Json_util.get_float args key with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s is required" key)
;;

(* [get_string_list] would drop a non-string entry silently, and an argv with a
   number in it is a caller mistake worth naming rather than a shorter argv. *)
let argv_of args =
  match Json_util.get_array args "argv" with
  | None -> Error "argv is required"
  | Some (`List items) ->
    let strings =
      List.filter_map
        (function
          | `String value -> Some value
          | _ -> None)
        items
    in
    if List.length strings <> List.length items
    then Error "every argv entry must be a string"
    else if strings = []
    then Error "argv needs a program to run"
    else Ok strings
  | Some _ -> Error "argv must be an array of strings"
;;

let stream_of args =
  (* stdout is the default because it is where a program says what it is
     doing. stderr is a deliberate ask. *)
  match Json_util.get_string args "stream" with
  | None | Some "stdout" -> Ok Spawn_registry.Stdout
  | Some "stderr" -> Ok Spawn_registry.Stderr
  | Some other -> Error (Printf.sprintf "stream must be stdout or stderr, got %S" other)
;;

let offset_of args =
  match Json_util.get_int args "from" with
  | None -> Ok 0
  | Some value when value >= 0 -> Ok value
  | Some value -> Error (Printf.sprintf "from must not be negative, got %d" value)
;;

(* A handle that names nothing is an ordinary answer. The message says the
   process is gone rather than that the call failed, because those lead a
   caller to different next moves: one spawns again, the other retries. *)
let gone handle =
  Printf.sprintf
    "no process is held under %s. It ended with the turn that spawned it, or \
     the handle came from an earlier one -- spawn again to get a live handle."
    (Spawn_handle.to_string handle)
;;

let handle_of args =
  let* text = required_string args "handle" in
  match Spawn_handle.of_string text with
  | Some handle -> Ok handle
  | None -> Error (Printf.sprintf "%S is not a handle keeper_spawn issued" text)
;;

(* [cwd] is declared in keeper_spawn.toml and was read by nobody: the word did
   not appear in this file, [Spawn_registry.spawn] took a path rather than a
   string, and the argument was simply never passed. 55 calls on 2026-09-01
   sent a cwd and every one of them ran somewhere else.

   Blank is an error rather than "use the default". A caller that sends the
   key is naming a directory, and silently substituting a different one is how
   the first version of this went wrong. *)
let cwd_of args =
  match Json_util.assoc_member_opt "cwd" args with
  | None -> Ok None
  | Some (`String value) ->
    (match String_util.trim_nonempty value with
     | Some value -> Ok (Some value)
     | None -> Error "cwd must not be blank")
  | Some _ -> Error "cwd must be a string"
;;

let handle_start ~tool_name ~start_time ctx args =
  match argv_of args with
  | Error message -> workflow_error ~tool_name ~start_time message
  | Ok argv ->
    (match cwd_of args with
     | Error message -> workflow_error ~tool_name ~start_time message
     | Ok cwd ->
    (match Spawn_registry.spawn ~sw:ctx.sw ctx.registry ?cwd argv with
     | Error message -> runtime_error ~tool_name ~start_time message
     | Ok handle ->
       ok
         ~tool_name
         ~start_time
         (`Assoc
             [ "status", `String "running"
             ; "handle", `String (Spawn_handle.to_string handle)
             ])))
;;

let handle_read ~tool_name ~start_time ctx args =
  let requested =
    let* handle = handle_of args in
    let* stream = stream_of args in
    let* from = offset_of args in
    Ok (handle, stream, from)
  in
  match requested with
  | Error message -> workflow_error ~tool_name ~start_time message
  | Ok (handle, stream, from) ->
    (match Spawn_registry.read ctx.registry handle ~stream ~from with
     | Error `Unknown_handle -> workflow_error ~tool_name ~start_time (gone handle)
     | Ok chunk ->
       ok
         ~tool_name
         ~start_time
         (`Assoc
             [ "bytes", `String chunk.Spawn_registry.bytes
             ; "next", `Int chunk.Spawn_registry.next
             ; "dropped_before", `Int chunk.Spawn_registry.dropped_before
             ]))
;;

let until_of args =
  let* until = required_string args "until" in
  match until with
  | "exit" -> Ok Spawn_registry.Exit
  | "output_contains" ->
    let* stream = stream_of args in
    let* needle = required_string args "needle" in
    Ok (Spawn_registry.Output_contains { stream; needle })
  | other -> Error (Printf.sprintf "until must be exit or output_contains, got %S" other)
;;

let status_json = function
  | Unix.WEXITED code -> `Assoc [ "kind", `String "exited"; "code", `Int code ]
  | Unix.WSIGNALED signal -> `Assoc [ "kind", `String "signalled"; "signal", `Int signal ]
  | Unix.WSTOPPED signal -> `Assoc [ "kind", `String "stopped"; "signal", `Int signal ]
;;

let handle_wait ~tool_name ~start_time ctx args =
  let requested =
    let* handle = handle_of args in
    let* until = until_of args in
    let* timeout_sec = required_number args "timeout_sec" in
    if timeout_sec <= 0.
    then Error "timeout_sec must be positive"
    else Ok (handle, until, timeout_sec)
  in
  match requested with
  | Error message -> workflow_error ~tool_name ~start_time message
  | Ok (handle, until, timeout_sec) ->
    (match Spawn_registry.wait ctx.registry handle ~until ~timeout_sec with
     | Error `Unknown_handle -> workflow_error ~tool_name ~start_time (gone handle)
     (* The bound is reported, never a result that happens to look plausible.
        The process is still there: read it, or wait again with a longer one. *)
     | Error `Timed_out ->
       ok
         ~tool_name
         ~start_time
         (`Assoc
             [ "status", `String "timed_out"
             ; "waited_sec", `Float timeout_sec
             ; "handle", `String (Spawn_handle.to_string handle)
             ])
     | Ok (Spawn_registry.Exited status) ->
       ok ~tool_name ~start_time (`Assoc [ "status", `String "exited"; "exit", status_json status ])
     | Ok (Spawn_registry.Matched offset) ->
       ok ~tool_name ~start_time (`Assoc [ "status", `String "matched"; "next", `Int offset ]))
;;

let handle_stop ~tool_name ~start_time ctx args =
  match handle_of args with
  | Error message -> workflow_error ~tool_name ~start_time message
  | Ok handle ->
    (match Spawn_registry.stop ctx.registry handle with
     | Error `Unknown_handle -> workflow_error ~tool_name ~start_time (gone handle)
     | Ok () -> ok ~tool_name ~start_time (`Assoc [ "status", `String "stopping" ]))
;;

let dispatch ctx ~name ~args : Tool_result.result option =
  let start_time = Time_compat.now () in
  let handle f =
    try Some (f ~tool_name:name ~start_time ctx args) with
    | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
    | exn ->
      Some
        (runtime_error
           ~tool_name:name
           ~start_time
           (Printf.sprintf "spawn tool failed: %s" (Printexc.to_string exn)))
  in
  match Tool_schemas_spawn.find_definition name with
  | Some { action = Tool_schemas_spawn.Start; _ } -> handle handle_start
  | Some { action = Tool_schemas_spawn.Read; _ } -> handle handle_read
  | Some { action = Tool_schemas_spawn.Wait; _ } -> handle handle_wait
  | Some { action = Tool_schemas_spawn.Stop; _ } -> handle handle_stop
  | None -> None
;;
