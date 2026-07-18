(** Boot-pinned physical data root
    (RFC-checkpoint-pinned-root-containment PR-1, #25151). *)

type pin_error =
  | Root_unresolvable of
      { path : string
      ; detail : string
      }
  | Root_not_directory of { physical : string }
  | Repin_differs of
      { pinned : string
      ; requested_path : string
      ; requested_physical : string
      }

let pin_error_to_string = function
  | Root_unresolvable { path; detail } ->
    Printf.sprintf "data root %S is unresolvable: %s" path detail
  | Root_not_directory { physical } ->
    Printf.sprintf "data root resolves to non-directory %S" physical
  | Repin_differs { pinned; requested_path; requested_physical } ->
    Printf.sprintf
      "data root already pinned to %S; refusing repin to %S (physical %S)"
      pinned requested_path requested_physical

let root : string option Atomic.t = Atomic.make None

let pinned () = Atomic.get root

let clear_for_tests () = Atomic.set root None

let resolve path =
  try
    let physical = Unix.realpath path in
    if (Unix.stat physical).Unix.st_kind <> Unix.S_DIR
    then Error (Root_not_directory { physical })
    else Ok physical
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error (error, operation, argument) ->
    Error
      (Root_unresolvable
         { path
         ; detail =
             Printf.sprintf "%s(%s): %s" operation argument
               (Unix.error_message error)
         })
  | exn -> Error (Root_unresolvable { path; detail = Printexc.to_string exn })

(* CAS claim loop: the [None] arm after a failed CAS is only reachable when
   a concurrent [clear_for_tests] emptied the slot between the CAS and the
   read; production never clears, tests are sequential, so the loop is a
   correctness formality rather than a contended path. *)
let rec claim ~requested_path physical =
  if Atomic.compare_and_set root None (Some physical) then Ok physical
  else (
    match Atomic.get root with
    | Some existing when String.equal existing physical -> Ok physical
    | Some existing ->
      Error
        (Repin_differs
           { pinned = existing
           ; requested_path
           ; requested_physical = physical
           })
    | None -> claim ~requested_path physical)

let pin path =
  match resolve path with
  | Error _ as error -> error
  | Ok physical -> claim ~requested_path:path physical
