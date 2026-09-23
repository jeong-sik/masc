(* The Overview's spend reading: the decoder for
   [GET /api/v1/dashboard/keeper-costs] and the tag each Team row carries.
   A library so a test can feed it the server's own encoder output.

   A turn whose runtime reported no cost or no usage stays unknown all the
   way to the screen: "$?" or a "≥" floor, never "$0.00". *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

let ( let* ) = Result.bind

(* The window the Team block reports over. The server takes the window in
   minutes; a day is the span a team report is read against. *)
let window_minutes = 24 * 60

let minutes_per_hour = 60

let cents_per_dollar = 100.0

let floor_mark = "\xe2\x89\xa5"

let decode_count json key =
  let* count = required_int_field json key in
  if count >= 0 then Ok count
  else Error (Printf.sprintf "%s is negative" key)

(* One of the aggregate's sums and the three counts that partition its turns.
   The server writes [null] exactly when no turn reported the value; any
   other pairing is a row this build cannot vouch for. *)
let decode_sum json ~samples ~total_key ~prefix ~sum_of_json =
  let* reported = decode_count json (prefix ^ "_reported_samples") in
  let* unreported = decode_count json (prefix ^ "_unreported_samples") in
  let* unread = decode_count json (prefix ^ "_unread_samples") in
  if reported + unreported + unread <> samples then
    Error (Printf.sprintf "%s counts do not add up to sample_count" prefix)
  else
    match (Yojson.Safe.Util.member total_key json, reported) with
    | `Null, 0 -> Ok Spend_unknown
    | `Null, _ -> Error (total_key ^ " is null although turns reported it")
    | _, 0 -> Error (total_key ^ " is set although no turn reported it")
    | value, _ ->
        let* sum = sum_of_json value in
        Ok (Spend_sum { sum; missing = unreported + unread })

let cost_of_json = function
  | `Float usd when Float.is_finite usd && usd >= 0.0 -> Ok usd
  | `Int usd when usd >= 0 -> Ok (float_of_int usd)
  | _ -> Error "total_cost_usd is not a non-negative number"

let tokens_of_json = function
  | `Int tokens when tokens >= 0 -> Ok tokens
  | _ -> Error "total_tokens is not a non-negative integer"

let decode_keeper json =
  let* name = required_string_field json "keeper_name" in
  let* samples = decode_count json "sample_count" in
  let* cost_usd =
    decode_sum json ~samples ~total_key:"total_cost_usd" ~prefix:"cost"
      ~sum_of_json:cost_of_json
  in
  let* tokens =
    decode_sum json ~samples ~total_key:"total_tokens" ~prefix:"tokens"
      ~sum_of_json:tokens_of_json
  in
  Ok (name, if samples = 0 then Spend_no_turns else Spend_turns { cost_usd; tokens })

let decode_reading json =
  let* cache = required_object_field json "cache" in
  let* cache_state = required_string_field cache "state" in
  let read () =
    let* window_minutes = required_int_field json "window_minutes" in
    let* rows = required_list_field json "keepers" in
    (* Row by row: a row this build cannot read leaves that Keeper unknown
       instead of blanking every other Keeper's tag. *)
    let keepers, undecodable =
      List.fold_right
        (fun row (keepers, undecodable) ->
          match decode_keeper row with
          | Ok keeper -> (keeper :: keepers, undecodable)
          | Error _ -> (keepers, undecodable + 1))
        rows ([], 0)
    in
    Ok (Overview_spend_read { window_minutes; keepers; undecodable })
  in
  match cache_state with
  | "fresh" | "stale_refreshing" -> read ()
  | "warming" -> Ok Overview_spend_warming
  | other -> Error ("unknown keeper-costs cache state " ^ other)

let window_text minutes =
  if minutes mod minutes_per_hour = 0 then
    Printf.sprintf "%dh" (minutes / minutes_per_hour)
  else Printf.sprintf "%dm" minutes

let floor_prefix missing = if missing > 0 then floor_mark else ""

let cost_text = function
  | Spend_unknown -> Ansi.dim ^ "$?" ^ Ansi.reset
  | Spend_sum { sum; missing } ->
      (* A cost that rounds to no cents is still a cost. *)
      let amount =
        if sum > 0.0 && Float.round (sum *. cents_per_dollar) = 0.0 then "<$0.01"
        else Printf.sprintf "$%.2f" sum
      in
      floor_prefix missing ^ amount

let tokens_text = function
  | Spend_unknown -> Ansi.dim ^ "? tok" ^ Ansi.reset
  | Spend_sum { sum; missing } ->
      floor_prefix missing ^ format_context_tokens sum ^ " tok"

(* What one Keeper's tag says. A Keeper missing from the rows -- not listed
   by the server, or its row unreadable -- is as unknown as a Keeper whose
   turns all left their spend out. *)
let spend_text = function
  | None -> cost_text Spend_unknown ^ " " ^ tokens_text Spend_unknown
  | Some Spend_no_turns -> Ansi.dim ^ "no turns" ^ Ansi.reset
  | Some (Spend_turns { cost_usd; tokens }) ->
      cost_text cost_usd ^ " " ^ tokens_text tokens

(* The tag each Team row carries after its age: the Keeper's cost and tokens
   over the window, padded to the widest tag among [names] so the detail
   after it starts in one column. Empty while nothing was read. *)
let keeper_tags (reading : overview_spend_reading) names =
  match reading with
  | Overview_spend_unread | Overview_spend_warming | Overview_spend_failed _ ->
      fun _ -> ""
  | Overview_spend_read { keepers; _ } ->
      let text_of name = spend_text (List.assoc_opt name keepers) in
      let cells =
        List.fold_left
          (fun widest name ->
            max widest (Masc_tui_message_layout.display_width (text_of name)))
          0 names
      in
      fun name -> fit_width (text_of name) cells ^ "  "

(* Two sums of the same value added: known where either is, a floor when
   either left something out. *)
let add_sums add left right =
  match (left, right) with
  | Spend_unknown, Spend_unknown -> Spend_unknown
  | Spend_sum { sum; missing }, Spend_unknown
  | Spend_unknown, Spend_sum { sum; missing } ->
      Spend_sum { sum; missing = missing + 1 }
  | Spend_sum left, Spend_sum right ->
      Spend_sum { sum = add left.sum right.sum; missing = left.missing + right.missing }

(* A Keeper whose row could not be read spent something unknown. *)
let with_unread_rows undecodable = function
  | Spend_unknown -> Spend_unknown
  | Spend_sum { sum; missing } -> Spend_sum { sum; missing = missing + undecodable }

(* The team's spend over the window, for the Team title: the sums of the
   Keepers that reported, a floor when any turn or row did not. *)
let team_total (reading : overview_spend_reading) =
  match reading with
  | Overview_spend_unread | Overview_spend_warming | Overview_spend_failed _ ->
      None
  | Overview_spend_read { window_minutes; keepers; undecodable } ->
      let window = Ansi.dim ^ window_text window_minutes ^ Ansi.reset in
      let turned =
        List.filter_map
          (fun (_, spend) ->
            match spend with
            | Spend_no_turns -> None
            | Spend_turns { cost_usd; tokens } -> Some (cost_usd, tokens))
          keepers
      in
      let total =
        match (turned, undecodable) with
        | [], 0 -> None
        | [], _ -> Some (Spend_unknown, Spend_unknown)
        | first :: rest, _ ->
            let cost, tokens =
              List.fold_left
                (fun (cost_total, tokens_total) (cost, tokens) ->
                  (add_sums ( +. ) cost_total cost, add_sums ( + ) tokens_total tokens))
                first rest
            in
            Some (with_unread_rows undecodable cost, with_unread_rows undecodable tokens)
      in
      Some
        (match total with
         | None -> Printf.sprintf "%s %sno turns%s" window Ansi.dim Ansi.reset
         | Some (cost, tokens) ->
             Printf.sprintf "%s %s \xc2\xb7 %s" window (cost_text cost) (tokens_text tokens))

(* The line under the Team block that says why no row carries a tag, or how
   many Keepers' rows could not be read. *)
let lines (reading : overview_spend_reading) =
  let dim text = Ansi.dim ^ text ^ Ansi.reset in
  match reading with
  | Overview_spend_unread -> []
  | Overview_spend_warming -> [ dim "$ spend not read yet: the server is still adding it up" ]
  | Overview_spend_failed err ->
      [ dim ("$ spend unread: " ^ Terminal_text.single_line err) ]
  | Overview_spend_read { undecodable = 0; _ } -> []
  | Overview_spend_read { undecodable; _ } ->
      [ Printf.sprintf "%s$ spend rows unreadable: %d Keeper%s drawn unknown%s"
          (Theme.warn ()) undecodable
          (if undecodable = 1 then "" else "s")
          Ansi.reset
      ]
