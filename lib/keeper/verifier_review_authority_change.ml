(** What moved between a retained review original and the current authority. *)

open Result.Syntax

type pair = { before : string; after : string }

type t =
  | Authority of pair
  | Output_contract of pair
  | Both of { authority : pair; output_contract : pair }

let schema = "verifier_review_authority_change/v1"

let moved pair = not (String.equal pair.before pair.after)

let between ~authority ~output_contract =
  match moved authority, moved output_contract with
  | true, true -> Some (Both { authority; output_contract })
  | true, false -> Some (Authority authority)
  | false, true -> Some (Output_contract output_contract)
  | false, false -> None
;;

let pair_to_json pair = `Assoc [ "before", `String pair.before; "after", `String pair.after ]

let to_json t =
  let authority, output_contract =
    match t with
    | Authority authority -> pair_to_json authority, `Null
    | Output_contract output_contract -> `Null, pair_to_json output_contract
    | Both { authority; output_contract } -> pair_to_json authority, pair_to_json output_contract
  in
  `Assoc
    [ "schema", `String schema
    ; "authority", authority
    ; "output_contract", output_contract
    ]
;;

let exact_keys ~what expected fields =
  let keys = List.map fst fields in
  if List.length keys = List.length (List.sort_uniq String.compare keys)
     && List.sort String.compare keys = List.sort String.compare expected
  then Ok ()
  else Error (Printf.sprintf "%s has an unexpected field set" what)
;;

let field ~what key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s has no %s" what key)
;;

(* An absent pair is [None]; a present one must hold two valid values that
   differ, because an unmoved pair is not evidence of a change. *)
let pair_of_json ~what ~valid = function
  | `Null -> Ok None
  | `Assoc fields ->
    let* () = exact_keys ~what [ "before"; "after" ] fields in
    let* before = field ~what "before" fields in
    let* after = field ~what "after" fields in
    (match before, after with
     | `String before, `String after when valid before && valid after ->
       if String.equal before after
       then Error (Printf.sprintf "%s did not move" what)
       else Ok (Some { before; after })
     | _ -> Error (Printf.sprintf "%s values are invalid" what))
  | _ -> Error (Printf.sprintf "%s must be an object or null" what)
;;

let of_json = function
  | `Assoc fields ->
    let what = "verifier review authority change" in
    let* () = exact_keys ~what [ "schema"; "authority"; "output_contract" ] fields in
    let* () =
      match field ~what "schema" fields with
      | Ok (`String name) when String.equal name schema -> Ok ()
      | Ok _ | Error _ -> Error (what ^ " has an unknown schema")
    in
    let* authority =
      let* json = field ~what "authority" fields in
      pair_of_json ~what:"authority change" ~valid:String_util.is_lowercase_sha256_hex json
    in
    let* output_contract =
      let* json = field ~what "output_contract" fields in
      pair_of_json ~what:"answer format change" ~valid:(fun text -> String.trim text <> "") json
    in
    (match authority, output_contract with
     | Some authority, Some output_contract -> Ok (Both { authority; output_contract })
     | Some authority, None -> Ok (Authority authority)
     | None, Some output_contract -> Ok (Output_contract output_contract)
     | None, None -> Error (what ^ " names nothing that moved"))
  | _ -> Error "verifier review authority change must be an object"
;;

let to_string = function
  | Authority _ -> "the lookup authority changed before dispatch"
  | Output_contract _ -> "the answer format changed before dispatch"
  | Both _ -> "the lookup authority and the answer format changed before dispatch"
;;
