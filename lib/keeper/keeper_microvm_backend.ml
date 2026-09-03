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
