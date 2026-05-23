open Keeper_types
open Keeper_exec_shared

(** Runtime helpers for keeper shell ops.

    Extracted from [keeper_shell_ops.ml] to make op handlers
    independently extractable.  All functions take previously-captured
    variables as explicit parameters. *)

(* RFC-0084: resolve coreutils from Host_config once at module-init. *)
let coreutils = (Host_config.host ()).coreutils


include Keeper_shell_render

let rewrite_turn_runtime_paths_to_host
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      text
  =
  let replace_all_substrings ~needle ~replacement text =
    let needle_len = String.length needle in
    if needle_len = 0 || not (String_util.contains_substring text needle) then text
    else
      let text_len = String.length text in
      let buf = Buffer.create text_len in
      let rec loop i =
        if i >= text_len then ()
        else if i + needle_len <= text_len
                && String.sub text i needle_len = needle then (
          Buffer.add_string buf replacement;
          loop (i + needle_len))
        else (
          Buffer.add_char buf text.[i];
          loop (i + 1))
      in
      loop 0;
      Buffer.contents buf
  in
  replace_all_substrings
    ~needle:(Keeper_sandbox.container_root meta.name)
    ~replacement:
      (Keeper_sandbox.host_root_abs_of_meta ~config meta
       |> Keeper_alerting_path.strip_trailing_slashes)
    text

let run_readonly_in_docker ?(ok_exit_codes = [ 0 ]) ~config ~meta
    ?turn_sandbox_factory ~op ~target ~command_argv ~max_bytes ~timeout_sec ()
  =
  let max_eintr_retries = 8 in
  let rec loop attempts_left =
    match
      Keeper_docker_read.container_path_of_host ~config ~meta ~host_path:target
    with
    | Error e ->
      Error
        (Keeper_exec_shared.error_json_for_op ~op
           ~extra_fields:[ "path", `String target ]
           e)
    | Ok cpath -> (
      match
        Keeper_docker_read.run_command_in_container_with_status
          ?turn_sandbox_factory ~ok_exit_codes ~config ~meta
          ~command_argv:(command_argv cpath) ~max_bytes ~timeout_sec ()
      with
      | Error msg
        when attempts_left > 0
             && String_util.contains_substring_ci msg
                  "interrupted system call" ->
        loop (attempts_left - 1)
      | Error msg ->
        Error
          (Keeper_exec_shared.error_json_for_op ~op
             ~extra_fields:[ "path", `String target ]
             msg)
      | Ok payload -> Ok payload)
  in
  loop max_eintr_retries
;;

