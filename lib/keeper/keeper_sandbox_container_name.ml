type t = string

type spec =
  | Micro_vm_persistent of
      { keeper_name : string
      ; network_mode : Keeper_types_profile_sandbox.network_mode
      ; base_path : string
      }
  | Docker_persistent of
      { keeper_name : string
      ; network_mode : Keeper_types_profile_sandbox.network_mode
      ; base_path : string
      ; image : string
      }
  | Docker_oneshot of
      { keeper_name : string
      ; pid : int
      ; started_ms : int
      ; seq : int
      }
  | Docker_read of
      { keeper_name : string
      ; pid : int
      ; started_ms : int
      }
  | Docker_managed of
      { keeper_name : string
      ; network_mode : Keeper_types_profile_sandbox.network_mode
      ; pid : int
      ; started_ms : int
      ; seq : int
      }

(* apple/container [ManagedContainer.nameValid], unchanged from 1.3.1 to
   1.4.1: at most 63 characters (the DNS label length) and
   [^[a-zA-Z0-9][a-zA-Z0-9_.-]+$]. The other microVM runtimes are looser --
   msb 0.6.16 takes 128 bytes of the same characters and nerdctl, like
   Docker, bounds no length -- so a guest name Apple accepts is accepted by
   all three, and the name does not have to know which one boots it.

   The character rule needs no check here. Every segment is either a fixed
   prefix starting with a letter, [Workspace_utils.safe_filename] output
   ([a-z0-9._-], anything else escaped as [_xx]), a network mode word, an
   integer or lowercase hex. *)
let micro_vm_guest_max_length = 63

(* The base-path segment names the MASC instance, not a secret; eight hex
   characters is what both keeper-lifetime names have always carried. *)
let base_path_hash_segment_length = 8

(* The digest that stands in for the cut part of a guest name. Two guests
   collide only when their names keep the same prefix, mode, base-path hash
   and first keeper characters and their full names agree on these 64 bits.
   The names that coexist on one host are keepers x modes x base paths --
   hundreds -- so the birthday bound is far below one in a billion. A cut
   name cannot equal a name that was not cut, either: the uncut one has a
   separator nine characters from its end, where a cut one has digest hex. *)
let cut_name_digest_hex_length = 16

let separator = "-"

let base_path_segment base_path =
  String.sub
    (Keeper_sandbox_runtime_setup.base_path_hash base_path)
    0
    base_path_hash_segment_length
;;

let spell ~prefix ~keeper_segment ~qualifiers =
  String.concat separator (prefix :: keeper_segment :: qualifiers)
;;

(* A full name longer than [limit] keeps everything but the keeper segment,
   which is cut to the room left once the digest is appended. The cut name
   is exactly [limit] long.

   The room is never negative for a spec this module bounds: the only one is
   [Micro_vm_persistent], whose fixed part is "masc-keeper-vm" plus four
   separators, a mode word of at most seven characters, the base-path
   segment and the digest -- 49 characters, leaving at least 14 for the
   keeper. *)
let fit ~limit ~prefix ~keeper_segment ~qualifiers =
  let full = spell ~prefix ~keeper_segment ~qualifiers in
  if String.length full <= limit
  then full
  else (
    let digest =
      String.sub
        Digestif.SHA256.(digest_string full |> to_hex)
        0
        cut_name_digest_hex_length
    in
    let qualifiers = qualifiers @ [ digest ] in
    let room = limit - String.length (spell ~prefix ~keeper_segment:"" ~qualifiers) in
    spell ~prefix ~keeper_segment:(String.sub keeper_segment 0 room) ~qualifiers)
;;

let make spec =
  match spec with
  | Micro_vm_persistent { keeper_name; network_mode; base_path } ->
    fit
      ~limit:micro_vm_guest_max_length
      ~prefix:"masc-keeper-vm"
      ~keeper_segment:(Workspace_utils.safe_filename keeper_name)
      ~qualifiers:
        [ Keeper_types_profile_sandbox.network_mode_to_string network_mode
        ; base_path_segment base_path
        ]
  | Docker_persistent { keeper_name; network_mode; base_path; image } ->
    spell
      ~prefix:"masc-keeper-docker"
      ~keeper_segment:(Workspace_utils.safe_filename keeper_name)
      ~qualifiers:
        [ Keeper_types_profile_sandbox.network_mode_to_string network_mode
        ; base_path_segment base_path
        ; Digestif.SHA256.(digest_string image |> to_hex)
        ]
  | Docker_oneshot { keeper_name; pid; started_ms; seq } ->
    spell
      ~prefix:"masc-keeper"
      ~keeper_segment:(Workspace_utils.safe_filename keeper_name)
      ~qualifiers:[ string_of_int pid; string_of_int started_ms; string_of_int seq ]
  | Docker_read { keeper_name; pid; started_ms } ->
    spell
      ~prefix:"masc-keeper-read"
      ~keeper_segment:(Workspace_utils.safe_filename keeper_name)
      ~qualifiers:[ string_of_int pid; string_of_int started_ms ]
  | Docker_managed { keeper_name; network_mode; pid; started_ms; seq } ->
    spell
      ~prefix:"masc-keeper-managed"
      ~keeper_segment:(Workspace_utils.safe_filename keeper_name)
      ~qualifiers:
        [ Keeper_types_profile_sandbox.network_mode_to_string network_mode
        ; string_of_int pid
        ; string_of_int started_ms
        ; string_of_int seq
        ]
;;

let to_string name = name
