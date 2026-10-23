(** Worker bridge that runs one retained verifier review attempt. *)

module AR = Task.Anti_rationalization
module O = Verifier_review_owner
module V = Verifier_review_original

let ( let* ) = Result.bind

type error =
  | Original_not_found
  | Original_corrupt of string
  | Grants_mismatch of string
  | Review_failed of string

let map_load_error (err : O.load_error) : error =
  match err with
  | O.Not_found -> Original_not_found
  | O.Load_store_unavailable detail ->
    Original_corrupt ("owner store unavailable: " ^ detail)
  | O.Corrupt_original detail -> Original_corrupt detail

(* The immutable original froze the reviewer's lookup grants at prepare time:
   the tool names [lookup_schemas] and the [lookup_root] it was built against.
   A caller that passes a [lookup] surface or [lookup_root] differing from
   those frozen grants is trying to widen the reviewer's reach beyond what the
   original authorised; the review must not run. [AR.review] only names tools
   from [lookup.schemas] in its prompt, so comparing the caller's surface
   names and root against the original's is exactly the check that preserves
   the frozen grants. *)
let check_grants ~original ~(lookup : AR.lookup_surface) ~lookup_root =
  let frozen_schemas = V.lookup_schemas original in
  let caller_schemas = List.map (fun (s : Types_core.tool_schema) -> s.name) lookup.schemas in
  if caller_schemas <> frozen_schemas
  then
    Error
      (Grants_mismatch
         (Printf.sprintf
            "lookup schemas differ: frozen [%s] vs caller [%s]"
            (String.concat ", " frozen_schemas)
            (String.concat ", " caller_schemas)))
  else (
    let frozen_root = V.lookup_root original in
    if frozen_root <> lookup_root
    then Error (Grants_mismatch "lookup_root differs from the original's frozen root")
    else Ok ())

let run_attempt
    ?on_verdict
    ?on_tool_result
    ?sw
    ~store
    ~verification_id
    ~attempt
    ~installation_id
    ~package_id
    ~question
    ~lookup
    ~lookup_root
    ~provider_rest
    ~base_path
    ()
  =
  (* The worker only runs the review the host already prepared. The retained
     original is the decision's fixed input; the caller's [lookup] surface and
     [lookup_root] must be exactly the grants the original froze. Nothing here
     extracts a verdict, calls a verdict tool, or advances a Task or Goal. *)
  let* original =
    O.load ~store ~verification_id ~attempt
    |> Result.map_error map_load_error
  in
  let* () = check_grants ~original ~lookup ~lookup_root in
  let req = V.review_request original in
  let result =
    AR.review
      ?on_verdict
      ?on_tool_result
      ?sw
      ~question
      ~lookup
      ~lookup_root
      ~provider_rest
      ~base_path
      req
  in
  Ok result
