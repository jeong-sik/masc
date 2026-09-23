(* The Overview's spend reading: the decoder for
   [GET /api/v1/dashboard/keeper-costs] and the tag each Team row carries.
   A library so a test can feed it the server's own encoder output.

   A turn whose runtime reported no cost or no usage stays unknown all the
   way to the screen: a "≥" floor or no dollar figure, never "$0.00". *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

let ( let* ) = Result.bind

(* The window the Team block reports over. The server takes the window in
   minutes; a day is the span a team report is read against. *)
let window_minutes = 24 * 60

let seconds_per_minute = 60

let minutes_per_hour = 60

let cents_per_dollar = 100.0

let floor_mark = "\xe2\x89\xa5"

(* Cells between a Team row's detail and its spend tag. *)
let tag_gap_cells = 2

let decode_count json key =
  let* count = required_int_field json key in
  if count >= 0 then Ok count
  else Error (Printf.sprintf "%s is negative" key)

(* One of the aggregate's sums and the three counts that partition its turns.
   The server writes [null] exactly when no turn reported the value; any
   other pairing is a row this build cannot vouch for. [malformed_rows] are
   rows of the window that were not JSON: any of them may have been a turn,
   so they make a known sum a floor. *)
let decode_sum json ~samples ~malformed_rows ~total_key ~prefix ~sum_of_json =
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
        Ok (Spend_sum { sum; missing = unreported + unread + malformed_rows })

let cost_of_json = function
  | `Float usd when Float.is_finite usd && usd >= 0.0 -> Ok usd
  | `Int usd when usd >= 0 -> Ok (float_of_int usd)
  | _ -> Error "total_cost_usd is not a non-negative number"

let tokens_of_json = function
  | `Int tokens when tokens >= 0 -> Ok tokens
  | _ -> Error "total_tokens is not a non-negative integer"

let decode_turns json ~malformed_rows =
  let* samples = decode_count json "sample_count" in
  let* cost_usd =
    decode_sum json ~samples ~malformed_rows ~total_key:"total_cost_usd"
      ~prefix:"cost" ~sum_of_json:cost_of_json
  in
  let* tokens =
    decode_sum json ~samples ~malformed_rows ~total_key:"total_tokens"
      ~prefix:"tokens" ~sum_of_json:tokens_of_json
  in
  (* No turn was read, but a row that was not JSON may have been one. *)
  Ok
    (if samples = 0 && malformed_rows = 0 then Spend_no_turns
     else Spend_turns { cost_usd; tokens })

let decode_keeper json =
  let* name = required_string_field json "keeper_name" in
  let* metrics_read = required_object_field json "metrics_read" in
  let* read_state = required_string_field metrics_read "state" in
  let* spend =
    match read_state with
    | "read" ->
        let* malformed_rows = decode_count metrics_read "malformed_rows" in
        decode_turns json ~malformed_rows
    | "failed" ->
        let* reason = required_string_field metrics_read "reason" in
        Ok (Spend_unread reason)
    | other -> Error ("unknown metrics_read state " ^ other)
  in
  Ok (name, spend)

let decode_rows json ~freshness =
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
  Ok (Overview_spend_read { window_minutes; keepers; undecodable; freshness })

let decode_reading json =
  let* cache = required_object_field json "cache" in
  let* cache_state = required_string_field cache "state" in
  let* last_error = optional_string_field cache "last_error" in
  match cache_state with
  | "fresh" -> decode_rows json ~freshness:Spend_fresh
  | "stale_refreshing" ->
      let* age_s =
        match Yojson.Safe.Util.member "age_s" cache with
        | `Float age_s when Float.is_finite age_s && age_s >= 0.0 -> Ok age_s
        | `Int age_s when age_s >= 0 -> Ok (float_of_int age_s)
        | _ -> Error "a stale keeper-costs answer carries no age_s"
      in
      decode_rows json ~freshness:(Spend_stale { age_s; last_error })
  | "warming" -> (
      (* The placeholder's rows are empty whatever the workspace spent. With
         an error, the server tried and failed to add it up. *)
      match last_error with
      | None -> Ok Overview_spend_warming
      | Some err -> Ok (Overview_spend_failed ("server could not add up spend: " ^ err)))
  | other -> Error ("unknown keeper-costs cache state " ^ other)

(* A failed load replaces the last good reading: a spend drawn after the
   reading that said so stopped arriving would be a number nobody observed. *)
let reading_of_load = function
  | Ok reading -> reading
  | Error err -> Overview_spend_failed err

let window_text minutes =
  if minutes mod minutes_per_hour = 0 then
    Printf.sprintf "%dh" (minutes / minutes_per_hour)
  else Printf.sprintf "%dm" minutes

let age_text age_s =
  let seconds = int_of_float age_s in
  if seconds < seconds_per_minute then Printf.sprintf "%ds" seconds
  else Printf.sprintf "%dm" (seconds / seconds_per_minute)

let floor_prefix missing = if missing > 0 then floor_mark else ""

let unknown_tokens_text = Ansi.dim ^ "? tok" ^ Ansi.reset

(* A known cost only; an unknown one is left out, not drawn as a figure. *)
let cost_text sum missing =
  (* A cost that rounds to no cents is still a cost. *)
  let amount =
    if sum > 0.0 && Float.round (sum *. cents_per_dollar) = 0.0 then "<$0.01"
    else Printf.sprintf "$%.2f" sum
  in
  floor_prefix missing ^ amount

let tokens_text = function
  | Spend_unknown -> unknown_tokens_text
  | Spend_sum { sum; missing } ->
      floor_prefix missing ^ format_context_tokens sum ^ " tok"

(* Cost is drawn only where some turn reported one; every live subscription
   runtime reports none, and "$?" on each of their rows says nothing the
   tokens beside it do not. *)
let turns_text ~cost_usd ~tokens =
  match cost_usd with
  | Spend_sum { sum; missing } -> cost_text sum missing ^ " " ^ tokens_text tokens
  | Spend_unknown -> tokens_text tokens

(* What one Keeper's tag says. A Keeper missing from the rows -- not listed
   by the server, or its row unreadable -- is unknown, as is one whose store
   the server could not read. *)
let spend_text = function
  | None | Some (Spend_unread _) -> unknown_tokens_text
  | Some Spend_no_turns -> Ansi.dim ^ "no turns" ^ Ansi.reset
  | Some (Spend_turns { cost_usd; tokens }) -> turns_text ~cost_usd ~tokens

(* The tag each Team row carries: the Keeper's spend over the window, padded
   to the widest tag among [names] so the tags stand in one column. Empty
   while nothing was read. *)
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
      fun name -> fit_width (text_of name) cells

(* A Team row with its tag at the right of [inner] cells. The tag goes only
   where the row still fits whole: the detail before it is the row's reason
   (a stuck Keeper's cause is drawn nowhere else), so a narrow row drops the
   spend and keeps the detail. *)
let place_tag ~inner ~tag row =
  let tag_cells = Masc_tui_message_layout.display_width tag in
  let row_cells = Masc_tui_message_layout.display_width row in
  if tag_cells = 0 || row_cells + tag_gap_cells + tag_cells > inner then row
  else fit_width row (inner - tag_cells) ^ tag

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

(* The team's spend over the window, for the Team title, summed over every
   Keeper the block knows -- its rows and its parked roll call. A Keeper the
   server's rows do not account for (not listed, its row unreadable, its
   store unread) is spend nobody read, so the total is then a floor or
   unknown.

   The forms the title may use, longest first: the whole total, then, for a
   stale answer, only how old it is. The title sheds a form whole, never
   part of a figure, and keeps the stale fact after the figures are gone. *)
let team_total (reading : overview_spend_reading) names =
  match reading with
  | Overview_spend_unread | Overview_spend_warming | Overview_spend_failed _ ->
      []
  | Overview_spend_read { window_minutes; keepers; freshness; undecodable = _ } -> (
      match names with
      | [] -> []
      | _ :: _ ->
          let window, stale_marker =
            match freshness with
            | Spend_fresh -> (window_text window_minutes, [])
            | Spend_stale { age_s; last_error = _ } ->
                let window =
                  Printf.sprintf "%s, %s old" (window_text window_minutes) (age_text age_s)
                in
                (window, [ Ansi.dim ^ window ^ Ansi.reset ])
          in
          let contributions =
            List.filter_map
              (fun name ->
                match List.assoc_opt name keepers with
                | None | Some (Spend_unread _) -> Some (Spend_unknown, Spend_unknown)
                | Some Spend_no_turns -> None
                | Some (Spend_turns { cost_usd; tokens }) -> Some (cost_usd, tokens))
              names
          in
          let text =
            match contributions with
            | [] -> Ansi.dim ^ "no turns" ^ Ansi.reset
            | first :: rest ->
                let cost_usd, tokens =
                  List.fold_left
                    (fun (cost_total, tokens_total) (cost, tokens) ->
                      (add_sums ( +. ) cost_total cost, add_sums ( + ) tokens_total tokens))
                    first rest
                in
                turns_text ~cost_usd ~tokens
          in
          Printf.sprintf "%s%s%s %s" Ansi.dim window Ansi.reset text :: stale_marker)

(* Cells between the Team title's counts and its spend. *)
let title_gap = "   "

(* The Team title that fits [cols]: the spend forms in order, each with the
   longest tail that fits, before any form is given up; the bare head last.
   Tails (the completion sparkline) are shed before the spend, and a spend
   form is kept whole or dropped, never cut inside a figure. *)
let fit_title ~cols ~head ~forms ~tails =
  let with_tails head = List.map (fun tail -> head ^ tail) tails @ [ head ] in
  let candidates =
    List.concat_map (fun form -> with_tails (head ^ title_gap ^ form)) forms
    @ with_tails head
  in
  match
    List.find_opt
      (fun title -> Masc_tui_message_layout.display_width title <= cols)
      candidates
  with
  | Some title -> title
  | None -> head

(* The lines under the Team block that say why no row carries a tag, or what
   the tags cannot vouch for. *)
let lines (reading : overview_spend_reading) =
  let dim text = Ansi.dim ^ text ^ Ansi.reset in
  let warn text = Theme.warn () ^ text ^ Ansi.reset in
  match reading with
  | Overview_spend_unread -> []
  | Overview_spend_warming -> [ dim "$ spend not read yet: the server is still adding it up" ]
  | Overview_spend_failed err -> [ dim ("$ spend unread: " ^ Terminal_text.single_line err) ]
  | Overview_spend_read { keepers; undecodable; freshness; window_minutes = _ } ->
      let stale =
        match freshness with
        | Spend_fresh | Spend_stale { last_error = None; _ } -> []
        | Spend_stale { age_s; last_error = Some err } ->
            [ warn
                (Printf.sprintf "$ spend is %s old, refresh failed: %s" (age_text age_s)
                   (Terminal_text.single_line err))
            ]
      in
      let unread_stores =
        List.filter_map
          (fun (_, spend) ->
            match spend with
            | Spend_unread reason -> Some reason
            | Spend_no_turns | Spend_turns _ -> None)
          keepers
      in
      let stores =
        match unread_stores with
        | [] -> []
        | reason :: rest ->
            [ warn
                (Printf.sprintf "$ spend unread for %d Keeper%s: %s"
                   (List.length rest + 1)
                   (match rest with [] -> "" | _ :: _ -> "s")
                   (Terminal_text.single_line reason))
            ]
      in
      let rows =
        if undecodable = 0 then []
        else
          [ warn
              (Printf.sprintf "$ spend unknown for %d unreadable Keeper row%s"
                 undecodable
                 (if undecodable = 1 then "" else "s"))
          ]
      in
      stale @ stores @ rows
