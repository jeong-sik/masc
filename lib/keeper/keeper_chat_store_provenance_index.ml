open Keeper_chat_store_row_codec
open Keeper_chat_store_delivery_rules

type scanned_provenance =
  | No_provenance
  | Valid_provenance of
      Keeper_chat_delivery_identity.delivery_provenance * string
  | Poisoned_delivery_key of
      Keeper_chat_delivery_identity.delivery_key * string

let provenance_of_line ~line_number line =
  let fail detail = Error (Printf.sprintf
    "keeper chat provenance decode failed at line %d: %s" line_number detail) in
  try
    match Yojson.Safe.from_string line with
    | `Assoc fields ->
      let open Result.Syntax in
      let* () = match validate_row_fields fields with
        | Ok () -> Ok () | Error detail -> fail detail in
      (match Keeper_chat_delivery_identity.delivery_provenance_of_fields fields with
       | Error detail -> fail detail
       | Ok None -> Ok No_provenance
       | Ok (Some provenance) ->
         (match validate_delivery_fields ~provenance fields with
          | Error detail -> Ok (Poisoned_delivery_key (provenance.delivery_key, detail))
          | Ok () ->
            match List.assoc_opt "id" fields with
            | Some (`String row_id) when String.trim row_id <> "" ->
              Ok (Valid_provenance (provenance, row_id))
            | _ -> fail "provenance row requires a nonblank id"))
    | _ -> fail "row must be a JSON object"
  with Yojson.Json_error detail -> fail detail
;;

module Provenance_key = struct
  type t = Keeper_chat_delivery_identity.delivery_provenance

  let equal = Keeper_chat_delivery_identity.delivery_provenance_equal
  let hash = Hashtbl.hash
end

module Provenance_index = Hashtbl.Make (Provenance_key)

module Delivery_key = struct
  type t = Keeper_chat_delivery_identity.delivery_key

  let equal = Keeper_chat_delivery_identity.delivery_key_equal
  let hash = Hashtbl.hash
end

module Poisoned_delivery_keys = Hashtbl.Make (Delivery_key)

module Tool_ordinal = struct
  type t = Keeper_chat_delivery_identity.delivery_key * int

  let equal (left_key, left_ordinal) (right_key, right_ordinal) =
    Keeper_chat_delivery_identity.delivery_key_equal left_key right_key
    && Int.equal left_ordinal right_ordinal
  ;;

  let hash = Hashtbl.hash
end

module Tool_ordinal_index = Hashtbl.Make (Tool_ordinal)

module Execution_id_key = struct
  type t = Ids.Execution_id.t

  let equal = Ids.Execution_id.equal
  let hash = Hashtbl.hash
end

module Execution_index = Hashtbl.Make (Execution_id_key)

type indexed_provenance =
  | Unique_provenance of string
  | Duplicate_provenance

type indexed_tool_ordinal =
  | Unique_tool_ordinal of
      Keeper_chat_delivery_identity.transcript_slot * string
  | Duplicate_tool_ordinal

type execution_owner =
  { delivery_key : Keeper_chat_delivery_identity.delivery_key
  ; ordinal : int
  }

type indexed_execution =
  | Unique_execution of execution_owner
  | Reused_execution

type indexed_autonomous_inputs =
  | Tools_without_input_binding
  | Bound_inputs of Keeper_chat_delivery_identity.approval_input_binding list
  | Conflicting_input_bindings

type autonomous_input_index = indexed_autonomous_inputs Poisoned_delivery_keys.t

type provenance_index =
  { valid : indexed_provenance Provenance_index.t
  ; poisoned_delivery_keys : string Poisoned_delivery_keys.t
  ; tool_ordinals : indexed_tool_ordinal Tool_ordinal_index.t
  ; executions : indexed_execution Execution_index.t
  ; autonomous_inputs : autonomous_input_index
  }

let poison_delivery_key index delivery_key detail =
  Poisoned_delivery_keys.replace index.poisoned_delivery_keys delivery_key detail
;;

