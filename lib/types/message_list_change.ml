type t =
  | Appended of
      { kept : int
      ; added : int
      }
  | Tail_removed of
      { kept : int
      ; removed : int
      }
  | Block_dropped of
      { at : int
      ; dropped : int
      ; kept_after : int
      ; added : int
      }
  | Rewritten_in_place of
      { first_index : int
      ; last_index : int
      ; rewritten : int
      ; previous_bytes : int
      ; current_bytes : int
      ; first_previous_role : Llm_provider.Types.role
      ; first_current_role : Llm_provider.Types.role
      ; added : int
      }
  | Diverged_at of
      { index : int
      ; previous_role : Llm_provider.Types.role
      ; previous_bytes : int
      ; current_role : Llm_provider.Types.role
      ; current_bytes : int
      ; previous_count : int
      ; current_count : int
      }

(* The JSON names of a message change. [to_json] writes them and [of_json]
   reads them back. *)
let kind_key = "kind"
let kept_key = "kept"
let added_key = "added"
let removed_key = "removed"
let at_key = "at"
let dropped_key = "dropped"
let kept_after_key = "kept_after"
let first_index_key = "first_index"
let last_index_key = "last_index"
let rewritten_key = "rewritten"
let previous_bytes_key = "previous_bytes"
let current_bytes_key = "current_bytes"
let first_previous_role_key = "first_previous_role"
let first_current_role_key = "first_current_role"
let index_key = "index"
let previous_role_key = "previous_role"
let current_role_key = "current_role"
let previous_count_key = "previous_count"
let current_count_key = "current_count"

(* A closed list of kinds, so a new shape does not compile until the writer
   and the reader both name it. *)
type kind =
  | Appended_kind
  | Tail_removed_kind
  | Block_dropped_kind
  | Rewritten_in_place_kind
  | Diverged_at_kind
[@@deriving enumerate]

let kind_of = function
  | Appended _ -> Appended_kind
  | Tail_removed _ -> Tail_removed_kind
  | Block_dropped _ -> Block_dropped_kind
  | Rewritten_in_place _ -> Rewritten_in_place_kind
  | Diverged_at _ -> Diverged_at_kind
;;

let kind_label = function
  | Appended_kind -> "appended"
  | Tail_removed_kind -> "tail_removed"
  | Block_dropped_kind -> "block_dropped"
  | Rewritten_in_place_kind -> "rewritten_in_place"
  | Diverged_at_kind -> "diverged_at"
;;

let role_json role = `String (Llm_provider.Types.role_to_string role)

let to_json change : Yojson.Safe.t =
  let fields =
    match change with
    | Appended { kept; added } -> [ kept_key, `Int kept; added_key, `Int added ]
    | Tail_removed { kept; removed } -> [ kept_key, `Int kept; removed_key, `Int removed ]
    | Block_dropped { at; dropped; kept_after; added } ->
      [ at_key, `Int at
      ; dropped_key, `Int dropped
      ; kept_after_key, `Int kept_after
      ; added_key, `Int added
      ]
    | Rewritten_in_place
        { first_index
        ; last_index
        ; rewritten
        ; previous_bytes
        ; current_bytes
        ; first_previous_role
        ; first_current_role
        ; added
        } ->
      [ first_index_key, `Int first_index
      ; last_index_key, `Int last_index
      ; rewritten_key, `Int rewritten
      ; previous_bytes_key, `Int previous_bytes
      ; current_bytes_key, `Int current_bytes
      ; first_previous_role_key, role_json first_previous_role
      ; first_current_role_key, role_json first_current_role
      ; added_key, `Int added
      ]
    | Diverged_at
        { index
        ; previous_role
        ; previous_bytes
        ; current_role
        ; current_bytes
        ; previous_count
        ; current_count
        } ->
      [ index_key, `Int index
      ; previous_role_key, role_json previous_role
      ; previous_bytes_key, `Int previous_bytes
      ; current_role_key, role_json current_role
      ; current_bytes_key, `Int current_bytes
      ; previous_count_key, `Int previous_count
      ; current_count_key, `Int current_count
      ]
  in
  `Assoc
    ((kind_key, `String (kind_label (kind_of change)))
     :: fields)
;;

let of_json (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let invalid key expected =
      Error (Printf.sprintf "message change field %s must be %s" key expected)
    in
    let count key =
      match List.assoc_opt key fields with
      | Some (`Int value) when value >= 0 -> Ok value
      | Some _ | None -> invalid key "a non-negative integer"
    in
    let role key =
      match List.assoc_opt key fields with
      | Some (`String label) ->
        (match Llm_provider.Types.role_of_string label with
         | Some role -> Ok role
         | None -> invalid key "a known message role")
      | Some _ | None -> invalid key "a message role"
    in
    let* kind =
      match List.assoc_opt kind_key fields with
      | Some (`String label) ->
        (match
           List.find_opt
             (fun kind -> String.equal (kind_label kind) label)
             all_of_kind
         with
         | Some kind -> Ok kind
         | None -> invalid kind_key (Printf.sprintf "a known kind, not %S" label))
      | Some _ | None -> invalid kind_key "a message change kind"
    in
    (match kind with
     | Appended_kind ->
       let* kept = count kept_key in
       let* added = count added_key in
       Ok (Appended { kept; added })
     | Tail_removed_kind ->
       let* kept = count kept_key in
       let* removed = count removed_key in
       Ok (Tail_removed { kept; removed })
     | Block_dropped_kind ->
       let* at = count at_key in
       let* dropped = count dropped_key in
       let* kept_after = count kept_after_key in
       let* added = count added_key in
       Ok (Block_dropped { at; dropped; kept_after; added })
     | Rewritten_in_place_kind ->
       let* first_index = count first_index_key in
       let* last_index = count last_index_key in
       let* rewritten = count rewritten_key in
       let* previous_bytes = count previous_bytes_key in
       let* current_bytes = count current_bytes_key in
       let* first_previous_role = role first_previous_role_key in
       let* first_current_role = role first_current_role_key in
       let* added = count added_key in
       Ok
         (Rewritten_in_place
            { first_index
            ; last_index
            ; rewritten
            ; previous_bytes
            ; current_bytes
            ; first_previous_role
            ; first_current_role
            ; added
            })
     | Diverged_at_kind ->
       let* index = count index_key in
       let* previous_role = role previous_role_key in
       let* previous_bytes = count previous_bytes_key in
       let* current_role = role current_role_key in
       let* current_bytes = count current_bytes_key in
       let* previous_count = count previous_count_key in
       let* current_count = count current_count_key in
       Ok
         (Diverged_at
            { index
            ; previous_role
            ; previous_bytes
            ; current_role
            ; current_bytes
            ; previous_count
            ; current_count
            }))
  | _ -> Error "a message change must be a JSON object"
;;
