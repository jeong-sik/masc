(** See .mli for the contract. *)

type t =
  | Apple_container
  | Microsandbox
  | Nerdctl_kata

let to_string = function
  | Apple_container -> "apple_container"
  | Microsandbox -> "microsandbox"
  | Nerdctl_kata -> "nerdctl_kata"
;;

(* Issue #8467 shape: [all] and [to_string] are the two places a constructor
   has to appear, and [valid_strings] is derived from them rather than typed
   again, so a backend added later cannot be half-registered. *)
let all = [ Apple_container; Microsandbox; Nerdctl_kata ]
let valid_strings = List.map to_string all
let of_string raw = List.find_opt (fun b -> String.equal (to_string b) raw) all

(* The containerd shim id for Kata. It is a literal here rather than in the
   argv builder so the one place that knows "this backend is not a microVM
   without this flag" is the backend's own definition. *)
let kata_containerd_shim = "io.containerd.kata.v2"

let run_runtime_args = function
  | Apple_container | Microsandbox -> []
  | Nerdctl_kata -> [ "--runtime"; kata_containerd_shim ]
;;

let cli_name = function
  | Apple_container -> "container"
  | Microsandbox -> "msb"
  | Nerdctl_kata -> "nerdctl"
;;

(* DET-OK: the host is the boundary this reads. Apple's runtime is macOS-only,
   so assuming it anywhere else would hand a keeper a different isolation than
   the one its TOML declared. Returning [None] makes that a refusal the
   operator sees at boot. *)
let default_for_host () =
  match Sys.os_type with
  | "Unix" when Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" ->
    Some Apple_container
  | _ -> None
;;

(* ── What the boot asks the runtime to guarantee ─────────────────────── *)

type guest_constraint =
  | Drop_all_capabilities
  | Read_only_rootfs
  | Remove_on_exit

let all_guest_constraints = [ Drop_all_capabilities; Read_only_rootfs; Remove_on_exit ]

let guest_constraint_to_string = function
  | Drop_all_capabilities -> "drop_all_capabilities"
  | Read_only_rootfs -> "read_only_rootfs"
  | Remove_on_exit -> "remove_on_exit"
;;

type constraint_class =
  | Isolation
  | Lifecycle

(* Losing an [Isolation] guarantee hands the keeper a weaker sandbox than the
   profile it declared, so the boot refuses instead of running without it.
   Losing the [Lifecycle] one does not: teardown removes the guest through
   [delete_force_argv_for] whether or not the runtime removes it on exit, so
   the boot records the drop on the guest and continues. The split is data
   because the alternative is a branch each new backend's author has to
   remember to write. *)
let constraint_class = function
  | Drop_all_capabilities -> Isolation
  | Read_only_rootfs -> Isolation
  | Remove_on_exit -> Lifecycle
;;

type constraint_argv =
  | Expressed of string list
  | Not_expressible of string

(* Nine arms, one per pair. No catch-all: a fourth runtime has to answer each
   guarantee separately, which is the question this table exists to ask.
   Apple's spellings were accepted by a live [container run] 1.3.0 on
   2026-08-28; the [msb] refusals were read from [msb run --help] on 0.6.16
   (2026-09-04) and confirmed by clap rejecting the flag before doing any
   work; nerdctl's are Docker's own grammar, from that CLI's published
   command reference. *)
let run_constraint_argv backend guest_constraint =
  match backend, guest_constraint with
  | Apple_container, Drop_all_capabilities -> Expressed [ "--cap-drop"; "ALL" ]
  | Apple_container, Read_only_rootfs -> Expressed [ "--read-only" ]
  | Apple_container, Remove_on_exit -> Expressed [ "--rm" ]
  | Microsandbox, Drop_all_capabilities ->
    Not_expressible
      "msb 0.6.16 run has no --cap-drop. Its `--security restricted` is the \
       only candidate and its help does not say what that drops, so it is not \
       substituted for a guarantee asked for by name"
  | Microsandbox, Read_only_rootfs ->
    Not_expressible "msb 0.6.16 run has no --read-only"
  | Microsandbox, Remove_on_exit ->
    Not_expressible
      "msb spells --rm as a rootfs path to hide before boot rather than \
       remove-on-exit, so passing it would consume the guest name as its value"
  | Nerdctl_kata, Drop_all_capabilities -> Expressed [ "--cap-drop"; "ALL" ]
  | Nerdctl_kata, Read_only_rootfs -> Expressed [ "--read-only" ]
  | Nerdctl_kata, Remove_on_exit -> Expressed [ "--rm" ]
;;

(* [msb run] and [msb exec] read the first bare word after their options as
   another option and stop; the command has to follow [--]. Measured 0.6.16,
   2026-09-04: `msb run alpine tail -f /dev/null` answers "unexpected argument
   'tail' found", and with [--] the guest's own [tail] answers instead. Apple
   and nerdctl take the command bare. *)
let command_separator = function
  | Apple_container | Nerdctl_kata -> []
  | Microsandbox -> [ "--" ]
;;

(* [container exec] and [nerdctl exec] take Docker's [-i]; [msb exec] rejects
   both [-i] and [--interactive] and spells the same thing [--stream], which
   its help describes as streaming stdin and stdout without a PTY. *)
let exec_stdin_args = function
  | Apple_container | Nerdctl_kata -> [ "-i" ]
  | Microsandbox -> [ "--stream" ]
;;