let run_in_turn_runtime ?(ok_exit_codes = [ 0 ]) ~root ~keeper_name ~op
    ~config ~meta ~turn_sandbox_factory ~cwd ~cmd ~command_argv ~max_bytes
    ~timeout_sec ?(map_output = fun out -> out) ?(extra = []) ()
  =
  match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
  | Some runtime ->
    (match
       Keeper_turn_sandbox_runtime.run_command_with_status ~ok_exit_codes runtime
         ~cwd ~command_argv ~max_bytes ~timeout_sec ()
     with
     | Error msg ->
       Keeper_exec_shared.error_json_for_op ~op
         ~extra_fields:([ "cwd", `String cwd ] @ extra)
         msg
     | Ok (st, out) ->
       render_completed_process_result ~root ~keeper_name ~op ~cwd ~cmd ~extra st
         (map_output out))
  | None -> render_process_result ~root ~keeper_name ~op ~cwd ~cmd command_argv
;;

let hostify_turn_runtime_output ~config ~meta out =
  Keeper_shell_shared.rewrite_turn_runtime_paths_to_host ~config ~meta out
;;

let docker_git_log_path ~config ~meta host_path =
  if String.trim host_path = ""
  then Ok ""
  else if Filename.is_relative host_path
  then Ok host_path
  else Keeper_docker_read.container_path_of_host ~config ~meta ~host_path
;;

let git_log_argv_core ~format ~count ~grep ?file_path () =
  let base =
    [ "git"; "--no-optional-locks"; "log"
    ; Printf.sprintf "--format=%s" format
    ; Printf.sprintf "-%d" count
    ]
  in
  let base = if grep = "" then base else base @ [ "--grep=" ^ grep ] in
  match file_path with
  | None | Some "" -> base
  | Some path -> base @ [ "--"; path ]
;;

let git_log_response_json ~ok ~op ~cwd ~count ~grep ?via ~status ~output ~limit =
  let entries = lines_to_json ~limit output in
  let fields =
    [ "ok", `Bool ok
    ; "op", `String op
    ; "cwd", cwd
    ; "count", `Int count
    ; "grep", `String grep
    ; "status", Keeper_alerting_path.process_status_to_json status
    ; "entries", entries
    ]
  in
  let fields = match via with
    | None -> fields
    | Some v -> fields @ [ "via", `String v ]
  in
  `Assoc fields
;;

let containment_check ~config ~meta target =
  Keeper_sandbox_containment.check_read_target ~config ~meta ~target
;;

let repo_check ~keeper_id ~base_path target =
  Keeper_repo_mapping.validate_path_access ~keeper_id ~base_path ~path:target
;;

let validate_resolved_path ~config ~meta ~base_path path =
  match containment_check ~config ~meta path with
  | Error _ as e -> e
  | Ok () ->
    repo_check ~keeper_id:meta.name ~base_path path
;;

let read_target ~config ~meta ~args ~root =
  match Keeper_shell_shared.resolve_keeper_shell_read_path ~config ~meta ~args with
  | Error _ as e -> e
  | Ok target ->
    (match containment_check ~config ~meta target with
     | Error msg -> Error msg
     | Ok () ->
       match repo_check ~keeper_id:meta.name ~base_path:root target with
       | Error msg -> Error msg
       | Ok () -> Ok target)
;;

let cwd_target ~config ~meta ~args ~root =
  match Keeper_shell_path.resolve_keeper_shell_read_cwd ~config ~meta ~args with
  | Error _ as e -> e
  | Ok cwd ->
    (match containment_check ~config ~meta cwd with
     | Error msg -> Error msg
     | Ok () ->
       match repo_check ~keeper_id:meta.name ~base_path:root cwd with
       | Error msg -> Error msg
       | Ok () -> Ok cwd)
;;


let path_error ~op ~meta ~raw_path e =
  Keeper_exec_shared.actionable_path_error ~op ~meta ~raw_path ~error:e
;;

let with_read_target ~config ~meta ~args ~root ~op ~raw_path f =
  match read_target ~config ~meta ~args ~root with
  | Error e -> path_error ~op ~meta ~raw_path e
  | Ok target -> f target
;;

let with_cwd_target ~config ~meta ~args ~root ~op ~raw_path f =
  match cwd_target ~config ~meta ~args ~root with
  | Error e -> path_error ~op ~meta ~raw_path e
  | Ok cwd -> f cwd
;;

(** {1 Readonly-op JSON response builders}

    Eliminates the repeated
    [[ "ok", … ; "op", … ; "path", … ; "via", … ; "status", … ; <output>, … ]]
    boilerplate across [ls/cat/head/tail/find/tree/rg] handlers. *)

let readonly_json_fields
      ?(ok_when = fun st -> st = Unix.WEXITED 0)
      ~op
      ~path
      ~via
      ~status
      ~output_field
      ~output
      ?(extra = [])
      ()
  =
  [ "ok", `Bool (ok_when status)
  ; "op", `String op
  ; "path", `String path
  ; "via", `String via
  ; "status", Keeper_alerting_path.process_status_to_json status
  ; output_field, output
  ]
  @ extra
;;

let readonly_json_string fields =
  Yojson.Safe.to_string (`Assoc fields)
;;

(** {1 Unified readonly-op execution}

    Both docker and host branches return [(via_label, status, output)] on
    success, or a pre-built error JSON string on failure.  This collapses the
    repeated [if should_route_read … then match run_readonly_in_docker … else
    let st, out = run_argv_with_status_retry_eintr …] pattern in every
    read-target handler. *)

let run_readonly_op
      ?(ok_exit_codes = [ 0 ])
      ~config
      ~meta
      ?turn_sandbox_factory
      ~op
      ~target
      ~host_argv
      ~docker_argv
      ~max_bytes
      ~timeout_sec
      ()
  =
  if Keeper_docker_read.should_route_read ~meta
  then
    match
      run_readonly_in_docker ~config ~meta ?turn_sandbox_factory ~ok_exit_codes
        ~op ~target
        ~command_argv:docker_argv ~max_bytes ~timeout_sec ()
    with
    | Error response -> Error response
    | Ok (st, out) -> Ok ("docker", st, out)
  else
    let st, out =
      Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec host_argv
    in
    Ok ("host", st, out)
;;

(** {1 Unified cwd-op execution}

    Both [git_status], [git_diff], [pwd], [git_worktree] share the same
    docker-or-host pattern.  This helper collapses the repeated
    [[ if should_route_read then render_docker_process_result … else
       run_in_turn_runtime … ]] boilerplate. *)

let run_cwd_op
      ~root
      ~keeper_name
      ~op
      ~config
      ~meta
      ?turn_sandbox_factory
      ~cwd
      ~cmd
      ~docker_cmd
      ?(map_output = fun out -> out)
      ~command_argv
      ~max_bytes
      ~timeout_sec
      ()
  =
  if Keeper_docker_read.should_route_read ~meta
  then
    render_docker_process_result ~root ~keeper_name ~op ~config ~meta ~cwd ~cmd
      ~docker_cmd ~timeout_sec
  else
    run_in_turn_runtime ~root ~keeper_name ~op ~config ~meta ~turn_sandbox_factory
      ~cwd ~cmd ~command_argv ~map_output ~max_bytes ~timeout_sec ()
;;

(** {1 Op-specific readonly helpers}

    Collapse the repeated read-target → run_readonly_op → json_fields
    pattern in ops.ml dispatcher arms. *)

let run_ls_op ~config ~meta ?turn_sandbox_factory ~op ~target ~limit ~timeout_sec () =
  match
    run_readonly_op ~config ~meta ?turn_sandbox_factory
      ~op ~target
      ~host_argv:[ coreutils.ls; "-la"; target ]
      ~docker_argv:(fun cpath -> [ "ls"; "-la"; cpath ])
      ~max_bytes:1_000_000
      ~timeout_sec ()
  with
  | Error response -> response
  | Ok (via, st, out) ->
    let fields =
      readonly_json_fields ~op ~path:target ~via
        ~status:st ~output_field:"entries" ~output:(lines_to_json ~limit out)
        ()
    in
    readonly_json_string fields
;;

let run_cat_op ~config ~meta ?turn_sandbox_factory ~op ~target ~max_bytes ~timeout_sec () =
  match
    run_readonly_op ~config ~meta ?turn_sandbox_factory
      ~op ~target
      ~host_argv:[ coreutils.cat; target ]
      ~docker_argv:(fun cpath -> [ "cat"; cpath ])
      ~max_bytes
      ~timeout_sec ()
  with
  | Error response -> response
  | Ok (via, st, out) ->
    let body = if String.length out > max_bytes then String.sub out 0 max_bytes else out in
    Yojson.Safe.to_string
      (`Assoc
        [ "ok", `Bool (st = Unix.WEXITED 0)
        ; "op", `String op
        ; "path", `String target
        ; "via", `String via
        ; "status", Keeper_alerting_path.process_status_to_json st
        ; "truncated", `Bool (String.length out > max_bytes)
        ; "content", `String body
        ])
;;

let run_head_tail_op ~config ~meta ?turn_sandbox_factory ~op ~target ~n ~timeout_sec () =
  let coreutil = if op = "head" then coreutils.head else coreutils.tail in
  match
    run_readonly_op ~config ~meta ?turn_sandbox_factory
      ~op ~target
      ~host_argv:[ coreutil; "-n"; string_of_int n; target ]
      ~docker_argv:(fun cpath -> [ coreutil; "-n"; string_of_int n; cpath ])
      ~max_bytes:1_000_000
      ~timeout_sec ()
  with
  | Error response -> response
  | Ok (via, st, out) ->
    let fields =
      readonly_json_fields ~op ~path:target ~via
        ~status:st ~output_field:"content" ~output:(`String out)
        ~extra:[ "lines", `Int n ]
        ()
    in
    readonly_json_string fields
;;

let run_tree_op ~config ~meta ?turn_sandbox_factory ~op ~target ~limit ~timeout_sec () =
  let tree_base path =
    [ "find"; path; "-maxdepth"; "3"; "-print"
    ; "-not"; "-path"; "*/.git/*"
    ; "-not"; "-path"; "*/_build/*" ]
  in
  match
    run_readonly_op ~config ~meta ?turn_sandbox_factory
      ~op ~target
      ~host_argv:(tree_base target)
      ~docker_argv:(fun cpath -> tree_base cpath)
      ~max_bytes:1_000_000
      ~timeout_sec ()
  with
  | Error response -> response
  | Ok (via, st, out) ->
    let fields =
      readonly_json_fields ~op ~path:target ~via
        ~status:st ~output_field:"entries" ~output:(lines_to_json ~limit out)
        ()
    in
    readonly_json_string fields
;;

let run_wc_op ~root ~keeper_name ~config ~meta ?turn_sandbox_factory ~op ~target ~timeout_sec () =
  match
    run_readonly_op ~config ~meta ?turn_sandbox_factory
      ~op ~target
      ~host_argv:[ coreutils.wc; "-l"; target ]
      ~docker_argv:(fun cpath -> [ "wc"; "-l"; cpath ])
      ~max_bytes:4096
      ~timeout_sec ()
  with
  | Error response -> response
  | Ok (via, st, out) ->
    render_completed_process_result ~root ~keeper_name ~op
      ~cmd:"wc" ~extra:[ "path", `String target; "via", `String via ] st out
;;
