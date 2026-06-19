(** gh-backed external verifier for the grounding reconciler (RFC-0259 §3.3 P2).

    See the .mli. Every failure path collapses to [Unverifiable] so the reconciler
    never treats an unreachable/ambiguous ref as a contradiction. *)

open Keeper_memory_os_types
module R = Keeper_memory_os_reconcile

(* gh prints the state field as a bare JSON object: {"state":"MERGED"}. Read the
   [state] string; anything else (malformed, missing) is unverifiable. *)
let state_of_json_output (out : string) : string option =
  match Yojson.Safe.from_string (String.trim out) with
  | `Assoc fields ->
    (match List.assoc_opt "state" fields with
     | Some (`String s) -> Some (String.uppercase_ascii (String.trim s))
     | _ -> None)
  | _ | (exception _) -> None
;;

(* Map a gh state token to external_state. OPEN -> live; MERGED/CLOSED -> terminal
   (a claim treating the ref as in-progress is stale). Unknown token -> conservative
   Unverifiable (we do not invent a verdict for a state we do not model). *)
let external_state_of_token = function
  | "OPEN" -> R.Still_open
  | "MERGED" | "CLOSED" -> R.Terminal
  | _ -> R.Unverifiable
;;

(* The gh subcommand for a kind. [Task] (Jira/PK ids) has no gh source of truth,
   so it is never grounded here — returns [None] and the caller yields
   Unverifiable. *)
let gh_subcommand = function
  | Pr -> Some "pr"
  | Issue -> Some "issue"
  | Task -> None
;;

let verify_external
      ~(proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t)
      ~repo
      (r : external_ref)
  : R.external_state
  =
  match gh_subcommand r.kind with
  | None -> R.Unverifiable
  | Some sub ->
    let argv = [ "gh"; sub; "view"; r.id; "--repo"; repo; "--json"; "state" ] in
    (* parse_out manages its own switch (spawn/drain/await/reap) and raises on
       non-zero exit / spawn failure / read error; all of those mean "could not
       determine", never "contradicted", so they collapse to [Unverifiable]. *)
    (try
       let out = Eio.Process.parse_out proc_mgr Eio.Buf_read.take_all argv in
       match state_of_json_output out with
       | Some token -> external_state_of_token token
       | None -> R.Unverifiable
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ -> R.Unverifiable)
;;
