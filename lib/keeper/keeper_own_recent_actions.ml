type outcome =
  | Ok_call
  | Failed_call of string option

type call =
  { tool : string
  ; input : string
  ; outcome : outcome
  }

type turn =
  { turn_id : int
  ; calls : call list
  }

(* Bounds on what one call contributes to the prompt. The argument object is
   what the keeper must see to recognise its own mistake (an empty object, a
   finished task id), so it is kept wider than the failure text, which only has
   to identify the refusal. *)
let input_max_chars = 240
let failure_max_chars = 200

(* Rows to read per requested turn. Measured on taskmaster 2026-08-16: 818 calls
   over 80 turns, median 8 per turn and p90 21. Reading 24 covers the 90th
   percentile turn whole. *)
let rows_per_turn = 24

let clip max_chars s =
  if String.length s <= max_chars then s else String.sub s 0 max_chars ^ "…"
;;

let string_field name json =
  match Json_util.assoc_member_opt name json with
  | Some (`String s) -> Some s
  | _ -> None
;;

(* [keeper_turn_id] is persisted as a string. A row whose id is not an integer
   cannot be ordered against the others, so it is dropped with the unattributed
   rows rather than folded into an adjacent turn. *)
let turn_id_field json =
  match Json_util.assoc_member_opt "keeper_turn_id" json with
  | Some (`String s) -> int_of_string_opt (String.trim s)
  | Some (`Int i) -> Some i
  | _ -> None
;;

(* A refusal the tool did not describe stays [None]. Substituting an empty
   string here would render as a refusal with no reason, indistinguishable from
   one the tool declined to explain. *)
let outcome_of_row json =
  match Json_util.assoc_member_opt "success" json with
  | Some (`Bool true) -> Ok_call
  | _ -> Failed_call (Option.map (clip failure_max_chars) (string_field "output" json))
;;

let call_of_row json =
  match string_field "tool" json with
  | None -> None
  | Some tool ->
    let input =
      match Json_util.assoc_member_opt "input" json with
      | None | Some `Null -> "{}"
      | Some (`String s) -> clip input_max_chars s
      | Some value -> clip input_max_chars (Yojson.Safe.to_string value)
    in
    Some { tool; input; outcome = outcome_of_row json }
;;

let turns_of_rows ~keeper_name ~max_turns rows =
  if max_turns <= 0
  then []
  else (
    (* One pass in persisted order builds each turn's call list; the turn order
       is then the order the turns first appeared, so both stay source order
       without a sort. *)
    let order = ref [] in
    let calls = Hashtbl.create 16 in
    List.iter
      (fun row ->
         match string_field "keeper" row, turn_id_field row, call_of_row row with
         | Some k, Some turn_id, Some call when String.equal k keeper_name ->
           if not (Hashtbl.mem calls turn_id)
           then (
             Hashtbl.replace calls turn_id [];
             order := turn_id :: !order);
           Hashtbl.replace calls turn_id (call :: Hashtbl.find calls turn_id)
         | _ -> ())
      rows;
    let ordered = List.rev !order in
    let keep = max 0 (List.length ordered - max_turns) in
    ordered
    |> List.filteri (fun i _ -> i >= keep)
    |> List.map (fun turn_id ->
      { turn_id; calls = List.rev (Hashtbl.find calls turn_id) }))
;;

let collect ~keeper_name ~max_turns =
  if max_turns <= 0
  then []
  else
    Keeper_tool_call_log.read_recent
      ~keeper_name
      ~n:(max_turns * rows_per_turn)
      ()
    |> turns_of_rows ~keeper_name ~max_turns
;;
