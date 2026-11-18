module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base

(** The keeper's root on the work volume: [<work root>/<keeper>], the
    directory the shim jails every request under. *)
let keeper_work_root ~keeper_name =
  Filename.concat work_volume_guest_root (Playground_paths.sanitize_keeper_name keeper_name)
;;

(** Where the guest finds [masc-exec-shim] and its config: one host directory
    mounted read-only. The guest root is read-only and [/etc] is the image's,
    so the config travels beside the binary and the transport names it
    through [MASC_EXEC_SHIM_CONFIG]. *)
let shim_guest_dir = "/opt/masc-exec-shim"
let shim_binary_name = "masc-exec-shim"
let shim_config_name = "masc-exec-shim.conf"
let shim_sidecar_name = "masc-exec-shim.sha256"

(* RFC-0427 B-2. The installer places the release's shim and, beside it, the
   sha256 the release's SHA256SUMS gave for that asset. The boot reads the
   pair: a binary that does not match its own sidecar is refused by name,
   because a shim the release did not ship is the 2026-09-05 outage waiting
   to recur. No sidecar means a hand-built shim; it runs, and the boot log
   says it was not verified. *)
type shim_provenance =
  | Shim_verified of { sha256 : string }
  | Shim_unverified

(* #52968. The guest's agent is the mounted binary, not the image's, so the
   relay version a guest will speak is fixed by these bytes. Every shim built
   from a source that knows the declaration carries
   {!Exec_ssh_protocol.Relay.version_declaration} as a literal; reading it
   needs no Linux to run the binary on. *)
type relay_declaration =
  | Relay_version of int
  | No_relay_version
  | Several_relay_versions of int list

type shim_inspection =
  { provenance : shim_provenance
  ; relay : relay_declaration
  }

(* The declaration's grammar: this prefix, one to four decimal digits, ';'.
   The host keeps the prefix; the shim binary carries only whole
   declarations, so every match is one the shim's source wrote. *)
let relay_declaration_prefix = "MASC_EXEC_SHIM_RELAY_VERSION="
let relay_declaration_terminator = ';'
let relay_declaration_max_digits = 4

let is_digit c = c >= '0' && c <= '9'

let declared_version_at bytes ~digits_start =
  let length = String.length bytes in
  let rec digits_end index =
    if index < length && is_digit bytes.[index] then digits_end (index + 1) else index in
  let stop = digits_end digits_start in
  let count = stop - digits_start in
  if count >= 1 && count <= relay_declaration_max_digits
     && stop < length && Char.equal bytes.[stop] relay_declaration_terminator
  then Some (int_of_string (String.sub bytes digits_start count))
  else None

let relay_declaration_of_bytes bytes =
  let prefix_length = String.length relay_declaration_prefix in
  let rec collect from found =
    match String_util.find_substring ~pos:from bytes relay_declaration_prefix with
    | None -> found
    | Some at ->
      let digits_start = at + prefix_length in
      let found = match declared_version_at bytes ~digits_start with
        | Some version when not (List.mem version found) -> version :: found
        | Some _ | None -> found in
      collect (at + 1) found in
  match List.sort Int.compare (collect 0 []) with
  | [] -> No_relay_version
  | [ version ] -> Relay_version version
  | (_ :: _ :: _) as versions -> Several_relay_versions versions

(* Integrity follows current bytes, not metadata that an in-place writer
   can preserve. The boot edge offloads this read and hash to its executor. *)
let read_binary path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok contents
  | exception Sys_error detail -> Error detail
;;

let sidecar_provenance ~sidecar ~binary contents =
  if not (Sys.file_exists sidecar)
  then Ok Shim_unverified
  else
    match In_channel.with_open_bin sidecar In_channel.input_all with
    | exception Sys_error detail ->
      Error (Printf.sprintf "microvm_shim_sidecar_unreadable: %s: %s" sidecar detail)
    | content ->
      let want =
        match String.split_on_char ' ' (String.trim content) with
        | first :: _ -> String.trim first
        | [] -> ""
      in
      if not (String_util.is_lowercase_sha256_hex want)
      then
        Error
          (Printf.sprintf
             "microvm_shim_sidecar_invalid: %s does not begin with a lowercase sha256 hex digest"
             sidecar)
      else
        let got = Agent_core_sha256.(digest_string contents |> to_hex) in
        if String.equal got want
        then Ok (Shim_verified { sha256 = got })
        else
          Error
            (Printf.sprintf
               "microvm_shim_hash_mismatch: %s is %s but %s says %s; reinstall both with scripts/install.sh, or remove the sidecar to run a hand-built shim unverified"
               binary got sidecar want)
;;

let inspect_shim ~dir =
  let binary = Filename.concat dir shim_binary_name in
  let sidecar = Filename.concat dir shim_sidecar_name in
  match read_binary binary with
  | Error detail -> Error (Printf.sprintf "microvm_shim_unreadable: %s: %s" binary detail)
  | Ok contents ->
    Result.map
      (fun provenance -> { provenance; relay = relay_declaration_of_bytes contents })
      (sidecar_provenance ~sidecar ~binary contents)
;;

let shim_guest_path = Filename.concat shim_guest_dir shim_binary_name
let shim_config_guest_path = Filename.concat shim_guest_dir shim_config_name

let shim_mount_args ~host_dir =
  [ "--volume"; host_dir ^ ":" ^ shim_guest_dir ^ ":ro" ]
;;

(** The config the host writes for the guest's shim: the jail root is the
    work volume, the payload PATH is the image's, and the env allowlist
    names the config env the endpoint injects with every request
    ({!Keeper_sandbox_runtime.config_env_names}) -- the shim drops any
    request env it was not told to accept, and the guest is given the
    config mount, so it must be told the names that point at it. No
    [scratch_root] line: the boot mounts the guest's in-memory filesystem at
    the shim's own default ({!Backend.scratch_guest_root} is that constant),
    and a shim one release behind refuses a key it does not know, which
    would fail every request on the guest. The host writes only the keys
    every spoken shim reads. *)
let shim_env_allowlist =
  Keeper_sandbox_runtime.config_env_names
  @ [ Keeper_github_identity.git_config_global_env_name ]
;;

let shim_config_content ~payload_path =
  Printf.sprintf
    "remote_root=%s\npath=%s\nenv_allowlist=%s\n"
    work_volume_guest_root
    payload_path
    (String.concat "," shim_env_allowlist)
;;

(** What the guest endpoint declares to the remote runner. No caller env
    crosses into a guest today (typed guest dispatch refuses env), so the
    allowlist is empty; the session ceiling mirrors the OpenSSH default, and
    the connect budget covers a [container exec] that has to wait on a
    guest still settling after boot. *)
let remote_env_allowlist : string list = []
let remote_connect_timeout_sec = 10
let remote_max_concurrent_sessions = 8
