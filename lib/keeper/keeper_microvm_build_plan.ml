let build_volume_guest_root = "/masc-build"

let build_link_separator = ':'

let build_link_target ~playground_relative =
  let segments = String.split_on_char '/' playground_relative in
  let empty = List.exists (fun s -> String.equal s "") segments in
  let traversal = List.exists (fun s -> String.equal s "." || String.equal s "..") segments in
  let collides = String.contains playground_relative build_link_separator in
  if List.is_empty segments || empty
  then Error ("empty path segment in playground path: " ^ playground_relative)
  else if traversal
  then Error ("dot path segment in playground path: " ^ playground_relative)
  else if collides
  then
    Error
      (Printf.sprintf
         "playground path contains %c, which the build link uses as a separator: %s"
         build_link_separator
         playground_relative)
  else
    Ok
      (Filename.concat
         build_volume_guest_root
         (String.concat (String.make 1 build_link_separator) segments))
;;

(** What [_build] is right now, as far as the plan cares. *)
type build_link_state =
  | Build_absent
  | Build_symlink of string
  | Build_real_directory

type build_link_plan =
  | Link_create of string
  | Link_preserve_symlink of { existing : string; expected : string }
  | Link_already_correct
  | Link_refused_real_directory
  | Link_refused_invalid_path of { detail : string; state : build_link_state }

(** Deciding is separate from acting so the refusal is testable.

    The scan runs inside a live guest, where a keeper's build may be using a
    real [_build], so the plan never deletes one: the caller reports it and
    the checkout keeps building on the unified work volume until the next
    owned first handoff removes it
    ([Keeper_sandbox_microvm.first_handoff_build_cleanup_script]), unless the
    checkout holds [Keeper_sandbox_microvm.build_keep_marker]. A differently
    targeted symlink is preserved because this plan cannot prove it is ours. *)
let plan_build_link ~target = function
  | Build_absent -> Link_create target
  | Build_symlink existing when String.equal existing target -> Link_already_correct
  | Build_symlink existing -> Link_preserve_symlink { existing; expected = target }
  | Build_real_directory -> Link_refused_real_directory
;;

type build_scan_row =
  { checkout : string
  ; state : build_link_state
  }

(** Each scan record is three NUL-terminated fields: checkout, kind, target.
    Newlines and tabs can occur in paths or link targets and are data. Refuse
    the entire stream when framing is incomplete or a kind is unknown. *)
let build_scan_rows_of_output raw =
  if String.equal raw "" then Ok []
  else
    let rec parse rows = function
      | [ "" ] -> Ok (List.rev rows)
      | checkout :: "absent" :: "" :: rest when not (String.equal checkout "") ->
        parse ({ checkout; state = Build_absent } :: rows) rest
      | checkout :: "real" :: "" :: rest when not (String.equal checkout "") ->
        parse ({ checkout; state = Build_real_directory } :: rows) rest
      | checkout :: "symlink" :: target :: rest when not (String.equal checkout "") ->
        parse ({ checkout; state = Build_symlink target } :: rows) rest
      | _ -> Error "invalid or truncated build scan output"
    in
    parse [] (String.split_on_char '\000' raw)
;;

(** Every scanned checkout's target and plan, decided purely so the refusal
    stays testable (see {!plan_build_link}) -- deciding never touches the
    guest; only [Keeper_sandbox_microvm.build_link_apply_request_for] does. *)
type build_link_row =
  { checkout : string
  ; target : string option
  ; plan : build_link_plan
  }

let build_link_rows_of_scan rows =
  List.map
    (fun { checkout; state } ->
      match build_link_target ~playground_relative:checkout with
      | Error detail ->
        { checkout; target = None; plan = Link_refused_invalid_path { detail; state } }
      | Ok target -> { checkout; target = Some target; plan = plan_build_link ~target state })
    rows
;;

(** The [(checkout, target)] pairs a plan actually needs a guest command
    for. A row already correct, or refused, needs none. *)
let build_link_actions rows =
  List.filter_map
    (fun { checkout; target; plan } ->
      match plan, target with
      | Link_create _, Some target -> Some (checkout, target)
      | (Link_create _, None)
      | ((Link_already_correct | Link_preserve_symlink _ | Link_refused_real_directory | Link_refused_invalid_path _), _) -> None)
    rows
;;

(** Every target a link points at, or is about to: create actions plus rows
    already linked. The build volume is recreated empty
    on every fresh guest boot while the work volume keeps the old links, so a
    link that is already correct points at a directory that no longer exists
    until it is created again -- and dune does not create it
    ([Keeper_sandbox_microvm.build_target_mkdir_request]). *)
let build_link_targets rows =
  List.filter_map
    (fun { checkout = _; target; plan } ->
      match plan, target with
      | (Link_create _ | Link_already_correct), Some target -> Some target
      | (Link_create _ | Link_already_correct | Link_preserve_symlink _ | Link_refused_real_directory | Link_refused_invalid_path _), _ ->
        None)
    rows
;;
