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

(* Sizing hint for the read window, not a bound on any row: how many calls a
   turn typically makes. Measured on a live Keeper over 932 calls --
   median 8 per turn, p90 21. Reading short costs turns, never a partial turn:
   only the oldest group can be clipped by the window edge, and
   {!turns_of_rows} drops it. *)
let typical_calls_per_turn = 24

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

(* Only a refusal carries its output. What a successful call returned is not
   what the keeper needs -- that the call landed is the fact -- and it is where
   the bytes are: measured 2026-08-16, a success returns a median 1310 bytes
   against a refusal's 417 (max 2116). Carrying both would put a 10-turn window
   over 80 KB for no added recall, and would force a truncation rule over the
   exact text the keeper has to read to recognise its mistake.

   A refusal the tool did not describe stays [None]. Substituting an empty
   string would render as a refusal with no reason, indistinguishable from one
   the tool declined to explain. *)
let outcome_of_row json =
  match Json_util.assoc_member_opt "success" json with
  | Some (`Bool true) -> Ok_call
  | _ -> Failed_call (string_field "output" json)
;;

let call_of_row json =
  match string_field "tool" json with
  | None -> None
  | Some tool ->
    let input =
      match Json_util.assoc_member_opt "input" json with
      | None | Some `Null -> "{}"
      | Some (`String s) -> s
      | Some value -> Yojson.Safe.to_string value
    in
    Some { tool; input; outcome = outcome_of_row json }
;;

(* A saturated tail read starts mid-turn, so its oldest group is missing that
   turn's earliest calls. Rendering a turn with some calls silently absent is
   worse than not rendering it: the keeper would read a complete-looking
   history that omits the call it needs to see. *)
let drop_clipped_leading_turn rows =
  match List.find_map turn_id_field rows with
  | None -> rows
  | Some clipped -> List.filter (fun row -> turn_id_field row <> Some clipped) rows
;;

let turns_of_rows ~keeper_name ~max_turns ~window_saturated rows =
  if max_turns <= 0
  then []
  else (
    let rows = if window_saturated then drop_clipped_leading_turn rows else rows in
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

(* The salience problem this answers: a 12-turn window renders as a hundred
   or more one-line calls in which a handful of refusals sit buried, and the
   keeper repeats the rejected call anyway (2026-08-28: a keeper re-read the
   same nonexistent paths every autonomous turn, 61 distinct paths over a
   day, while every one of those refusals was already inside this window).
   The digest lifts the failures out deduped: one row per distinct rejected
   (tool, input), counted, with the newest refusal's detail. *)
type failure_digest =
  { failure_tool : string
  ; failure_input : string
  ; failure_count : int
  ; failure_detail : string option
  ; failure_last_turn : int
  }

let digest_failures ?(limit = 8) (turns : turn list) : failure_digest list =
  let counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let sources : (string, string * string) Hashtbl.t = Hashtbl.create 16 in
  let details : (string, string option) Hashtbl.t = Hashtbl.create 16 in
  let last_turn : (string, int) Hashtbl.t = Hashtbl.create 16 in
  (* Turns arrive oldest first, so walking forward leaves the newest
     occurrence's detail and turn as the last write per key. *)
  List.iter
    (fun (turn : turn) ->
       List.iter
         (fun (call : call) ->
            match call.outcome with
            | Ok_call -> ()
            | Failed_call detail ->
              let key = call.tool ^ "\000" ^ call.input in
              Hashtbl.replace counts key
                (1 + Option.value ~default:0 (Hashtbl.find_opt counts key));
              Hashtbl.replace sources key (call.tool, call.input);
              Hashtbl.replace details key detail;
              Hashtbl.replace last_turn key turn.turn_id)
         turn.calls)
    turns;
  Hashtbl.fold
    (fun key _count acc ->
       let tool, input = Hashtbl.find sources key in
       { failure_tool = tool
       ; failure_input = input
       ; failure_count = Hashtbl.find counts key
       ; failure_detail = Hashtbl.find details key
       ; failure_last_turn = Hashtbl.find last_turn key
       }
       :: acc)
    counts
    []
  |> List.sort (fun left right ->
         Int.compare right.failure_last_turn left.failure_last_turn)
  |> List.filteri (fun index _ -> index < limit)
;;

let collect ~keeper_name ~max_turns =
  if max_turns <= 0
  then []
  else begin
    (* One turn's worth of slack, so discarding the clipped group still leaves
       [max_turns] whole ones. *)
    let n = (max_turns + 1) * typical_calls_per_turn in
    let rows = Keeper_tool_call_log.read_recent ~keeper_name ~n () in
    (* Short of the window means the store held nothing older, so nothing was
       cut. *)
    turns_of_rows
      ~keeper_name ~max_turns
      ~window_saturated:(List.length rows >= n)
      rows
  end
;;
