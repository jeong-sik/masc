(** Best-effort playground repository state cache.

    The cache is advisory runtime metadata used by keeper status surfaces.
    Callers must not depend on cache writes succeeding for the primary
    operation to succeed. *)

let env_float name default =
  match Sys.getenv_opt name with
  | Some s -> (match float_of_string_opt s with Some f -> f | None -> default)
  | None -> default

(* Ceiling for lightweight git metadata commands (rev-parse, log --oneline).
   These are local disk ops that should complete in <1s; 5s is generous
   without masking genuine repository corruption or NFS hangs. *)
let git_meta_timeout_sec = env_float "MASC_KEEPER_GIT_META_TIMEOUT_SEC" 5.0

let git_meta repo_path args =
  Process_eio.run_argv_with_status ~timeout_sec:git_meta_timeout_sec
    ("git" :: "-C" :: repo_path :: args)

let is_shallow_repo repo_path =
  try
    match git_meta repo_path [ "rev-parse"; "--is-shallow-repository" ] with
    | Unix.WEXITED 0, output ->
        String.equal "true" (String.trim output)
    | _ -> false
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> false

let update
    ~(playground_dir : string)
    ~(repo_name : string)
    ~(repo_path : string)
    ~(action : string)
    ~(shallow : bool) : unit =
  try
    let branch =
      match git_meta repo_path [ "rev-parse"; "--abbrev-ref"; "HEAD" ] with
      | Unix.WEXITED 0, output -> String.trim output
      | _ -> "unknown"
    in
    let commit =
      match git_meta repo_path [ "log"; "--oneline"; "-1" ] with
      | Unix.WEXITED 0, output -> String.trim output
      | _ -> ""
    in
    let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
    let entry =
      `Assoc
        [
          ("name", `String repo_name);
          ("branch", `String branch);
          ("latest_commit", `String commit);
          ("shallow", `Bool shallow);
          ("last_action", `String action);
          ("updated_at", `String ts);
        ]
    in
    let cache_path = Filename.concat playground_dir ".playground_state.json" in
    let existing =
      try
        let json = Yojson.Safe.from_file cache_path in
        match Yojson.Safe.Util.member "repos" json with
        | `List repos -> repos
        | _ -> []
      with Sys_error _ | Yojson.Json_error _ -> []
    in
    let updated =
      entry
      :: List.filter
           (fun repo ->
             match Yojson.Safe.Util.member "name" repo with
             | `String name -> not (String.equal name repo_name)
             | _ -> true)
           existing
    in
    let json =
      `Assoc [ ("repos", `List updated); ("last_updated", `String ts) ]
    in
    match
      Fs_compat.save_file_atomic cache_path
        (Yojson.Safe.pretty_to_string json ^ "\n")
    with
    | Ok () -> ()
    | Error e -> Log.Misc.warn "playground cache save failed: %s" e
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Misc.warn "playground cache update failed: %s"
        (Printexc.to_string exn)
