module Turn_id = Ids.Turn_id
module Index_set = Set.Make (Int)
open Result.Syntax

type name =
  | Leading of int
  | In_turn of
      { turn : Turn_id.t
      ; ordinal : int
      }

let equal_name left right =
  match left, right with
  | Leading left, Leading right -> Int.equal left right
  | In_turn left, In_turn right ->
    Turn_id.equal left.turn right.turn && Int.equal left.ordinal right.ordinal
  | Leading _, In_turn _ | In_turn _, Leading _ -> false
;;

let name_to_string = function
  | Leading index -> Printf.sprintf "leading/%d" index
  | In_turn { turn; ordinal } -> Printf.sprintf "%s/%d" (Turn_id.to_string turn) ordinal
;;

type frame =
  | Message_history
  | Canonical_turns

let frame_to_string = function
  | Message_history -> "message_history"
  | Canonical_turns -> "canonical_turns"
;;

type extent =
  | Whole_turn
  | Up_to of
      { ordinal : int
      ; settled : Turn_id.t option
      }

type through =
  | Through_leading of int
  | Through_turn of
      { turn : Turn_id.t
      ; extent : extent
      }

type coverage =
  { through : through option
  ; beyond : name list
  }

let settled_turn { through; beyond = _ } =
  match through with
  | None | Some (Through_leading _) -> None
  | Some (Through_turn { turn; extent = Whole_turn }) -> Some turn
  | Some (Through_turn { turn = _; extent = Up_to { settled; ordinal = _ } }) -> settled
;;

let through_to_string = function
  | Through_leading last -> Printf.sprintf "leading/%d" last
  | Through_turn { turn; extent = Whole_turn } -> Turn_id.to_string turn
  | Through_turn { turn; extent = Up_to { ordinal; settled = _ } } ->
    Printf.sprintf "%s/%d" (Turn_id.to_string turn) ordinal
;;

let coverage_to_string { through; beyond } =
  let front = Option.fold ~none:"none" ~some:through_to_string through in
  match beyond with
  | [] -> front
  | _ :: _ -> Printf.sprintf "%s +%d later" front (List.length beyond)
;;

(* --- Strict JSON codecs --- *)

let turn_to_json turn = `String (Turn_id.to_string turn)

let turn_of_json = function
  | `String value when not (String.equal (String.trim value) "") -> Ok (Turn_id.of_string value)
  | _ -> Error "expected a non-blank turn id"
;;

let nonnegative_of_json ~field = function
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a non-negative integer" field)
;;

let decode_list decode items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* decoded = decode item in
      loop (decoded :: acc) rest
  in
  loop [] items
;;

let name_to_json = function
  | Leading index -> `Assoc [ "kind", `String "leading"; "index", `Int index ]
  | In_turn { turn; ordinal } ->
    `Assoc [ "kind", `String "in_turn"; "ordinal", `Int ordinal; "turn", turn_to_json turn ]
;;

let name_of_json = function
  | `Assoc fields ->
    (match List.sort compare fields with
     | [ "index", index; "kind", `String "leading" ] ->
       let* index = nonnegative_of_json ~field:"index" index in
       Ok (Leading index)
     | [ "kind", `String "in_turn"; "ordinal", ordinal; "turn", turn ] ->
       let* ordinal = nonnegative_of_json ~field:"ordinal" ordinal in
       let* turn = turn_of_json turn in
       Ok (In_turn { turn; ordinal })
     | _ -> Error "unknown or malformed atom name")
  | _ -> Error "expected a JSON object for an atom name"
;;

let through_to_json = function
  | Through_leading last -> `Assoc [ "kind", `String "leading"; "last", `Int last ]
  | Through_turn { turn; extent = Whole_turn } ->
    `Assoc [ "kind", `String "whole_turn"; "turn", turn_to_json turn ]
  | Through_turn { turn; extent = Up_to { ordinal; settled } } ->
    `Assoc
      [ "kind", `String "turn_up_to"
      ; "ordinal", `Int ordinal
      ; "settled", Option.fold ~none:`Null ~some:turn_to_json settled
      ; "turn", turn_to_json turn
      ]
;;

let through_of_json = function
  | `Assoc fields ->
    (match List.sort compare fields with
     | [ "kind", `String "leading"; "last", last ] ->
       let* last = nonnegative_of_json ~field:"last" last in
       Ok (Through_leading last)
     | [ "kind", `String "whole_turn"; "turn", turn ] ->
       let* turn = turn_of_json turn in
       Ok (Through_turn { turn; extent = Whole_turn })
     | [ "kind", `String "turn_up_to"; "ordinal", ordinal; "settled", settled; "turn", turn ] ->
       let* ordinal = nonnegative_of_json ~field:"ordinal" ordinal in
       let* settled =
         match settled with
         | `Null -> Ok None
         | json -> Result.map Option.some (turn_of_json json)
       in
       let* turn = turn_of_json turn in
       Ok (Through_turn { turn; extent = Up_to { ordinal; settled } })
     | _ -> Error "unknown or malformed coverage boundary")
  | _ -> Error "expected a JSON object for a coverage boundary"
;;

let coverage_to_json { through; beyond } =
  `Assoc
    [ "beyond", `List (List.map name_to_json beyond)
    ; "through", Option.fold ~none:`Null ~some:through_to_json through
    ]
