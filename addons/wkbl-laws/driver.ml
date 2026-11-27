(* Reads games as tab-separated text, runs the checker extracted from Laws.v
   and writes one line per reported violation.

   Rocq does not check this file. fixtures/law-cases.tsv and
   fixtures/law-cases.out pin it from both sides: the image build runs this
   program on the .tsv and compares its output with the .out, and the worker
   tests check that server.py writes the same .tsv and reads the same .out.

   Input, one block per game. Fields are separated by one tab, an empty
   field is an absent value, and a number is written in base 2:
     G  key  home-team  away-team  home-final  away-final  home-quarters  away-quarters
     L  label  team  player  points  two-made  three-made  free-made
   Quarters are numbers joined by commas. An L row belongs to the G row
   above it.

   Output, in the checker's order, then the number of games read:
     V  key  box_points       team   final   box-total
     V  key  quarter_points   team   final   quarter-total
     V  key  composition      label  points  composed
     V  key  foreign_team     label  team
     V  key  repeated_player  label  player
     C  games

   Base 2 keeps every number exact: the text maps digit by digit onto the
   extracted binary type, so no machine integer can overflow on either side. *)

let ( let* ) = Result.bind

let fail fmt = Printf.ksprintf (fun message -> Error message) fmt

let required name = function "" -> fail "%s is empty" name | text -> Ok text

(* text.[0] is the leading 1. The extracted positive nests its lowest bit
   outermost, so the last digit becomes the outer constructor. *)
let positive_of_bits text =
  let rec build i =
    if i = 0 then Ok Laws.XH
    else
      let* rest = build (i - 1) in
      match text.[i] with
      | '0' -> Ok (Laws.XO rest)
      | '1' -> Ok (Laws.XI rest)
      | _ -> fail "not a base-2 number: %S" text
  in
  build (String.length text - 1)

let number text =
  if String.equal text "0" then Ok Laws.N0
  else if text <> "" && text.[0] = '1' then
    let* p = positive_of_bits text in
    Ok (Laws.Npos p)
  else fail "not a base-2 number: %S" text

let optional parse = function
  | "" -> Ok None
  | text ->
      let* value = parse text in
      Ok (Some value)

let numbers text =
  List.fold_right
    (fun item acc ->
      let* rest = acc in
      let* value = number item in
      Ok (value :: rest))
    (String.split_on_char ',' text) (Ok [])

let rec bits = function
  | Laws.XH -> "1"
  | Laws.XO p -> bits p ^ "0"
  | Laws.XI p -> bits p ^ "1"

let show = function Laws.N0 -> "0" | Laws.Npos p -> bits p

type pending = {
  key : string;
  home : string Laws.side;
  away : string Laws.side;
  rows : (string, string, string) Laws.line list;  (* newest first *)
}

let side team final quarters = { Laws.side_team = team; final; quarters }

let parse_game = function
  | [ key; home; away; home_final; away_final; home_quarters; away_quarters ] ->
      let* key = required "game key" key in
      let* home = required "home team" home in
      let* away = required "away team" away in
      let* home_final = optional number home_final in
      let* away_final = optional number away_final in
      let* home_quarters = optional numbers home_quarters in
      let* away_quarters = optional numbers away_quarters in
      Ok { key; home = side home home_final home_quarters;
           away = side away away_final away_quarters; rows = [] }
  | fields -> fail "a G row has 8 fields, not %d" (List.length fields + 1)

let parse_line = function
  | [ label; team; player; points; two_made; three_made; free_made ] ->
      let* line_label = required "row label" label in
      let* line_team = required "row team" team in
      let line_player = if String.equal player "" then None else Some player in
      let* points = number points in
      let* two_made = number two_made in
      let* three_made = number three_made in
      let* free_made = number free_made in
      Ok { Laws.line_label; line_team; line_player; points; two_made; three_made;
           free_made }
  | fields -> fail "an L row has 8 fields, not %d" (List.length fields + 1)

let finish pending =
  { Laws.home = pending.home; away = pending.away; lines = List.rev pending.rows }

let read text =
  let rows = match List.rev (String.split_on_char '\n' text) with
    | "" :: rest -> List.rev rest
    | rows -> List.rev rows in
  let close games = function None -> games | Some pending -> pending :: games in
  let rec go games current = function
    | [] -> Ok (List.rev (close games current))
    | row :: rest -> (
        match String.split_on_char '\t' row with
        | "G" :: fields ->
            let* game = parse_game fields in
            go (close games current) (Some game) rest
        | "L" :: fields -> (
            match current with
            | None -> fail "an L row comes before any G row"
            | Some pending ->
                let* line = parse_line fields in
                go games (Some { pending with rows = line :: pending.rows }) rest)
        | _ -> fail "unknown row: %S" row)
  in
  go [] None rows

let report key = function
  | Laws.Box_points_differ (team, final, box) ->
      [ key; "box_points"; team; show final; show box ]
  | Laws.Quarter_points_differ (team, final, quarters) ->
      [ key; "quarter_points"; team; show final; show quarters ]
  | Laws.Composition_differs (label, points, composed) ->
      [ key; "composition"; label; show points; show composed ]
  | Laws.Foreign_team (label, team) -> [ key; "foreign_team"; label; team ]
  | Laws.Repeated_player (label, player) -> [ key; "repeated_player"; label; player ]

let () =
  match read (In_channel.input_all stdin) with
  | Error message ->
      prerr_endline ("wkbl-laws-check: " ^ message);
      exit 2
  | Ok games ->
      let out = Buffer.create 4096 in
      List.iter
        (fun pending ->
          List.iter
            (fun violation ->
              Buffer.add_string out (String.concat "\t" ("V" :: report pending.key violation));
              Buffer.add_char out '\n')
            (Laws.check String.equal String.equal (finish pending)))
        games;
      Printf.bprintf out "C\t%d\n" (List.length games);
      print_string (Buffer.contents out)
