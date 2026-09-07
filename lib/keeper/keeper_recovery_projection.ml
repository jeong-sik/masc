open Agent_core.Types
module Positions = Map.Make (Int)

type required_reason = User_instruction | Task_contract | Pending_continuation
[@@deriving yojson]
type requirement = { message_index : int; reason : required_reason }
[@@deriving yojson]
type atom =
  { atom_id : int
  ; first_message : int
  ; last_message : int
  ; requirements : requirement list
  ; pending_tool_cycle : bool
  }
[@@deriving yojson]
type indexed_atom = { description : atom; messages : message list }
type source = { reference : Keeper_checkpoint_ref.t; indexed : indexed_atom list }
type error =
  | Required_message_missing of int
  | Invalid_transcript of Keeper_transcript_unit.structural_error
  | Source_changed
  | Atom_order_mismatch of { expected : int; actual : int }
  | Invalid_atom_range of { first : int; last : int }
  | Protected_atom of int
  | Empty_summary
  | Incomplete_partition of int
let ( let* ) = Result.bind
let error_to_string = function
  | Required_message_missing i -> Printf.sprintf "required message %d is outside the source" i
  | Invalid_transcript error -> Keeper_transcript_unit.show_structural_error error
  | Source_changed -> "proposal source checkpoint changed"
  | Atom_order_mismatch {expected; actual} -> Printf.sprintf "expected source atom %d, got %d" expected actual
  | Invalid_atom_range {first; last} -> Printf.sprintf "invalid source atom range %d..%d" first last
  | Protected_atom i -> Printf.sprintf "source atom %d must remain original" i
  | Empty_summary -> "derived summary is empty"
  | Incomplete_partition i -> Printf.sprintf "proposal omitted source atom %d" i

let index ~source:snapshot ~required =
  let messages = Keeper_checkpoint_store.exact_snapshot_messages snapshot in
  let count = List.length messages in
  let* required = List.fold_left (fun acc requirement ->
    let* positions = acc in
    if requirement.message_index < 0 || requirement.message_index >= count
    then Error (Required_message_missing requirement.message_index)
    else Ok (Positions.update requirement.message_index
      (function None -> Some [requirement] | Some xs -> Some (requirement :: xs)) positions))
      (Ok Positions.empty) required in
  let* partition = Keeper_transcript_unit.partition messages
    |> Result.map_error (fun error -> Invalid_transcript error) in
  let units = List.map (fun unit ->
    Keeper_transcript_unit.messages_of_closed_unit unit, false) partition.closed_prefix in
  let units = match partition.protected_suffix with
    | [] -> units | suffix -> units @ [suffix, true] in
  let rec loop position atom_id acc = function
    | [] -> Ok {reference=Keeper_checkpoint_store.exact_snapshot_reference snapshot; indexed=List.rev acc}
    | (messages, pending_tool_cycle) :: rest ->
      let next, requirements = List.fold_left (fun (position, requirements) _ ->
        let requirements = match Positions.find_opt position required with
          | None -> requirements | Some rs -> List.rev_append rs requirements in
        position+1, requirements) (position, []) messages in
      let description = {atom_id; first_message=position; last_message=next-1;
        requirements=List.rev requirements; pending_tool_cycle} in
      loop next (atom_id+1) ({description; messages} :: acc) rest
  in loop 0 0 [] units

let source_reference source = source.reference
let atoms source = List.map (fun atom -> atom.description) source.indexed
type step = Retain of int | Summarize of {first_atom:int; last_atom:int; text:string}
[@@deriving yojson]
type proposal = {source_sha256:string; steps:step list} [@@deriving yojson]
type derived = {text:string; source_sha256:string; first_message:int; last_message:int}
type segment = Original of message list | Derived of derived
type validated = {reference:Keeper_checkpoint_ref.t; segments:segment list}
let segments validated = validated.segments

let validate ~(source : source) (proposal : proposal) =
  if not (String.equal source.reference.sha256 proposal.source_sha256) then Error Source_changed
  else
    let rec consume_summary last remaining = match remaining with
      | [] -> Error (Invalid_atom_range {first=last; last})
      | atom :: rest ->
        let d = atom.description in
        if d.requirements <> [] || d.pending_tool_cycle then Error (Protected_atom d.atom_id)
        else if d.atom_id = last then Ok (d.last_message, rest)
        else consume_summary last rest in
    let rec loop expected remaining acc = function
      | [] -> (match remaining with
        | [] -> Ok {reference=source.reference; segments=List.rev acc}
        | _ -> Error (Incomplete_partition expected))
      | step :: rest ->
        let first, last = match step with
          | Retain i -> i, i | Summarize {first_atom; last_atom; _} -> first_atom,last_atom in
        if first <> expected then Error (Atom_order_mismatch {expected; actual=first})
        else if last < first then Error (Invalid_atom_range {first; last})
        else match remaining with
        | [] -> Error (Invalid_atom_range {first; last})
        | atom :: tail -> (match step with
          | Retain _ -> loop (expected+1) tail (Original atom.messages :: acc) rest
          | Summarize {text; _} ->
            if String.trim text = "" then Error Empty_summary
            else let* last_message, remaining = consume_summary last remaining in
            let segment = Derived {text; source_sha256=source.reference.sha256;
              first_message=atom.description.first_message; last_message} in
            loop (last+1) remaining (segment :: acc) rest)
    in loop 0 source.indexed [] proposal.steps

let bind_exact ~current_source validated =
  if Keeper_checkpoint_ref.equal validated.reference
      (Keeper_checkpoint_store.exact_snapshot_reference current_source)
  then Ok validated.segments else Error Source_changed
