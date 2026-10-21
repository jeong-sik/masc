module Fetched = Masc_tui_fetched
module Reading = Masc_tui_detail_reading
type choice = { execution_id : string; tool : string; args : string; subject : string option }
type request = string Fetched.request
let path ~keeper ~execution_id =
  Printf.sprintf "/api/v1/keepers/%s/tool-calls?execution_id=%s"
    (Uri.pct_encode ~component:`Generic keeper) (Uri.pct_encode ~component:`Generic execution_id)
type t = {
  choices : choice list;
  cursor : int;
  choosing : bool;
  fetched : (string, Masc.Tui_decode.keeper_call) Fetched.t;
  document : Reading.t;
}
let section heading body = { Reading.heading; body }
let selection_document choices cursor =
  let sections = match List.nth_opt choices cursor with
    | None -> [section "Unavailable" "No original execution ID is recorded in this conversation."]
    | Some choice ->
        [section (Printf.sprintf "Call %d of %d · %s" (cursor+1) (List.length choices) choice.tool)
           choice.execution_id;
         section "Original input" choice.args]
        @ (match choice.subject with None -> [] | Some subject -> [section "Original target" subject]) in
  Reading.create ~title:"Original calls · j/k choose · Enter read · Esc back" sections
let create choices =
  (* Preserve the first original occurrence; repeated delivery is not a new call. *)
  let module Ids = Set.Make(String) in
  let _,choices = List.fold_left (fun (seen,kept) choice ->
    if Ids.mem choice.execution_id seen then seen,kept
    else Ids.add choice.execution_id seen, choice::kept) (Ids.empty,[]) choices in
  let choices=List.rev choices in
  { choices; cursor=0; choosing=true; fetched=Fetched.initial;
    document=selection_document choices 0 }
type action = Close | Choose of int | Open | Retry | Move of Reading.movement | Ignore
let action ~key ~height t =
  match key with
  | "esc" -> Close
  | "j" | "down" when t.choosing -> Choose 1
  | "k" | "up" when t.choosing -> Choose (-1)
  | "\r" | "\n" | "enter" when t.choosing -> Open
  | "r" when not t.choosing -> Retry
  | "pagedown" -> Move (Reading.By height)
  | "pageup" -> Move (Reading.By (-height))
  | "home" | "g" -> Move Reading.First
  | "end" | "G" -> Move Reading.Last
  | "j" | "down" | "wheel-down" when not t.choosing -> Move (Reading.By 1)
  | "k" | "up" | "wheel-up" when not t.choosing -> Move (Reading.By (-1))
  | _ -> Ignore
let choices t = t.choices
let selected t = List.nth_opt t.choices t.cursor
let choosing t = t.choosing
let choose delta t =
  let cursor = max 0 (min (List.length t.choices - 1) (t.cursor + delta)) in
  {t with cursor; document=selection_document t.choices cursor}
let select_execution execution_id t =
  Option.map (fun cursor -> {t with cursor; document=selection_document t.choices cursor})
    (List.find_index (fun choice -> String.equal choice.execution_id execution_id) t.choices)
let observation t = match selected t with
  | None -> Fetched.Absent
  | Some choice -> Fetched.view_for ~equal:String.equal t.fetched ~key:choice.execution_id
let original_failure = function
  | Masc.Tui_decode.Original_failed detail -> Some detail
  | Original_pending -> Some "The enclosing turn's original trace is not published yet"
  | Original_unavailable reason -> Some reason
  | Original_not_read | Original_body _ -> None
let output_sections (call:Masc.Tui_decode.keeper_call) =
  let preview () = [section "Recorded output preview"
    (match call.kc_output with Some output -> output | None -> "No output was recorded.")] in
  let output = match call.kc_original with
    | Original_body body ->
      let printed = match Masc_tui_execute_result.of_result body.content with
        | None -> []
        | Some result -> [section "Command outcome" (Masc_tui_execute_result.status_text result)]
            @ (match result.output with
               | None -> []
               | Some (Masc_tui_execute_result.Printed text) -> [section "Printed output" text]
               | Some (Stored reference) ->
                   [section "Stored output" (Masc_tui_execute_result.stored_text reference)]) in
      printed @ [section "Retained original result" body.content;
        section "Original source" (Printf.sprintf
          "%d projected bytes · %d recorded bytes · sha256 %s"
          (String.length body.content) body.recorded_bytes body.sha256)]
    | Original_not_read -> preview ()
    | (Original_pending | Original_unavailable _ | Original_failed _) as source ->
        preview () @ (match original_failure source with
          | None -> [] | Some reason -> [section "Original source not available" reason]) in
  output @ (match call.kc_truncated_to with None -> [] | Some bytes ->
    [section "Ledger preview limit" (Printf.sprintf
      "The ledger preview declares truncation to %d bytes; the original source is read separately." bytes)])
let result_document t =
  match selected t with
  | None -> Reading.create ~title:"Original calls" [section "Unavailable" "No original execution ID is recorded in this conversation."]
  | Some choice ->
    let state = observation t in
    let observation = match state with
      | Fetched.Absent -> [section "Not read" "Open this original call to read it."]
      | Loading -> [section "Reading" "Reading the selected original execution."]
      | Failed reason -> [section "Read failed" reason]
      | Ready call | Stale (call, _) ->
          [section "Tool" call.Masc.Tui_decode.kc_tool;
           section "Input" call.kc_input;
           ] @ output_sections call
          @ (match state with Stale (_,reason) -> [section "Refresh failed · retained reading" reason]
             | Absent | Loading | Failed _ | Ready _ -> []) in
    let pending = if Fetched.in_flight t.fetched then
      [section "Read pending" "Reading this original execution; any retained result and failure remain below."]
      else [] in
    Reading.replace ~title:"Original call · j/k scroll · r retry · Esc calls"
      (section "Execution" choice.execution_id :: pending @ observation) t.document
let start t = match selected t with
  | None -> {t with document=result_document t}, None
  | Some choice ->
      match Fetched.refresh ~equal:String.equal t.fetched ~key:choice.execution_id with
      | Fetched.Already_loading -> t,None
      | Started (fetched,request) ->
          let document = if t.choosing then Reading.create_observation ~title:"Original call" [] else t.document in
          let t={t with choosing=false;fetched;document} in
          {t with document=result_document t},Some request
let complete t request result =
  let result = Result.bind result (fun call ->
    if Option.equal String.equal call.Masc.Tui_decode.kc_execution_id
         (Some (Fetched.request_key request)) then Ok call
    else Error "Original execution identity mismatch") in
  let result = Result.bind result (fun call ->
    match original_failure call.Masc.Tui_decode.kc_original, observation t with
    | Some reason, (Fetched.Ready previous | Stale (previous,_)) ->
        (match previous.Masc.Tui_decode.kc_original with
         | Original_body _ -> Error reason
         | Original_not_read | Original_pending | Original_unavailable _ | Original_failed _ -> Ok call)
    | (None | Some _), (Fetched.Absent | Loading | Failed _ | Ready _ | Stale _) -> Ok call) in
  if not (Fetched.is_current ~equal:String.equal t.fetched request) then t
  else let t={t with fetched=Fetched.complete ~equal:String.equal t.fetched request result} in
    {t with document=result_document t}
let back t =
  let t={t with choosing=true;fetched=Fetched.cancel_pending ~reason:"Reader closed" t.fetched} in
  {t with document=selection_document t.choices t.cursor}
let document t = t.document
let move ~count ~height movement t =
  {t with document=Reading.move ~count ~height movement t.document}
let pending t = Fetched.in_flight t.fetched