;;

let coverage_of_json = function
  | `Assoc fields ->
    (match List.sort compare fields with
     | [ "beyond", `List beyond; "through", through ] ->
       let* through =
         match through with
         | `Null -> Ok None
         | json -> Result.map Option.some (through_of_json json)
       in
       let* beyond = decode_list name_of_json beyond in
       Ok { through; beyond }
     | _ -> Error "expected beyond and through")
  | _ -> Error "expected a JSON object for coverage"
;;

(* --- Naming --- *)

type atom =
  { name : name
  ; messages : Agent_core.Types.message list
  ; last_position : int
  }

let atoms_of_messages messages =
  let labelled, atom_count = Runtime_model_input_tail_window.annotate messages in
  let members_rev = Array.make atom_count [] in
  let last_positions = Array.make atom_count (-1) in
  List.iteri
    (fun position (message, label) ->
       match label with
       | Runtime_model_input_tail_window.Pinned -> ()
       | Runtime_model_input_tail_window.Atom index ->
         members_rev.(index) <- message :: members_rev.(index);
         last_positions.(index) <- position)
    labelled;
  let next_ordinals : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let take_ordinal turn =
    let key = Turn_id.to_string turn in
    let ordinal = Option.value ~default:0 (Hashtbl.find_opt next_ordinals key) in
    Hashtbl.replace next_ordinals key (ordinal + 1);
    ordinal
  in
  (* An atom's opening message names its turn. An atom whose opener names
     none (an assistant reply, a mid-turn user message) belongs to the turn
     of the atom before it; before any turn it is a leading atom. *)
  let rec name_from index current leading acc =
    if index >= atom_count
    then Array.of_list (List.rev acc)
    else (
      let messages = List.rev members_rev.(index) in
      let opened =
        match messages with
        | opener :: _ -> Keeper_turn_ref_metadata.turn_of_message opener
        | [] -> None
      in
      let name, current, leading =
        match opened, current with
        | Some turn, (Some _ | None) | None, Some turn ->
          In_turn { turn; ordinal = take_ordinal turn }, Some turn, leading
        | None, None -> Leading leading, None, leading + 1
      in
      let atom = { name; messages; last_position = last_positions.(index) } in
      name_from (index + 1) current leading (atom :: acc))
  in
  name_from 0 None 0 []
;;

(* --- Coverage --- *)

let names_turn turn atom =
  match atom.name with
  | In_turn { turn = named; ordinal = _ } -> Turn_id.equal named turn
  | Leading _ -> false
;;

let first_index_naming atoms turn =
  let count = Array.length atoms in
  let rec scan index =
    if index >= count
    then None
    else if names_turn turn atoms.(index)
    then Some index
    else scan (index + 1)
  in
  scan 0
;;

let is_leading atom =
  match atom.name with
  | Leading _ -> true
  | In_turn _ -> false
;;

let covered_end through atoms =
  let count = Array.length atoms in
  match through with
  | None -> -1
  | Some (Through_leading last) ->
    (* Leading atoms are a prefix of the list and [Leading j] sits at index j. *)
    let rec scan index =
      if index < count && index <= last && is_leading atoms.(index)
      then scan (index + 1)
      else index - 1
    in
    scan 0
  | Some (Through_turn { turn; extent }) ->
    (match first_index_naming atoms turn with
     | None -> -1
     | Some first ->
       (match extent with
        | Whole_turn ->
          let rec run_end index =
            if index + 1 < count && names_turn turn atoms.(index + 1)
            then run_end (index + 1)
            else index
          in
          run_end first
        | Up_to { ordinal = limit; settled = _ } ->
          (* The turn's ordinals rise along the list, so the last of its atoms
             at or under [limit] is the end. The first one has ordinal 0. *)
          let rec scan index best =
            if index >= count
            then best
            else (
              match atoms.(index).name with
              | In_turn { turn = named; ordinal } when Turn_id.equal named turn && ordinal <= limit ->
                scan (index + 1) index
              | In_turn _ | Leading _ -> scan (index + 1) best)
          in
          scan first first))
;;

type latest =
  { message_history : coverage option
  ; canonical_turns : coverage option
  }

let latest_over frame { message_history; canonical_turns } =
  match frame with
  | Message_history -> message_history
  | Canonical_turns -> canonical_turns
;;

(* A turn's prompt is its ordinal 0 in both kinds of list. Past it, the
   canonical list holds only the final answer, while the message history may
   hold tool rounds before it. *)
let through_read_in ~written_over ~read_in through =
  match written_over, read_in with
  | Message_history, Message_history | Canonical_turns, Canonical_turns -> through
  | Canonical_turns, Message_history ->
    (* A rollover keeps at least two atoms of at most two per turn, so its
       boundary is a whole turn or a turn's prompt. Any other ordinal would
       land no later in the history than it meant. *)
    through
  | Message_history, Canonical_turns ->
    (match through with
     | Through_turn { turn; extent = Up_to { ordinal = _; settled } } ->
       Through_turn { turn; extent = Up_to { ordinal = 0; settled } }
     | Through_turn { turn = _; extent = Whole_turn } | Through_leading _ -> through)
;;

let furthest_covered_end ~frame latest atoms =
  let read_over written_over =
    let through =
      Option.bind (latest_over written_over latest) (fun coverage -> coverage.through)
    in
    covered_end (Option.map (through_read_in ~written_over ~read_in:frame) through) atoms
  in
  Int.max (read_over Message_history) (read_over Canonical_turns)
;;

(* The boundary a producer writes when its evicted prefix ends at [index].

   A turn settles when none of its atoms lies past [index] and every turn that
   opened before it settles too: the canonical turn store prunes its rows in
   commit order, so it may prune through a turn only when every earlier row is
   covered as well. A turn opens at its ordinal 0. *)
let through_at atoms ~index ~previous_settled =
  let count = Array.length atoms in
  match atoms.(index).name with
  | Leading last -> Through_leading last
  | In_turn { turn; ordinal } ->
    let last_index : (string, int) Hashtbl.t = Hashtbl.create 16 in
    Array.iteri
      (fun position atom ->
         match atom.name with
         | In_turn { turn = named; ordinal = _ } ->
           Hashtbl.replace last_index (Turn_id.to_string named) position
         | Leading _ -> ())
      atoms;
    let closed named =
      match Hashtbl.find_opt last_index (Turn_id.to_string named) with
      | Some last -> last <= index
      | None -> true
    in
    let first = Option.value ~default:index (first_index_naming atoms turn) in
    (* [covered_end] reads [Whole_turn] as the turn's first run of atoms, so
       the turn is written whole only when that run reaches [index]. A turn
       whose atoms another turn's atom splits is written [Up_to], which
       [covered_end] reads by ordinal and so lands on [index]. *)
    let rec runs_to_index position =
      position > index || (names_turn turn atoms.(position) && runs_to_index (position + 1))
    in
    let rec settle position settled =
      if position >= first
      then settled, true
      else (
        match atoms.(position).name with
        | In_turn { turn = named; ordinal = 0 } ->
          if closed named then settle (position + 1) (Some named) else settled, false
        | In_turn _ | Leading _ -> settle (position + 1) settled)
    in
    let settled_before, earlier_turns_closed = settle 0 None in
    if earlier_turns_closed && closed turn && runs_to_index first && index + 1 < count
    then Through_turn { turn; extent = Whole_turn }
    else (
      let settled =
        match settled_before with
        | Some _ -> settled_before
        | None -> previous_settled
      in
      Through_turn { turn; extent = Up_to { ordinal; settled } })
;;

type eviction =
  { prefix : int
  ; later : int list
  }

type advance =
  { coverage : coverage
  ; fresh : int list
  }

let advance ~previous atoms { prefix; later } =
  let count = Array.length atoms in
  if prefix < 0 || prefix > count
  then Error (Printf.sprintf "evicted prefix %d lies outside %d atoms" prefix count)
  else (
    match List.find_opt (fun index -> index < prefix || index >= count) later with
    | Some index ->
      Error (Printf.sprintf "later evicted atom %d lies outside [%d, %d)" index prefix count)
    | None ->
      let later = Index_set.of_list later in
      let previous_through = Option.bind previous (fun coverage -> coverage.through) in
      let previous_end = covered_end previous_through atoms in
      let previous_beyond : (string, unit) Hashtbl.t = Hashtbl.create 8 in
      Option.iter
        (fun coverage ->
           List.iter
             (fun name -> Hashtbl.replace previous_beyond (name_to_string name) ())
             coverage.beyond)
        previous;
      let archived_beyond index =
        Hashtbl.length previous_beyond > 0
        && Hashtbl.mem previous_beyond (name_to_string atoms.(index).name)
      in
      let indices = List.init count Fun.id in
      let fresh =
        List.filter
          (fun index ->
             (index < prefix || Index_set.mem index later)
             && index > previous_end
             && not (archived_beyond index))
          indices
      in
      (match fresh with
       | [] -> Ok None
       | _ :: _ ->
         let new_end = Int.max (prefix - 1) previous_end in
         let through =
           if prefix - 1 <= previous_end
           then previous_through
           else
             Some
               (through_at
                  atoms
                  ~index:(prefix - 1)
                  ~previous_settled:(Option.bind previous settled_turn))
         in
         let beyond =
           List.filter_map
             (fun index ->
                if index > new_end && (Index_set.mem index later || archived_beyond index)
                then Some atoms.(index).name
                else None)
             indices
         in
         Ok (Some { coverage = { through; beyond }; fresh })))
;;
