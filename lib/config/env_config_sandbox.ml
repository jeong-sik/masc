(** Env_config_sandbox — sandbox configuration SSOT.

    See {!Env_config_sandbox} module doc in the .mli for the full
    rationale.  Notes:

    - Fresh read per call.
    - Every operational timeout is resolved through a typed shell-timeout
      bucket; callers do not impose a second local clamp. *)

open Env_config_core

(* --------------------------------------------------------------- *)
(* Hardening                                                       *)
(* --------------------------------------------------------------- *)

module Hardening = struct
  let pids_limit () =
    max 32 (get_int ~default:128 "MASC_KEEPER_SANDBOX_PIDS_LIMIT")

  let nofile_limit () =
    max 1024 (get_int ~default:245_760 "MASC_KEEPER_SANDBOX_NOFILE_LIMIT")

  let memory () =
    get_string ~default:"2g" "MASC_KEEPER_SANDBOX_MEMORY"

  let tmpfs_size () =
    get_string ~default:"256m" "MASC_KEEPER_SANDBOX_TMPFS_SIZE"

  let relax_fs () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_RELAX_FS"

  let read_only_rootfs_args () =
    if relax_fs () then [] else [ "--read-only" ]

  let tmpfs_mount () =
    let exec_suffix = if relax_fs () then "" else ",noexec" in
    Printf.sprintf "/tmp:rw,nosuid,nodev%s,size=%s"
      exec_suffix (tmpfs_size ())

  let seccomp_profile () =
    get_string ~default:"" "MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"

  let require_rootless () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"

  let require_userns () =
    get_bool ~default:false "MASC_KEEPER_SANDBOX_REQUIRE_USERNS"
end

(* --------------------------------------------------------------- *)
(* Cleanup                                                         *)
(* --------------------------------------------------------------- *)

module Cleanup = struct
  let enabled () =
    get_bool ~default:true "MASC_KEEPER_SANDBOX_CLEANUP_ENABLED"

  let stale_after_sec () =
    float_of_int
      (max 60
         (get_int ~default:21_600 "MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC"))

  let interval_sec () =
    float_of_int
      (max 10
         (get_int ~default:300 "MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC"))

end

(* --------------------------------------------------------------- *)
(* Runtime                                                         *)
(* --------------------------------------------------------------- *)

module Runtime = struct
  let docker_image () =
    get_string ~default:"masc-keeper-sandbox:local"
      "MASC_KEEPER_SANDBOX_DOCKER_IMAGE"
end

(* --------------------------------------------------------------- *)
(* Preflight                                                       *)
(* --------------------------------------------------------------- *)

module Preflight = struct
  let enabled () =
    get_bool ~default:true "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED"

  (* Read-only canonical list — see .mli for the why-not-env note. *)
  let required_commands () =
    [ "sh"; "bash"; "cat"; "find"; "head"; "tail"; "wc"
    ; "git"; "gh"; "rg"; "tree"; "jq"
    ; "python3"; "node"; "npm"; "make"; "opam"; "dune"; "ssh"
    ]
end

(* --------------------------------------------------------------- *)
(* Shell_timeout — typed-bucket SSOT                               *)
(* --------------------------------------------------------------- *)