let execution_owner_matches owner ~delivery_key ~ordinal =
  Keeper_chat_delivery_identity.delivery_key_equal owner.delivery_key delivery_key
  && Int.equal owner.ordinal ordinal
;;

let register_execution_identity index ~delivery_key ~ordinal execution_id =
  match Execution_index.find_opt index.executions execution_id with
  | None ->
    Execution_index.add index.executions execution_id
      (Unique_execution { delivery_key; ordinal })
  | Some (Unique_execution owner)
    when execution_owner_matches owner ~delivery_key ~ordinal ->
    ()
  | Some (Unique_execution owner) ->
    let detail =
      "canonical Keeper execution_id is reused by a different delivery or tool ordinal"
    in
    poison_delivery_key index owner.delivery_key detail;
    poison_delivery_key index delivery_key detail;
    Execution_index.replace index.executions execution_id Reused_execution
  | Some Reused_execution ->
    poison_delivery_key index delivery_key
      "canonical Keeper execution_id is already reused by multiple deliveries or tool ordinals"
;;

let register_autonomous_inputs index provenance =
  match provenance.Keeper_chat_delivery_identity.delivery_key with
  | Keeper_chat_delivery_identity.Autonomous_turn _ ->
    let key = provenance.delivery_key in
    (match provenance.transcript_slot with
     | Keeper_chat_delivery_identity.Autonomous_input_binding inputs ->
       (match Poisoned_delivery_keys.find_opt index.autonomous_inputs key with
        | None | Some Tools_without_input_binding ->
          Poisoned_delivery_keys.replace index.autonomous_inputs key (Bound_inputs inputs)
        | Some (Bound_inputs _ | Conflicting_input_bindings) ->
          Poisoned_delivery_keys.replace index.autonomous_inputs key Conflicting_input_bindings;
          poison_delivery_key index key "duplicate autonomous input binding rows")
     | Keeper_chat_delivery_identity.Tool_call _ | Tool_delivery _ ->
       if not (Poisoned_delivery_keys.mem index.autonomous_inputs key) then
         Poisoned_delivery_keys.add index.autonomous_inputs key Tools_without_input_binding
     | Keeper_chat_delivery_identity.Accepted_user | Terminal_result | Settled_failure
     | Approval_request | Approval_resolution | Approval_replay | Approval_replay_correction
     | Approval_continuation -> ())
  | Keeper_chat_delivery_identity.Operation _ | Operation_checkpoint _ | Operation_native _
  | Fusion_run _ | Workspace_message _ | Connector_message _ | Approval_lifecycle _ -> ()
;;

