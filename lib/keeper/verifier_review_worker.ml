(** Worker bridge that runs one retained verifier review attempt. *)

module AR = Task.Anti_rationalization
module O = Verifier_review_owner

let ( let* ) = Result.bind

type error =
  | Original_not_found
  | Original_corrupt of string
  | Review_failed of string

let map_load_error (err : O.load_error) : error =
  match err with
  | O.Not_found -> Original_not_found
  | O.Store_unavailable detail -> Original_corrupt ("owner store unavailable: " ^ detail)
  | O.Corrupt_original detail -> Original_corrupt detail

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
  =
  (* The worker only runs the review the host already prepared. The retained
     original is the decision's fixed input; the host-built lookup surface and
     root are exactly the grants the original froze. Nothing here extracts a
     verdict, calls a verdict tool, or advances a Task or Goal. *)
  let* original =
    O.load ~store ~verification_id ~attempt
    |> Result.map_error map_load_error
  in
  let req = Verifier_review_original.review_request original in
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
