open Keeper_memory_os_types

type lifecycle =
  | Ephemeral
  | Working
  | Consolidated
  | Canonical
  | Superseded_by of string
  | Molted_to_archive

type invalid_transition =
  { from : lifecycle
  ; to_ : lifecycle
  ; reason : string
  }

let lifecycle_to_string = function
  | Ephemeral -> "ephemeral"
  | Working -> "working"
  | Consolidated -> "consolidated"
  | Canonical -> "canonical"
  | Superseded_by id -> "superseded_by:" ^ id
  | Molted_to_archive -> "molted_to_archive"
;;

let lifecycle_of_string raw =
  match raw with
  | "ephemeral" -> Some Ephemeral
  | "working" -> Some Working
  | "consolidated" -> Some Consolidated
  | "canonical" -> Some Canonical
  | "molted_to_archive" -> Some Molted_to_archive
  | _ ->
    let prefix = "superseded_by:" in
    let plen = String.length prefix in
    if String.length raw > plen && String.equal (String.sub raw 0 plen) prefix
    then (
      let target = String.sub raw plen (String.length raw - plen) in
      if String.equal (String.trim target) "" then None else Some (Superseded_by target))
    else None
;;

let invalid_transition_to_string { from; to_; reason } =
  Printf.sprintf "invalid lifecycle transition %s -> %s: %s"
    (lifecycle_to_string from) (lifecycle_to_string to_) reason
;;

let transition ~from ~to_ =
  match from, to_ with
  | (Superseded_by _ | Molted_to_archive), _ ->
    Error { from; to_; reason = "terminal lifecycle state cannot transition" }
  | _, Superseded_by target when String.equal (String.trim target) "" ->
    Error { from; to_; reason = "superseding target id must be non-blank" }
  | Ephemeral, (Working | Consolidated | Superseded_by _ | Molted_to_archive) -> Ok to_
  | Ephemeral, Ephemeral ->
    Error { from; to_; reason = "no-op self-transition" }
  | Ephemeral, Canonical ->
    Error { from; to_; reason = "ephemeral fact must consolidate or enter working before canonical" }
  | Working, (Consolidated | Canonical | Superseded_by _ | Molted_to_archive) -> Ok to_
  | Working, (Ephemeral | Working) ->
    Error { from; to_; reason = "lifecycle cannot regress or self-transition" }
  | Consolidated, (Canonical | Superseded_by _ | Molted_to_archive) -> Ok to_
  | Consolidated, (Ephemeral | Working | Consolidated) ->
    Error { from; to_; reason = "consolidated fact cannot regress or self-transition" }
  | Canonical, (Superseded_by _ | Molted_to_archive) -> Ok to_
  | Canonical, (Ephemeral | Working | Consolidated | Canonical) ->
    Error { from; to_; reason = "canonical fact can only be superseded or molted" }
;;

type molt_trigger =
  | Compaction_epoch_advanced of { epoch_id : int }
  | Synthesis_cycle_completed

let f_kind = wire_field_kind
let f_epoch_id = "epoch_id"

let molt_trigger_to_json = function
  | Compaction_epoch_advanced { epoch_id } ->
    `Assoc [ f_kind, `String "compaction_epoch_advanced"; f_epoch_id, `Int epoch_id ]
  | Synthesis_cycle_completed ->
    `Assoc [ f_kind, `String "synthesis_cycle_completed" ]
;;

let ( let* ) = Result.bind

let molt_trigger_of_json = function
  | `Assoc fields ->
    let* kind = wire_string_field f_kind fields in
    (match kind with
     | "compaction_epoch_advanced" ->
       let* () = exact_field_names_result [ f_kind; f_epoch_id ] fields in
       let* epoch_id = wire_int_field f_epoch_id fields in
       if epoch_id < 0
       then wire_fail [ Wire_field f_epoch_id ] Negative
       else Ok (Compaction_epoch_advanced { epoch_id })
     | "synthesis_cycle_completed" ->
       let* () = exact_field_names_result [ f_kind ] fields in
       Ok Synthesis_cycle_completed
     | other -> wire_fail [ Wire_field f_kind ] (Unknown_token other))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

type world_promotion =
  { source_fact_ids : string list
  ; claim : string
  ; category : category
  ; facets : string list
  ; scope : string
  }

let f_source_fact_ids = "source_fact_ids"
let f_claim = wire_field_claim
let f_category = wire_field_category
let f_facets = "facets"
let f_scope = "scope"

let world_promotion_fields = [ f_source_fact_ids; f_claim; f_category; f_facets; f_scope ]

let world_promotion_to_json (p : world_promotion) =
  `Assoc
    [ f_source_fact_ids, `List (List.map (fun id -> `String id) p.source_fact_ids)
    ; f_claim, `String p.claim
    ; f_category, `String (category_to_string p.category)
    ; f_facets, `List (List.map (fun f -> `String f) p.facets)
    ; f_scope, `String p.scope
    ]
;;

let decode_string_list field ~validate fields =
  let* items = wire_list_field field fields in
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | `String s :: rest ->
      let* v = wire_at_element field idx (validate s) in
      loop (idx + 1) (v :: acc) rest
    | (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null) :: _ ->
      wire_at_element field idx (wire_here Expected_string)
  in
  loop 0 [] items
;;

let world_promotion_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result world_promotion_fields fields in
    let* source_fact_ids =
      decode_string_list f_source_fact_ids
        ~validate:(fun id -> if is_memory_id id then Ok id else wire_here (Not_a_memory_id id))
        fields
    in
    let* () =
      match source_fact_ids with
      | [] -> wire_fail [ Wire_field f_source_fact_ids ] Empty_list
      | _ :: _ -> Ok ()
    in
    let* claim = wire_string_field f_claim fields in
    let* () =
      if String.equal (String.trim claim) ""
      then wire_fail [ Wire_field f_claim ] Blank_string
      else Ok ()
    in
    let* category_token = wire_string_field f_category fields in
    let* category =
      match category_of_string category_token with
      | Some c -> Ok c
      | None -> wire_fail [ Wire_field f_category ] (Unknown_token category_token)
    in
    let* facets =
      decode_string_list f_facets
        ~validate:(fun f ->
          if String.equal (String.trim f) "" then wire_here Blank_string else Ok f)
        fields
    in
    let* scope = wire_string_field f_scope fields in
    let* () =
      if String.equal (String.trim scope) ""
      then wire_fail [ Wire_field f_scope ] Blank_string
      else Ok ()
    in
    Ok { source_fact_ids; claim; category; facets; scope }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;