module Shell_timeout = struct
  type bucket =
    | Io
    | Read
    | Git_meta
    | Gh_min
    | User_max
    | Cleanup_rm
    | Unknown of string

  let global_default_sec = 30.0

  let bucket_key = function
    | Io -> "io"
    | Read -> "read"
    | Git_meta -> "git_meta"
    | Gh_min -> "gh_min"
    | User_max -> "user_max"
    | Cleanup_rm -> "cleanup_rm"
    | Unknown s -> s

  let known_buckets () =
    [ Io; Read; Git_meta; Gh_min; User_max; Cleanup_rm ]

  (* [Gh_min] is the only read-only floor bucket — see .mli: operators
     MUST NOT lower it via env (doing so runtimes 401 retries, #8688).
     Exhaustive match (warning 4) so a new bucket forces a deliberate
     floor/non-floor classification here, once, rather than at every
     call site that branches on it. *)
  type timeout_floor =
    | Tool_dispatch_floor

  let timeout_floor : bucket -> timeout_floor option = function
    | Gh_min -> Some Tool_dispatch_floor
    | Io | Read | Git_meta | User_max | Cleanup_rm | Unknown _ -> None

  let timeout_floor_default_sec = function
    | Tool_dispatch_floor -> 15.0

  let is_floor_bucket bucket =
    Option.is_some (timeout_floor bucket)

  let known_default_sec = function
    | Io -> Some 30.0
    | Read -> Some 15.0
    | Git_meta -> Some 5.0
    | Gh_min -> Some (timeout_floor_default_sec Tool_dispatch_floor)
    | User_max -> Some 180.0
    | Cleanup_rm -> Some 10.0
    | Unknown _ -> None

  let upper_case s =
    s
    |> String.map (fun c ->
         if c >= 'a' && c <= 'z' then
           Char.chr (Char.code c - 32)
         else if c = '-' then '_'
         else c)

  let per_bucket_env_var ~bucket =
    Printf.sprintf "MASC_KEEPER_SHELL_TIMEOUT_%s_SEC"
      (upper_case (bucket_key bucket))

  let global_env_var = "MASC_KEEPER_SHELL_TIMEOUT_DEFAULT_SEC"

  (** Empty-string env vars (used by test clearing patterns) must NOT
      be treated as "set". *)
  let trimmed_value_opt name =
    match raw_value_opt name with
    | Some v ->
      let t = String.trim v in
      if t = "" then None else Some t
    | None -> None

  let timeout_sec ~bucket () =
    match timeout_floor bucket with
    | Some floor ->
      (* Read-only floor — see .mli.  Operators MUST NOT lower this
         via env; doing so runtimes 401 retries (#8688). *)
      timeout_floor_default_sec floor
    | None ->
      let per_bucket_env = per_bucket_env_var ~bucket in
      match trimmed_value_opt per_bucket_env with
      | Some v ->
        Safe_ops.float_of_string_with_default
          ~default:global_default_sec v
      | None ->
        match known_default_sec bucket with
        | Some d -> d
        | None ->
          match trimmed_value_opt global_env_var with
          | Some v ->
            Safe_ops.float_of_string_with_default
              ~default:global_default_sec v
          | None -> global_default_sec
end

(* --------------------------------------------------------------- *)
(* Diagnostics / observability surface                                  *)
(* --------------------------------------------------------------- *)

(* Helper: does an env var currently exist (non-empty after trim)? *)
let env_is_set name =
  match Env_config_core.raw_value_opt name with
  | Some v -> String.trim v <> ""
  | None -> false

(* Convenience builders for [{ value, source, env_var }] entries. *)
let entry_env_overridable ~env_var (value : Yojson.Safe.t) : Yojson.Safe.t =
  let source = if env_is_set env_var then "env" else "default" in
  `Assoc
    [ "value", value
    ; "source", `String source
    ; "env_var", `String env_var
    ]

let entry_floor (value : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc
    [ "value", value
    ; "source", `String "load_bearing_floor"
    ; "env_var", `Null
    ]

let bool_v b : Yojson.Safe.t = `Bool b
let int_v i : Yojson.Safe.t = `Int i
let float_v f : Yojson.Safe.t = `Float f
let string_v s : Yojson.Safe.t = `String s

let raw_hardening () : Yojson.Safe.t =
  `Assoc
    [ "pids_limit",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_PIDS_LIMIT"
        (int_v (Hardening.pids_limit ()))
    ; "nofile_limit",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_NOFILE_LIMIT"
        (int_v (Hardening.nofile_limit ()))
    ; "memory",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_MEMORY"
        (string_v (Hardening.memory ()))
    ; "tmpfs_size",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_TMPFS_SIZE"
        (string_v (Hardening.tmpfs_size ()))
    ; "relax_fs",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_RELAX_FS"
        (bool_v (Hardening.relax_fs ()))
    ; "seccomp_profile",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_SECCOMP_PROFILE"
        (string_v (Hardening.seccomp_profile ()))
    ; "require_rootless",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS"
        (bool_v (Hardening.require_rootless ()))
    ; "require_userns",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_REQUIRE_USERNS"
        (bool_v (Hardening.require_userns ()))
    ]

let raw_cleanup () : Yojson.Safe.t =
  `Assoc
    [ "enabled",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_CLEANUP_ENABLED"
        (bool_v (Cleanup.enabled ()))
    ; "stale_after_sec",
      entry_env_overridable
        ~env_var:"MASC_KEEPER_SANDBOX_CLEANUP_STALE_AFTER_SEC"
        (float_v (Cleanup.stale_after_sec ()))
    ; "interval_sec",
      entry_env_overridable
        ~env_var:"MASC_KEEPER_SANDBOX_CLEANUP_INTERVAL_SEC"
        (float_v (Cleanup.interval_sec ()))
    ]

let raw_runtime () : Yojson.Safe.t =
  `Assoc
    [ "docker_image",
      entry_env_overridable ~env_var:"MASC_KEEPER_SANDBOX_DOCKER_IMAGE"
        (string_v (Runtime.docker_image ()))
    ]

let raw_preflight () : Yojson.Safe.t =
  `Assoc
    [ "enabled",
      entry_env_overridable
        ~env_var:"MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED"
        (bool_v (Preflight.enabled ()))
    ; "required_commands",
      entry_floor
        (`List (List.map (fun s -> `String s)
                  (Preflight.required_commands ())))
    ]

let raw_shell_timeout () : Yojson.Safe.t =
  let bucket_entry b =
    let key = Shell_timeout.bucket_key b in
    let value = float_v (Shell_timeout.timeout_sec ~bucket:b ()) in
    let entry =
      if Shell_timeout.is_floor_bucket b then entry_floor value
      else
        entry_env_overridable
          ~env_var:(Shell_timeout.per_bucket_env_var ~bucket:b)
          value
    in
    key, entry
  in
  `Assoc (List.map bucket_entry (Shell_timeout.known_buckets ()))

let raw_section () : Yojson.Safe.t =
  `Assoc
    [ "hardening", raw_hardening ()
    ; "cleanup", raw_cleanup ()
    ; "runtime", raw_runtime ()
    ; "preflight", raw_preflight ()
    ; "shell_timeout", raw_shell_timeout ()
    ]

let derived_section () : Yojson.Safe.t =
  `Assoc
    [ "read_only_rootfs_args",
      `List (List.map (fun s -> `String s)
               (Hardening.read_only_rootfs_args ()))
    ; "tmpfs_mount", `String (Hardening.tmpfs_mount ())
    ]

let effective_config_json () : Yojson.Safe.t =
  `Assoc
    [ "raw", raw_section ()
    ; "derived", derived_section ()
    ]
