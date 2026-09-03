(** See .mli for the contract. *)

type t =
  | Apple_container
  | Microsandbox

let to_string = function
  | Apple_container -> "apple_container"
  | Microsandbox -> "microsandbox"
;;

(* Issue #8467 shape: [all] and [to_string] are the two places a constructor
   has to appear, and [valid_strings] is derived from them rather than typed
   again, so a backend added later cannot be half-registered. *)
let all = [ Apple_container; Microsandbox ]
let valid_strings = List.map to_string all
let of_string raw = List.find_opt (fun b -> String.equal (to_string b) raw) all

let cli_name = function
  | Apple_container -> "container"
  | Microsandbox -> "msb"
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
