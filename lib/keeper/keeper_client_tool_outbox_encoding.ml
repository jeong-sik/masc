(* Compare the existing JSON values directly instead of keeping a second
   serialized copy of every distinct response as a grouping key. Float bits
   distinguish signed zero (and distinct NaN payloads) so sharing never
   changes a numeric value's representation. *)
let rec compare_json (left : Yojson.Safe.t) (right : Yojson.Safe.t) =
  match left, right with
  | `Float left, `Float right -> Int64.compare (Int64.bits_of_float left) (Int64.bits_of_float right)
  | `Assoc left, `Assoc right -> compare_fields left right
  | `List left, `List right -> compare_values left right
  | _ -> Stdlib.compare left right
and compare_fields left right =
  match left, right with
  | [], [] -> 0
  | [], _ :: _ -> -1
  | _ :: _, [] -> 1
  | (left_name, left_value) :: left_rest, (right_name, right_value) :: right_rest ->
    let name_order = String.compare left_name right_name in
    if name_order <> 0 then name_order else
    let value_order = compare_json left_value right_value in
    if value_order <> 0 then value_order else compare_fields left_rest right_rest
and compare_values left right =
  match left, right with
  | [], [] -> 0
  | [], _ :: _ -> -1
  | _ :: _, [] -> 1
  | left :: left_rest, right :: right_rest ->
    let order = compare_json left right in
    if order <> 0 then order else compare_values left_rest right_rest

module Json_map = Map.Make(struct type t = Yojson.Safe.t let compare = compare_json end)

type t =
  | Individual of string
  | Shared of string

type reference =
  { shared_index : int
  ; call_id : string
  ; host_invocation_index : int option
  }

let shared_description =
  "The JSON is losslessly shared: each receipts row is \
   [shared_index, call_id] or [shared_index, call_id, host_invocation_index]. \
   A row represents one distinct receipt: copy the zero-based shared object \
   at shared_index, add call_id, and add host_invocation_index when present.\n"

type grouped =
  { indices : int Json_map.t
  ; shared_rev : Yojson.Safe.t list
  ; receipts_rev : reference list
  ; next_index : int
  ; has_shared : bool
  }

let unique_field name fields =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [(_, value)] -> Some value
  | [] | _ :: _ -> None

let add_valid_receipt grouped fields call_id host_invocation_index =
  let shared = `Assoc (List.filter (fun (key, _) ->
    not (String.equal key "call_id" || String.equal key "host_invocation_index")) fields) in
  let index, indices, shared_rev, next_index, has_shared =
    match Json_map.find_opt shared grouped.indices with
    | Some index -> index, grouped.indices, grouped.shared_rev, grouped.next_index, true
    | None ->
      grouped.next_index, Json_map.add shared grouped.next_index grouped.indices,
      shared :: grouped.shared_rev, grouped.next_index + 1, grouped.has_shared in
  let receipt = {shared_index=index; call_id; host_invocation_index} in
  Some {indices; shared_rev; receipts_rev=receipt :: grouped.receipts_rev; next_index; has_shared}

let add_receipt grouped = function
  | `Assoc fields ->
    let call_id = unique_field "call_id" fields in
    let physical_index = unique_field "host_invocation_index" fields in
    let index_fields = List.filter (fun (key, _) -> String.equal key "host_invocation_index") fields in
    (match call_id, physical_index, index_fields with
     | Some (`String id), None, [] -> add_valid_receipt grouped fields id None
     | Some (`String id), Some (`Int index), [_] -> add_valid_receipt grouped fields id (Some index)
     | _ -> None)
  | _ -> None

let saturating_add left right =
  if right > max_int - left then max_int else left + right

let saturating_multiply left right =
  if left = 0 || right = 0 then 0
  else if left > max_int / right then max_int else left * right

let json_size buffer json =
  Buffer.clear buffer;
  Yojson.Safe.to_buffer buffer json;
  Buffer.length buffer

let reference_json receipt =
  `List ([`Int receipt.shared_index; `String receipt.call_id]
    @ Option.to_list (Option.map (fun index -> `Int index) receipt.host_invocation_index))

let identity_json receipt =
  `Assoc (["call_id", `String receipt.call_id]
    @ Option.to_list (Option.map (fun index -> "host_invocation_index", `Int index)
        receipt.host_invocation_index))

let encode rows =
  let individual () = Individual (Yojson.Safe.to_string (`List rows)) in
  let initial = {indices=Json_map.empty; shared_rev=[]; receipts_rev=[]; next_index=0; has_shared=false} in
  let grouped = List.fold_left (fun state row -> Option.bind state (fun state -> add_receipt state row))
      (Some initial) rows in
  match grouped with
  | None -> individual ()
  | Some grouped when not grouped.has_shared -> individual ()
  | Some grouped ->
    let shared = List.rev grouped.shared_rev and receipts = List.rev grouped.receipts_rev in
    let counts = Array.make grouped.next_index 0 in
    List.iter (fun receipt -> counts.(receipt.shared_index) <- counts.(receipt.shared_index) + 1) receipts;
    let scratch = Buffer.create 0 in
    (* One copy of each common object occurs in both representations, and the
       receipt-array separators cancel. Only repeated copies contribute to
       the size difference, so unique large results need not be serialized to
       decide whether the shared representation is smaller. *)
    let shared_info = Array.of_list (List.mapi (fun index json ->
      let has_fields = match json with `Assoc [] -> false | _ -> true in
      let duplicates = counts.(index) - 1 in
      let saved = if duplicates = 0 then 0 else
        saturating_multiply duplicates (json_size scratch json) in
      has_fields, saved) shared) in
    let empty = `Assoc ["shared", `List []; "receipts", `List []] in
    let packed_base = saturating_add (String.length (Yojson.Safe.to_string empty))
      (saturating_add (Array.length shared_info - 1) (String.length shared_description)) in
    let individually, packed = List.fold_left (fun (individual, packed) receipt ->
      let has_fields, _ = shared_info.(receipt.shared_index) in
      let identity_size = json_size scratch (identity_json receipt) in
      let identity_bytes = saturating_add (identity_size - 2) (if has_fields then 1 else 0) in
      saturating_add individual identity_bytes,
      saturating_add packed (json_size scratch (reference_json receipt))) (2, packed_base) receipts in
    let individually = Array.fold_left (fun size (_, saved) -> saturating_add size saved)
      individually shared_info in
    Buffer.reset scratch;
    if packed < individually then
      Shared (Yojson.Safe.to_string (`Assoc
        ["shared", `List shared; "receipts", `List (List.map reference_json receipts)]))
    else individual ()