let provenance_index_of_existing existing =
  let index =
    { valid = Provenance_index.create 16
    ; poisoned_delivery_keys = Poisoned_delivery_keys.create 16
    ; tool_ordinals = Tool_ordinal_index.create 16
    ; executions = Execution_index.create 16
    ; autonomous_inputs = Poisoned_delivery_keys.create 16
    }
  in
  let add_provenance (provenance, row_id) =
    register_autonomous_inputs index provenance;
    (match Provenance_index.find_opt index.valid provenance with
     | None ->
       Provenance_index.add index.valid provenance (Unique_provenance row_id)
     | Some (Unique_provenance _ | Duplicate_provenance) ->
       Provenance_index.replace index.valid provenance Duplicate_provenance;
       poison_delivery_key index provenance.delivery_key
         "duplicate Keeper chat delivery provenance rows");
    let ordinal =
      match provenance.Keeper_chat_delivery_identity.transcript_slot with
      | Keeper_chat_delivery_identity.Tool_call { ordinal; _ }
      | Keeper_chat_delivery_identity.Tool_delivery { ordinal } -> Some ordinal
      | Keeper_chat_delivery_identity.Accepted_user
      | Keeper_chat_delivery_identity.Terminal_result
      | Keeper_chat_delivery_identity.Settled_failure
      | Keeper_chat_delivery_identity.Approval_request
      | Keeper_chat_delivery_identity.Approval_resolution
      | Keeper_chat_delivery_identity.Approval_replay
      | Keeper_chat_delivery_identity.Approval_replay_correction
      | Keeper_chat_delivery_identity.Approval_continuation
      | Keeper_chat_delivery_identity.Autonomous_input_binding _ -> None
    in
    Option.iter
      (fun ordinal ->
         let key = provenance.delivery_key, ordinal in
         match Tool_ordinal_index.find_opt index.tool_ordinals key with
         | None ->
           Tool_ordinal_index.add
             index.tool_ordinals
             key
             (Unique_tool_ordinal (provenance.transcript_slot, row_id))
         | Some (Unique_tool_ordinal _ | Duplicate_tool_ordinal) ->
           Tool_ordinal_index.replace
             index.tool_ordinals
             key
             Duplicate_tool_ordinal;
           poison_delivery_key index provenance.delivery_key
             "duplicate Keeper chat tool ordinal rows")
      ordinal;
    match provenance.transcript_slot with
    | Keeper_chat_delivery_identity.Tool_call { execution_id; ordinal } ->
      register_execution_identity index ~delivery_key:provenance.delivery_key
        ~ordinal execution_id
    | Keeper_chat_delivery_identity.Accepted_user
    | Keeper_chat_delivery_identity.Tool_delivery _
    | Keeper_chat_delivery_identity.Terminal_result
    | Keeper_chat_delivery_identity.Settled_failure
    | Keeper_chat_delivery_identity.Approval_request
    | Keeper_chat_delivery_identity.Approval_resolution
    | Keeper_chat_delivery_identity.Approval_replay
    | Keeper_chat_delivery_identity.Approval_replay_correction
    | Keeper_chat_delivery_identity.Approval_continuation
      | Keeper_chat_delivery_identity.Autonomous_input_binding _ -> ()
  in
  existing
  |> String.split_on_char '\n'
  |> List.mapi (fun offset line -> offset + 1, line)
  |> List.fold_left
       (fun result (line_number, line) ->
          let open Result.Syntax in
          let* () = result in
          if String.equal line ""
          then Ok ()
          else
            let* provenance = provenance_of_line ~line_number line in
            (match provenance with
             | No_provenance -> ()
             | Valid_provenance (provenance, row_id) ->
               add_provenance (provenance, row_id)
             | Poisoned_delivery_key (delivery_key, detail) ->
               Poisoned_delivery_keys.replace
                 index.poisoned_delivery_keys
                 delivery_key
                 detail);
            Ok ())
       (Ok ())
  |> Result.map (fun () ->
       Poisoned_delivery_keys.iter (fun key -> function
         | Tools_without_input_binding ->
           poison_delivery_key index key "autonomous tool rows have no input binding"
         | Bound_inputs _ | Conflicting_input_bindings -> ()) index.autonomous_inputs;
       index)
;;

let validate_indexed_autonomous_inputs index ~delivery_key inputs =
  let open Result.Syntax in
  let* () = Keeper_chat_delivery_identity.validate_approval_input_bindings inputs in
  match delivery_key with
  | Keeper_chat_delivery_identity.Autonomous_turn _ ->
    (match Poisoned_delivery_keys.find_opt index.poisoned_delivery_keys delivery_key with
     | Some detail -> Error ("autonomous input binding is quarantined: " ^ detail)
     | None ->
       match Poisoned_delivery_keys.find_opt index.autonomous_inputs delivery_key with
       | None -> Ok ()
       | Some (Bound_inputs existing) ->
         if Keeper_chat_delivery_identity.approval_input_bindings_equal existing inputs
         then Ok () else Error "autonomous turn has a different ordered approval input binding"
       | Some Tools_without_input_binding -> Error "autonomous tool rows have no input binding"
       | Some Conflicting_input_bindings -> Error "autonomous turn has conflicting input bindings")
  | Keeper_chat_delivery_identity.Operation _ | Operation_checkpoint _ | Operation_native _
  | Fusion_run _ | Workspace_message _ | Connector_message _ | Approval_lifecycle _ ->
    Error "approval input binding requires an autonomous turn owner"
;;

