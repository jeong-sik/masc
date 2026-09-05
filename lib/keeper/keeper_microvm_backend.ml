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
  | Scratch_tmpfs

let all_guest_constraints =
  [ Drop_all_capabilities; Read_only_rootfs; Remove_on_exit; Scratch_tmpfs ]
;;

let guest_constraint_to_string = function
  | Drop_all_capabilities -> "drop_all_capabilities"
  | Read_only_rootfs -> "read_only_rootfs"
  | Remove_on_exit -> "remove_on_exit"
  | Scratch_tmpfs -> "scratch_tmpfs"
;;

(* Where the guest's shim makes a boxed request's scratch (RFC-0422). The
   boot mounts an in-memory filesystem here, and it is the shim's own
   default when its config names no [scratch_root]; one constant on both
   sides, so the two cannot drift apart without the host writing a key an
   older shim would refuse. *)
let scratch_guest_root = Exec_ssh_protocol.default_scratch_root

type constraint_class =
  | Isolation
  | Lifecycle
  | Observation

(* Losing an [Isolation] guarantee hands the keeper a weaker sandbox than the
   profile it declared, so the boot refuses instead of running without it.
   Losing the [Lifecycle] one does not: teardown removes the guest through
   [delete_force_argv_for] whether or not the runtime removes it on exit, so
   the boot records the drop on the guest and continues. Losing the
   [Observation] one costs the observe lane and nothing else: the shim
   answers an observe request with observe_scratch_error when it cannot make
   its scratch and the gate hands that request to the judge, so the boot
   records the drop the same way and continues. The split is data because
   the alternative is a branch each new backend's author has to remember to
   write. *)
let constraint_class = function
  | Drop_all_capabilities -> Isolation
  | Read_only_rootfs -> Isolation
  | Remove_on_exit -> Lifecycle
  | Scratch_tmpfs -> Observation
;;

type constraint_argv =
  | Expressed of string list
  | Not_expressible of string

(* Twelve arms, one per pair. No catch-all: a fourth runtime has to answer
   each guarantee separately, which is the question this table exists to ask.
   Apple's spellings were accepted by a live [container run] 1.3.0 on
   2026-08-28; the [msb] refusals were read from [msb run --help] on 0.6.16
   (2026-09-04) and confirmed by clap rejecting the flag before doing any
   work; nerdctl's are Docker's own grammar, from that CLI's published
   command reference.

   The scratch mount, measured 2026-09-05 on container 1.3.1 with
   [--user 501:20 --read-only]: [--tmpfs /tmp] comes up as tmpfs rw, mode
   1777 owned by root, sized by the kernel at half the guest's memory (551M
   on the default guest); mkdir and a write as 501:20 succeed and the rootfs
   still refuses. No size is passed: the guest's memory is already the
   operator's knob and the kernel's half is a function of it, so a second
   number here would be one the lane has not measured a need for.
   ([--tmpfs /tmp:size=64m] is accepted and [--tmpfs /tmp:64m] is refused
   with errno 22, so a bound, if one is ever wanted, is spelled Docker's
   way.) nerdctl's reference documents the same grammar
   ([--tmpfs /tmp:size=64m,exec]). *)
let run_constraint_argv backend guest_constraint =
  match backend, guest_constraint with
  | Apple_container, Drop_all_capabilities -> Expressed [ "--cap-drop"; "ALL" ]
  | Apple_container, Read_only_rootfs -> Expressed [ "--read-only" ]
  | Apple_container, Remove_on_exit -> Expressed [ "--rm" ]
  | Apple_container, Scratch_tmpfs -> Expressed [ "--tmpfs"; scratch_guest_root ]
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
  | Microsandbox, Scratch_tmpfs ->
    Not_expressible
      "msb 0.6.16 run documents --tmpfs PATH, PATH:SIZE and PATH:SIZE:OPTIONS, \
       but what mode the mount comes up with and whether the keeper's uid can \
       write it has not been measured, and msb does not boot under masc today"
  | Nerdctl_kata, Drop_all_capabilities -> Expressed [ "--cap-drop"; "ALL" ]
  | Nerdctl_kata, Read_only_rootfs -> Expressed [ "--read-only" ]
  | Nerdctl_kata, Remove_on_exit -> Expressed [ "--rm" ]
  | Nerdctl_kata, Scratch_tmpfs -> Expressed [ "--tmpfs"; scratch_guest_root ]
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
