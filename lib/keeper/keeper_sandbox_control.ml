(** Operator-facing keeper sandbox control.

    This module keeps Docker lifecycle operations scoped to MASC keeper labels
    and the active base path.  Start operations deliberately manage only
    [container_kind=managed]; stop operations default to that same safe scope,
    but can target [turn] or [all] when an operator needs to clear abandoned
    turn containers before TTL cleanup. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module Contract = Keeper_sandbox_control_contract

type stop_scope = Contract.stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

let stop_scope_to_string = Contract.stop_scope_to_string
let parse_stop_scope = Contract.parse_stop_scope
let managed_kind = stop_scope_to_string Stop_managed
let turn_kind = stop_scope_to_string Stop_turn

let now_ms () =
  int_of_float (Unix.gettimeofday () *. 1000.0)

let normalize_path path =
  Keeper_alerting_path.normalize_path_for_check path
  |> Keeper_alerting_path.strip_trailing_slashes

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

(* Monotonically increasing counter to disambiguate managed containers
   created within the same millisecond by the same process.  Mirrors
   {!Keeper_turn_sandbox_runtime.container_counter}. *)
let managed_container_counter : int Atomic.t = Atomic.make 0

let managed_container_name ~(meta : keeper_meta) ~(network_label : string) =
  let seq = Atomic.fetch_and_add managed_container_counter 1 in
  Printf.sprintf "masc-keeper-managed-%s-%s-%d-%d-%d"
    (Workspace_utils.safe_filename meta.name)
    (Workspace_utils.safe_filename network_label)
    (Unix.getpid ())
    (now_ms ())
    seq

let configured_effective_network network_mode = network_mode

let live_containers ~config ~meta ~timeout_sec =
  Keeper_sandbox_runtime.list_containers
    ~keeper_name:meta.name
    ~base_path:config.Workspace.base_path
    ~timeout_sec
    ()

let live_microvm_containers ~config ~meta ~timeout_sec =
  Keeper_sandbox_microvm.list_live_containers
    ~base_path:config.Workspace.base_path
    ~keeper_name:meta.name
    ~timeout_sec

let live_containers_for_keeper ~(meta : keeper_meta) containers =
  let keeper_label = Keeper_sandbox_runtime.sanitize_label_value meta.name in
  List.filter
    (fun (c : Keeper_sandbox_runtime.live_container) ->
      match c.keeper_name with
      | Some name -> String.equal name meta.name || String.equal name keeper_label
      | None -> false)
    containers

let running_managed_container ~network_label containers =
  List.find_opt
    (fun (c : Keeper_sandbox_runtime.live_container) ->
      c.container_kind = Some managed_kind
      && c.running = Some true
      && c.network_label = Some network_label)
    containers

let start_managed_container
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(network_mode : network_mode)
    ~(ttl_sec : float)
    ~(timeout_sec : float)
    () =
  if meta.sandbox_profile <> Docker then
    Error "keeper sandbox start requires sandbox_profile=docker"
  else
    let network_mode = configured_effective_network network_mode in
    let network_args, network_label =
      Keeper_sandbox_runtime.docker_network_args network_mode
    in
    let probe_timeout = timeout_sec in
    match live_containers ~config ~meta ~timeout_sec:probe_timeout with
    | Ok containers -> (
        match running_managed_container ~network_label containers with
        | Some container ->
            Ok
              (`Assoc
                 [
                   ("started", `Bool false);
                   ("already_running", `Bool true);
                   ("container",
                    Keeper_sandbox_runtime.live_container_to_yojson container);
                 ])
        | None ->
            let image =
              match meta.sandbox_image with
              | Some img when String.trim img <> "" -> img
              | _ -> Env_config_sandbox.Runtime.docker_image ()
            in
            if String.trim image = "" then
              Error "keeper sandbox docker image is not configured"
            else
              match
                Keeper_sandbox_runtime.ensure_keeper_sandbox_image_present_with_class
                  ~image
                  ~timeout_sec
              with
              | Error failure ->
                Error (Keeper_sandbox_runtime.image_preflight_start_error failure)
              | Ok () ->
              match
                Keeper_sandbox_runtime.ensure_keeper_sandbox_runtime
                  ~timeout_sec
              with
              | Error _ as err -> err
              | Ok seccomp_args ->
                  let host_root =
                    Keeper_sandbox.host_root_abs_of_meta ~config meta
                    |> normalize_path
                  in
                  ensure_dir host_root;
                  let container_root =
                    Keeper_sandbox.container_root meta.name
                    |> Keeper_alerting_path.strip_trailing_slashes
                  in
                  let uid = Unix.getuid () in
                  let gid = Unix.getgid () in
                  let container_name =
                    managed_container_name ~meta ~network_label
                  in
                  let argv =
                    Keeper_sandbox_runtime.docker_command_argv ()
                    @ [
                        "run";
                        "-d";
                        "--rm";
                        "--name";
                        container_name;
                      ]
                    @ Keeper_sandbox_runtime.docker_run_pull_never_args ()
                    @ Keeper_sandbox_runtime.docker_label_args
                        ~ttl_sec
                        ~base_path:config.base_path
                        ~keeper_name:meta.name
                        ~container_kind:managed_kind
                        ~network_label ()
                    @ [
                      "--user";
                      Printf.sprintf "%d:%d" uid gid;
                      "--env";
                      "HOME=/tmp";
                    ]
                    @ Env_config_sandbox.Hardening.read_only_rootfs_args ()
                    @ [
                      "--tmpfs";
                      Env_config_sandbox.Hardening.tmpfs_mount ();
                      "--cap-drop=ALL";
                      "--security-opt";
                      "no-new-privileges";
                    ]
                    @ seccomp_args
                    @ [
                      "--pids-limit";
                      string_of_int
                        (Env_config_sandbox.Hardening.pids_limit ());
                      "--memory";
                      Env_config_sandbox.Hardening.memory ();
                      "-v";
                      host_root ^ ":" ^ container_root ^ ":rw";
                      "--workdir";
                      container_root;
                    ]
                    @ network_args
                    @ [ image; "tail"; "-f"; "/dev/null" ]
                  in
                  (* Record the exact Docker spawn dynamic extent without
                     delaying or rejecting the keeper lane. *)
                  let st, out =
                    Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
                      Process_eio.run_argv_with_status
                        ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
                        ~cwd:(Config_dir_resolver.current_working_dir ())
                        ~timeout_sec
                        argv)
                  in
                  if st = Unix.WEXITED 0 then (
                    Keeper_registry.clear_error
                      ~base_path:config.base_path meta.name;
                    Ok
                      (`Assoc
                         [
                           ("started", `Bool true);
                           ("already_running", `Bool false);
                           ("container_id", `String (String.trim out));
                           ("container_name", `String container_name);
                           ("container_kind", `String managed_kind);
                           ("network_label", `String network_label);
                           ("ttl_sec", `Float ttl_sec);
                           ("image", `String image);
                         ]))
                  else (
                    let message =
                      Printf.sprintf "docker_managed_container_start_failed: %s"
                        (Exec_policy.truncate_for_log out)
                    in
                    Keeper_registry_error_recording.record
                      ~base_path:config.base_path meta.name message;
                    Error message))
    | Error err -> Error err