(* The read every append-once delivery runs before it writes. A row this reads
   as an error refuses every later delivery to the keeper, so the deploy
   preflight asks the same question of a transcript on disk. *)
let transcript_provenance_readable existing =
  provenance_index_of_existing existing |> Result.map (fun (_ : provenance_index) -> ())
;;

let find_indexed_provenance index ~provenance =
  let open Result.Syntax in
  let* () = validate_delivery_slot_owner provenance in
  match
    Poisoned_delivery_keys.find_opt
      index.poisoned_delivery_keys
      provenance.Keeper_chat_delivery_identity.delivery_key
  with
  | Some detail ->
    Error
      (Printf.sprintf
         "Keeper chat delivery key has quarantined invalid provenance: %s"
         detail)
  | None ->
    let execution_identity_available =
      match provenance.Keeper_chat_delivery_identity.transcript_slot with
      | Keeper_chat_delivery_identity.Tool_call { execution_id; ordinal } ->
        (match Execution_index.find_opt index.executions execution_id with
         | None -> Ok ()
         | Some (Unique_execution owner)
           when execution_owner_matches owner
                  ~delivery_key:provenance.delivery_key
                  ~ordinal ->
           Ok ()
         | Some (Unique_execution _) ->
           Error
             "canonical Keeper execution_id belongs to a different delivery or tool ordinal"
         | Some Reused_execution ->
           Error
             "canonical Keeper execution_id is reused by multiple deliveries or tool ordinals")
      | Keeper_chat_delivery_identity.Accepted_user
      | Keeper_chat_delivery_identity.Tool_delivery _
      | Keeper_chat_delivery_identity.Terminal_result
      | Keeper_chat_delivery_identity.Settled_failure
      | Keeper_chat_delivery_identity.Approval_request
      | Keeper_chat_delivery_identity.Approval_resolution
      | Keeper_chat_delivery_identity.Approval_replay
      | Keeper_chat_delivery_identity.Approval_replay_correction
      | Keeper_chat_delivery_identity.Approval_continuation
      | Keeper_chat_delivery_identity.Autonomous_input_binding _ -> Ok ()
    in
    let open Result.Syntax in
    let* () = execution_identity_available in
    let ordinal =
      match provenance.Keeper_chat_delivery_identity.transcript_slot with
      | Keeper_chat_delivery_identity.Tool_call { ordinal; _ }
      | Keeper_chat_delivery_identity.Tool_delivery { ordinal } -> Some ordinal
      | Keeper_chat_delivery_identity.Accepted_user
      | Keeper_chat_delivery_identity.Terminal_result
      | Keeper_chat_delivery_identity.Settled_failure
      | Keeper_chat_delivery_identity.Approval_request
      | Keeper_chat_delivery_identity.Approval_resolution
      | Keeper_chat_delivery_identity.Approval_replay
      | Keeper_chat_delivery_identity.Approval_replay_correction
      | Keeper_chat_delivery_identity.Approval_continuation
      | Keeper_chat_delivery_identity.Autonomous_input_binding _ -> None
    in
    (match
       Option.bind ordinal (fun ordinal ->
         Tool_ordinal_index.find_opt
           index.tool_ordinals
           (provenance.delivery_key, ordinal))
     with
     | Some (Unique_tool_ordinal (existing_slot, row_id)) ->
       if
         Keeper_chat_delivery_identity.transcript_slot_equal
           existing_slot
           provenance.transcript_slot
       then Ok (Some row_id)
       else
         Error
           "Keeper chat tool ordinal is occupied by a conflicting execution identity"
     | Some Duplicate_tool_ordinal ->
       Error "duplicate Keeper chat tool ordinal rows"
     | None ->
       (match Provenance_index.find_opt index.valid provenance with
        | None -> Ok None
        | Some (Unique_provenance row_id) -> Ok (Some row_id)
        | Some Duplicate_provenance ->
          Error "duplicate Keeper chat delivery provenance rows"))
;;

let find_provenance existing ~provenance =
  let open Result.Syntax in
  let* index = provenance_index_of_existing existing in
  find_indexed_provenance index ~provenance
;;
