(** Path / working-dir validation helpers for keeper repair flows.

    Verbatim extract from [Tool_keeper]. Used by
    [handle_keeper_repair] to enforce that target files and working
    directories stay inside the calling keeper's own playground.

    Pure helpers (modulo [Unix.realpath]); no parent-local state.
    All callers are internal to [Tool_keeper]. *)

let is_safe_subpath ~parent ~child =
  if String.equal child parent then true
  else
    let parent_with_sep =
      if Filename.check_suffix parent Stdlib.Filename.dir_sep then parent
      else parent ^ Filename.dir_sep
    in
    let plen = String.length parent_with_sep in
    String.length child >= plen
    && String.equal (Stdlib.String.sub child 0 plen) parent_with_sep

let validate_target_file ~working_dir ~target_file =
  match target_file with
  | None -> Ok None
  | Some tf ->
      if not (Filename.is_relative tf) then
        Error "target_file must be a relative path"
      else
        let candidate = Filename.concat working_dir tf in
        let resolved =
          try Unix.realpath candidate with
          | Unix.Unix_error _ -> candidate
        in
        if is_safe_subpath ~parent:working_dir ~child:resolved then
          Ok (Some tf)
        else
          Error "target_file must reside within working_dir"

let resolve_playground_working_dir ~agent_name ~base_path ~working_dir_arg =
  let playground_rel =
    Keeper_alerting_path.playground_path_of_keeper agent_name
  in
  let playground_abs_raw = Filename.concat base_path playground_rel in
  match
    try Ok (Unix.realpath playground_abs_raw) with
    | Unix.Unix_error _ ->
        Error
          (Printf.sprintf
             "keeper playground directory %S does not exist yet — cannot \
              validate working_dir containment. Use keeper_context_status to \
              inspect your sandbox paths first. See #6527/#6641."
             playground_rel)
  with
  | Error msg -> Error msg
  | Ok playground_abs ->
      let effective_arg =
        if String.equal (String.trim working_dir_arg) "" then playground_abs
        else working_dir_arg
      in
      let resolved =
        try Ok (Unix.realpath effective_arg) with
        | Unix.Unix_error _ ->
            Error "working_dir does not exist or is not accessible"
      in
      (match resolved with
      | Error msg -> Error msg
      | Ok working_dir ->
          if is_safe_subpath ~parent:playground_abs ~child:working_dir then
            Ok working_dir
          else
            Error
              (Printf.sprintf
                 "working_dir must be inside your own keeper playground \
                  (%s). Cross-keeper repair loops are blocked — use \
                  keeper_context_status to inspect your sandbox paths first. \
                  See #6527/#6641."
                 playground_rel))