let stop_containers ?keeper_name ~scope ~(config : Workspace.config)
    ~(timeout_sec : float) () =
  let container_kind =
    match scope with
    | Stop_managed -> Some managed_kind
    | Stop_turn -> Some turn_kind
    | Stop_all -> None
  in
  Keeper_sandbox_runtime.stop_containers
    ?keeper_name
    ?container_kind
    ~base_path:config.base_path
    ~timeout_sec
    ()

(* [observed_is_dir], [valid_checkout_name] and [filesystem_checkout_names]
   lived here to list [<sandbox>/repos/*]. Discovery now measures the tree
   ([Keeper_playground_checkouts]), which also validates entry kinds and
   reports read failures as a typed result instead of a warn-and-empty-list. *)

type catalog_resolution =
  | Registered of Repo_manager_types.repository
  | Unregistered
  | Ambiguous of string list
  | Catalog_unavailable of string
  | Origin_unavailable of string

type checkout_freshness =
  | Current of { target_ref : string; upstream_head : string }
  | Ahead of { target_ref : string; upstream_head : string; ahead : int }
  | Behind of { target_ref : string; upstream_head : string; behind : int }
  | Diverged of
      { target_ref : string
      ; upstream_head : string
      ; ahead : int
      ; behind : int
      }
  | Freshness_unavailable of string

let canonical_url raw = Agent_observation.canonical_url_of_remote raw

let resolve_catalog ~catalog ~origin =
  match catalog with
  | Error error -> Catalog_unavailable error
  | Ok repositories ->
    (match canonical_url origin with
     | None -> Origin_unavailable "origin URL is not canonicalizable"
     | Some origin_id ->
       let matches =
         List.filter
           (fun (repo : Repo_manager_types.repository) ->
             match canonical_url repo.url with
             | Some catalog_id -> String.equal catalog_id origin_id
             | None -> false)
           repositories
       in
       match matches with
       | [ repo ] -> Registered repo
       | [] -> Unregistered
       | repos -> Ambiguous (List.map (fun repo -> repo.Repo_manager_types.id) repos))

let with_inspection_budget budget inspect =
  match Repo_git.Inspection_budget.remaining_timeout budget with
  | Error _ as error -> error
  | Ok timeout_sec -> inspect timeout_sec
;;

let first_git_line ~budget ~cwd args =
  match
    with_inspection_budget budget (fun timeout_sec ->
      Repo_git.run_git ~cwd ~timeout_sec args)
  with
  | Ok (line :: _) -> Ok line
  | Ok [] -> Error (Printf.sprintf "git %s returned no output" (String.concat " " args))
  | Error _ as error -> error

let dirty_state ~budget ~repository =
  match
    with_inspection_budget budget (fun timeout_sec ->
      Repo_git.status_summary ~timeout_sec ~repository ())
  with
  | Ok summary -> Ok (summary.Repo_git.changed_files > 0, summary.changed_files)
  | Error _ as error -> error

let freshness_of_catalog ~budget ~repository = function
  | Registered catalog_repo ->
    let target_ref = "origin/" ^ catalog_repo.default_branch in
    (match
       first_git_line
         ~budget
         ~cwd:repository.Repo_manager_types.local_path
         [ "rev-parse"; target_ref ]
     with
     | Error error -> Freshness_unavailable error
     | Ok upstream_head ->
       (match
          with_inspection_budget budget (fun timeout_sec ->
            Repo_git.ahead_behind ~timeout_sec ~repository ~target_ref ())
        with
        | Error error -> Freshness_unavailable error
        | Ok (0, 0) -> Current { target_ref; upstream_head }
        | Ok (0, ahead) -> Ahead { target_ref; upstream_head; ahead }
        | Ok (behind, 0) -> Behind { target_ref; upstream_head; behind }
        | Ok (behind, ahead) -> Diverged { target_ref; upstream_head; ahead; behind }))
  | Unregistered -> Freshness_unavailable "checkout is not registered in the repository catalog"
  | Ambiguous ids ->
    Freshness_unavailable
      (Printf.sprintf "checkout origin matches multiple repository ids: %s"
         (String.concat ", " ids))
  | Catalog_unavailable error -> Freshness_unavailable ("repository catalog unavailable: " ^ error)
  | Origin_unavailable error -> Freshness_unavailable error

let catalog_json = function
  | Registered repo ->
    `Assoc [ "state", `String "registered"; "repository_id", `String repo.id ]
  | Unregistered -> `Assoc [ "state", `String "unregistered" ]
  | Ambiguous ids ->
    `Assoc
      [ "state", `String "ambiguous"
      ; "repository_ids", `List (List.map (fun id -> `String id) ids)
      ]
  | Catalog_unavailable error ->
    `Assoc [ "state", `String "unavailable"; "error", `String error ]
  | Origin_unavailable error ->
    `Assoc [ "state", `String "origin_unavailable"; "error", `String error ]

let freshness_json = function
  | Current { target_ref; upstream_head } ->
    `Assoc
      [ "state", `String "current"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int 0; "behind", `Int 0 ]
  | Ahead { target_ref; upstream_head; ahead } ->
    `Assoc
      [ "state", `String "ahead"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int ahead; "behind", `Int 0 ]
  | Behind { target_ref; upstream_head; behind } ->
    `Assoc
      [ "state", `String "behind"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int 0; "behind", `Int behind ]
  | Diverged { target_ref; upstream_head; ahead; behind } ->
    `Assoc
      [ "state", `String "diverged"; "target_ref", `String target_ref
      ; "upstream_head", `String upstream_head; "ahead", `Int ahead; "behind", `Int behind ]
  | Freshness_unavailable error ->
    `Assoc [ "state", `String "unavailable"; "error", `String error ]

(* One checkout's measured facts. [checkout_json] renders this to the tool
   surface and [freshness_row_of_inspection] projects it into the turn
   context, so the two surfaces read the same probe and can never disagree. *)
type checkout_inspection = {
  inspected : Keeper_playground_checkouts.checkout;
  catalog_resolution : catalog_resolution;
  branch : (string, string) result;
  head : (string, string) result;
  dirty : (bool * int, string) result;
  freshness : checkout_freshness;
}

let inspect_checkout ~budget ~catalog (checkout : Keeper_playground_checkouts.checkout) =
  (* The checkout's own path, as discovered. Previously this reassembled
     [sandbox_abs/repos/<name>], which meant any checkout found outside that
     one shape was inspected at a path that does not exist — every git call
     below would fail and the entry would render as "unavailable". *)
  let checkout_abs = checkout.absolute_path in
  let name = checkout.name in
  let origin =
    with_inspection_budget budget (fun timeout_sec ->
      Repo_git.get_origin_url ~timeout_sec ~local_path:checkout_abs ()
      |> Result.map_error Repo_git.origin_lookup_error_to_string)
  in
  let catalog_resolution =
    match origin with
    | Ok origin -> resolve_catalog ~catalog ~origin
    | Error error -> Origin_unavailable error
  in
  let repository : Repo_manager_types.repository =
    match catalog_resolution with
    | Registered repo -> { repo with local_path = checkout_abs }
    | Unregistered | Ambiguous _ | Catalog_unavailable _ | Origin_unavailable _ ->
      { id = name; name; url = ""; local_path = checkout_abs; aliases = []
      ; default_branch = ""; keepers = []; status = Active; auto_sync = false
      ; sync_interval = 0; created_at = 0L; updated_at = 0L }
  in
  let branch =
    with_inspection_budget budget (fun timeout_sec ->
      Repo_git.current_branch ~timeout_sec ~repository ())
  in
  let head = first_git_line ~budget ~cwd:checkout_abs [ "rev-parse"; "HEAD" ] in
  let dirty = dirty_state ~budget ~repository in
  (* Freshness stays the last probe so the budget drains in the same order as
     the pre-split [checkout_json] did. *)
  let freshness = freshness_of_catalog ~budget ~repository catalog_resolution in
  { inspected = checkout; catalog_resolution; branch; head; dirty; freshness }

let checkout_json (inspection : checkout_inspection) =
  let checkout = inspection.inspected in
  let name = checkout.Keeper_playground_checkouts.name in
  let catalog_resolution = inspection.catalog_resolution in
  let branch = inspection.branch in
  let head = inspection.head in
  let dirty = inspection.dirty in
  let inspection_errors =
    [ (match branch with Error error -> Some ("branch: " ^ error) | Ok _ -> None)
    ; (match head with Error error -> Some ("head: " ^ error) | Ok _ -> None)
    ; (match dirty with Error error -> Some ("status: " ^ error) | Ok _ -> None)
    ]
    |> List.filter_map Fun.id
  in
  `Assoc
    [ "checkout_name", `String name
    ; "path", `String checkout.relative_path
      (* [path] is relative to the keeper's workspace root and is whatever the
         keeper actually used; it is no longer prefixed with a segment the
         system prescribes. [path_base] states that basis on the wire so a
         reader does not have to know the old convention. *)
    ; "path_base", `String "playground_root"
    ; ( "git_link"
      , `String
          (match checkout.git_link with
           | Keeper_playground_checkouts.Git_directory -> "directory"
           | Keeper_playground_checkouts.Git_pointer_file -> "pointer_file") )
    ; "catalog", catalog_json catalog_resolution
    ; "branch", (match branch with Ok value -> `String value | Error _ -> `Null)
    ; "head", (match head with Ok value -> `String value | Error _ -> `Null)
    ; "dirty", (match dirty with Ok (value, _) -> `Bool value | Error _ -> `Null)
    ; "changed_files", (match dirty with Ok (_, value) -> `Int value | Error _ -> `Null)
    ; "inspection_state", `String (if inspection_errors = [] then "available" else "unavailable")
    ; "inspection_errors", `List (List.map (fun error -> `String error) inspection_errors)
    ; "freshness", freshness_json inspection.freshness
    ]

type freshness_row = {
  row_checkout_path : string;
  row_branch : string option;
  row_changed_files : int option;
  row_freshness : checkout_freshness;
}

let freshness_row_of_inspection (inspection : checkout_inspection) =
  (* [relative_path], not [name]: it is the cwd the keeper passes to its
     tools, and basenames collide (a live playground held two [poc-repo]
     checkouts at different paths, 2026-09-01 field probe). *)
  { row_checkout_path =
      inspection.inspected.Keeper_playground_checkouts.relative_path
  ; row_branch = Result.to_option inspection.branch
  ; row_changed_files =
      (match inspection.dirty with
       | Ok (_, changed_files) -> Some changed_files
       | Error _ -> None)
  ; row_freshness = inspection.freshness
  }

let repository_checkouts_json_with_budget_impl
    ~before_git_inspection
    ~inspection_budget_sec
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
  =
  let sandbox_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta
    |> normalize_path
  in
  let observed_at_unix = Time_compat.now () in
  let catalog = Repo_store.load_all ~base_path:config.base_path in
  let scan = Keeper_playground_checkouts.discover ~root:sandbox_abs in
  before_git_inspection ();
  (* The budget bounds the per-checkout Git inspections below, so it starts
     after [load_all] and [discover]. Opening it first let a large catalog or a
     slow filesystem walk exhaust it before any Git subprocess ran, and every
     checkout then reported branch/head/status as unavailable. *)
  let inspection_budget =
    Repo_git.Inspection_budget.create ~timeout_sec:inspection_budget_sec ()
  in
  let entries =
    match scan with
    | Ok discovery ->
      Keeper_playground_checkouts.found discovery
      |> List.map (fun checkout ->
        checkout_json (inspect_checkout ~budget:inspection_budget ~catalog checkout))
    | Error _ -> []
  in
  `Assoc
    [ ( "state"
      , `String
          (match catalog, scan with
           | Ok _, Ok _ when Repo_git.Inspection_budget.is_exhausted inspection_budget ->
             "inspection_budget_exhausted"
           | Ok _, Ok _ -> "available"
           | Error _, _ -> "catalog_unavailable"
           (* A failed scan and an empty playground used to be the same empty
              list. They are different answers and now say so. *)
           | Ok _, Error _ -> "filesystem_unavailable") )
    ; "scan", Keeper_playground_checkouts.scan_json scan
    ; "observed_at", `String (Masc_domain.iso8601_of_unix_seconds observed_at_unix)
    ; "observed_at_unix", `Float observed_at_unix
    ; "entries", `List entries
    ; "error", (match catalog with Ok _ -> `Null | Error error -> `String error)
    ]

let repository_checkouts_json_with_budget ~inspection_budget_sec ~config ~meta =
  repository_checkouts_json_with_budget_impl
    ~before_git_inspection:(fun () -> ())
    ~inspection_budget_sec
    ~config
    ~meta
;;

let repository_checkouts_json ~config ~meta =
  repository_checkouts_json_with_budget
    ~inspection_budget_sec:Repo_git.inspection_timeout_sec
    ~config
    ~meta
;;

let checkout_freshness_rows
    ?(inspection_budget_sec = Repo_git.inspection_timeout_sec)
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ()
  =
  let sandbox_abs =
    Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize_path
  in
  let catalog = Repo_store.load_all ~base_path:config.base_path in
  match Keeper_playground_checkouts.discover ~root:sandbox_abs with
  | Error scan_error -> Error scan_error
  | Ok discovery ->
    let budget =
      Repo_git.Inspection_budget.create ~timeout_sec:inspection_budget_sec ()
    in
    Ok
      (Keeper_playground_checkouts.found discovery
       |> List.map (fun checkout ->
         freshness_row_of_inspection (inspect_checkout ~budget ~catalog checkout)))
;;

module For_testing = struct
  let repository_checkouts_json_with_budget = repository_checkouts_json_with_budget

  let repository_checkouts_json_with_budget_after_discovery
      ~before_git_inspection
      ~inspection_budget_sec
      ~config
      ~meta
    =
    repository_checkouts_json_with_budget_impl
      ~before_git_inspection
      ~inspection_budget_sec
      ~config
      ~meta
  ;;
end

let preflight_status ~timeout_sec =
  Keeper_sandbox_runtime.docker_preflight ~timeout_sec ()

(* [docker_preflight] already answers [ok] as a bool. Serialising the record
   and reading the field back out of an [`Assoc] meant a typo in the key, or a
   rename upstream, produced [None] — indistinguishable from "the probe did
   not run" — instead of a compile error. Keep the record typed to the point
   where the payload is built. *)
let preflight_ok (preflight : Keeper_sandbox_runtime.docker_preflight option) =
  Option.map (fun (p : Keeper_sandbox_runtime.docker_preflight) -> p.ok) preflight

(* The [Local] arm that opened this went with the profile: every keeper runs
   under a backend now, so the answer is about containers from the first
   line. *)
let container_mode (meta : keeper_meta) containers =
  match meta.sandbox_profile with
  | Micro_vm ->
    if List.exists (fun (c : Keeper_sandbox_runtime.live_container) -> c.running = Some true) containers
    then "microvm_vm_running"
    else "microvm_vm_not_running"
  | Docker ->
    if
      List.exists
        (fun (c : Keeper_sandbox_runtime.live_container) ->
          c.container_kind = Some managed_kind && c.running = Some true)
        containers
    then
      "managed_running"
    else (
      match meta.network_mode with
      | Network_none -> "turn_scoped_or_managed_none"
      | Network_inherit -> "oneshot_or_managed_inherit")
  | Remote_ssh -> "remote_ssh"

let why_no_container (meta : keeper_meta) ~preflight containers =
  (* "sandbox_profile=local" was the first answer here. No keeper can report
     it now, so the reasons below are the whole list. *)
  if containers <> [] then
    None
  else
    match meta.sandbox_profile with
    | Micro_vm ->
      Some "no visible Apple Container VM; a microvm guest is created on this Keeper's first sandboxed tool execution"
    | Remote_ssh ->
      Some "remote_ssh executes on its configured endpoint and does not own a local container"
    | Docker -> (
      match preflight_ok preflight with
      | Some false -> Some "docker_preflight_failed"
      | _ -> (
          match meta.network_mode with
          | Network_inherit ->
              Some
                "no visible managed sandbox container; network_mode=inherit uses one-shot Docker containers on sandboxed tool calls, and those containers still mount the keeper playground"
          | Network_none ->
              Some
                "no active turn or visible managed sandbox container; Docker containers start on sandboxed tool calls or via masc_keeper_sandbox_start, with the keeper playground mounted"))

(** Where a microvm keeper's build output actually sits.

    The vnode exhaustion that panicked this host three times was invisible
    from every operator surface: whether a checkout writes to the virtiofs
    share or to the block volume decided whether the machine survived, and
    nothing showed it. This answers that per checkout.

    Read-only. Opening a tab must not install links, so it walks through
    [observe_build_links] rather than the ensure path.

    [unlinked] is the actionable list: a checkout still holding a real
    [_build] keeps writing to the share, and only a person can clear it --
    the ensure path refuses to delete build output it did not create. *)
let microvm_build_volume_json ~(config : Workspace.config) ~(meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker | Remote_ssh -> `Null
  | Micro_vm ->
    let playground_root =
      Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize_path
    in
    let observations = Keeper_sandbox_microvm.observe_build_links ~playground_root in
    let is_linked (_, state) =
      match state with
      | Keeper_sandbox_microvm.Build_symlink _ -> true
      | Keeper_sandbox_microvm.Build_absent | Keeper_sandbox_microvm.Build_real_directory
        -> false
    in
    let linked, unlinked = List.partition is_linked observations in
    let relative path =
      match Keeper_sandbox_microvm.playground_relative ~playground_root path with
      | Some rel -> rel
      | None -> path
    in
    `Assoc
      [ ( "name"
        , match Keeper_sandbox_microvm.build_volume_name ~keeper_name:meta.name with
          | Ok name -> `String name
          | Error _ -> `Null )
      ; ("guest_root", `String Keeper_sandbox_microvm.build_volume_guest_root)
      ; ("linked", `Int (List.length linked))
      ; ( "unlinked"
        , `List
            (List.map
               (fun (path, state) ->
                 `Assoc
                   [ ("path", `String (relative path))
                   ; ( "reason"
                     , `String
                         (match state with
                          | Keeper_sandbox_microvm.Build_real_directory ->
                            "holds build output on the share"
                          | Keeper_sandbox_microvm.Build_absent -> "not built yet"
                          | Keeper_sandbox_microvm.Build_symlink _ -> "linked") )
                   ])
               unlinked) )
      ]
;;

let sandbox_resource_config_json (meta : keeper_meta) =
  match meta.sandbox_profile with
  | Micro_vm ->
    let memory =
      match Env_config_sandbox.Runtime.microvm_memory () with
      | "" -> Env_config_sandbox.Hardening.memory ()
      | configured -> configured
    in
    let cpus =
      match Env_config_sandbox.Runtime.microvm_cpus () with
      | "" -> `Null
      | configured -> `String configured
    in
    `Assoc
      [ "memory", `String memory
      ; "cpus", cpus
      ; "work_volume_size", `String (Env_config_sandbox.Runtime.microvm_work_volume_size ())
      ; "build_volume_size", `String (Env_config_sandbox.Runtime.microvm_build_volume_size ())
      ; "pids_limit", `Null
      ; "tmpfs_size", `Null
      ]
  | Docker ->
    `Assoc
      [ "memory", `String (Env_config_sandbox.Hardening.memory ())
      ; "cpus", `Null
      ; "work_volume_size", `Null
      ; "build_volume_size", `Null
      ; "pids_limit", `Int (Env_config_sandbox.Hardening.pids_limit ())
      ; "tmpfs_size", `String (Env_config_sandbox.Hardening.tmpfs_size ())
      ]
  | Remote_ssh -> `Null
;;

let sandbox_paths_json ~(config : Workspace.config) (meta : keeper_meta) =
  let host_workspace =
    Keeper_sandbox.host_root_abs_of_meta ~config meta |> normalize_path
  in
  match meta.sandbox_profile with
  | Remote_ssh ->
    `Assoc
      [ "host_workspace", `String host_workspace
      ; "guest_home", `Null
      ; "guest_workspace", `Null
      ; "guest_config", `Null
      ; "guest_work_volume", `Null
      ; "guest_build_volume", `Null
      ]
  | Docker | Micro_vm ->
    let container_root = Keeper_sandbox.container_root meta.name in
    let guest_workspace =
      match meta.sandbox_profile with
      | Micro_vm -> Keeper_sandbox_microvm.keeper_work_root ~keeper_name:meta.name
      | Docker | Remote_ssh -> container_root
    in
    `Assoc
      [ "host_workspace", `String host_workspace
      ; "guest_home", `Null
      ; "guest_workspace", `String guest_workspace
      ; ( "guest_config"
        , `String
            (Keeper_sandbox_runtime.container_masc_config_dir
               ~container_root) )
      ; ( "guest_work_volume"
        , match meta.sandbox_profile with
          | Micro_vm -> `String Keeper_sandbox_microvm.work_volume_guest_root
          | Docker | Remote_ssh -> `Null )
      ; ( "guest_build_volume"
        , match meta.sandbox_profile with
          | Micro_vm -> `String Keeper_sandbox_microvm.build_volume_guest_root
          | Docker | Remote_ssh -> `Null )
      ]
;;

let live_status_json ?(include_preflight = true)
    ?preflight_override
    ?containers_override
    ?(include_repository_checkouts = true)
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(timeout_sec : float)
    ~(verbose : bool)
    () =
  let preflight =
    match preflight_override with
    | Some cached -> cached
    | None ->
      if include_preflight && meta.sandbox_profile = Docker then
        preflight_status ~timeout_sec
      else
        None
  in
  let containers, container_error =
    match meta.sandbox_profile with
    | Docker ->
      (match containers_override with
       | Some (Ok containers) ->
           (live_containers_for_keeper ~meta containers, None)
       | Some (Error err) -> ([], Some err)
       | None -> (
         match live_containers ~config ~meta ~timeout_sec with
         | Ok containers -> (containers, None)
         | Error err -> ([], Some err)))
    | Micro_vm -> (
      match live_microvm_containers ~config ~meta ~timeout_sec with
      | Ok containers -> (containers, None)
      | Error err -> ([], Some err))
    | Remote_ssh -> ([], None)
  in
  let why_no_container =
    match container_error with
    | Some _ ->
      Some
        (match meta.sandbox_profile with
         | Docker -> "docker_container_listing_failed"
         | Micro_vm -> "microvm_container_listing_failed"
         | Remote_ssh -> "remote_ssh_container_listing_failed")
    | None -> why_no_container meta ~preflight containers
  in
  `Assoc
    [
      ("keeper", `String meta.name);
      ("sandbox_profile", `String (sandbox_profile_to_string meta.sandbox_profile));
      ("configured_network_mode", `String (network_mode_to_string meta.network_mode));
      ("effective_mode", `String (container_mode meta containers));
      ( "managed_container_kind"
      , match meta.sandbox_profile with
        | Docker -> `String managed_kind
        | Micro_vm -> `String Keeper_sandbox_microvm.keeper_vm_container_kind
        | Remote_ssh -> `Null );
      ("containers",
       `List (List.map Keeper_sandbox_runtime.live_container_to_yojson containers));
      ( "preflight",
        if verbose
        then
          Json_util.option_to_yojson
            Keeper_sandbox_runtime.docker_preflight_to_yojson
            preflight
        else `Null );
      ("build_volume", microvm_build_volume_json ~config ~meta);
      ("resource_config", sandbox_resource_config_json meta);
      ("paths", sandbox_paths_json ~config meta);
      ("container_error", Json_util.string_opt_to_json container_error);
      ("why_no_container", Json_util.string_opt_to_json why_no_container);
      ( "repository_checkouts",
        if include_repository_checkouts then
          repository_checkouts_json ~config ~meta
        else
          `Assoc [ "state", `String "not_inspected"; "entries", `List [] ] );
    ]
