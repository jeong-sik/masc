(* The Overview's pull request reading (RFC-0465): the decoder for
   [GET /api/v1/repositories/pulls] and the lines drawn under the Team block.
   A library so a test can feed it the server's own encoder output. *)

open Masc_tui_types
open Tui_decode
open Masc_tui_ansi

let ( let* ) = Result.bind

let decode_open_pull json =
  let* op_number = required_int_field json "number" in
  let* op_title = required_string_field json "title" in
  let* op_head_branch = required_string_field json "head_branch" in
  let* op_draft =
    match Yojson.Safe.Util.member "draft" json with
    | `Bool draft -> Ok draft
    | _ -> Error "draft is not a boolean"
  in
  let* checks = required_string_field json "checks" in
  let* op_checks =
    match checks with
    | "passing" -> Ok Pull_checks_passing
    | "failing" -> Ok Pull_checks_failing
    | "running" -> Ok Pull_checks_running
    | "none" -> Ok Pull_checks_none
    | other -> Error ("unknown checks " ^ other)
  in
  let* review = required_string_field json "review" in
  let* op_review =
    match review with
    | "approved" -> Ok Pull_review_approved
    | "changes_requested" -> Ok Pull_review_changes_requested
    | "waiting" -> Ok Pull_review_waiting
    | "none" -> Ok Pull_review_none
    | other -> Error ("unknown review " ^ other)
  in
  let* mergeable = required_string_field json "mergeable" in
  let* op_mergeable =
    match mergeable with
    | "mergeable" -> Ok Pull_mergeable
    | "conflicting" -> Ok Pull_conflicting
    | "unknown" -> Ok Pull_mergeable_unknown
    | other -> Error ("unknown mergeable " ^ other)
  in
  let* op_keeper =
    match Yojson.Safe.Util.member "keeper" json with
    | `Null -> Ok None
    | `String name -> Ok (Some name)
    | _ -> Error "keeper is neither a string nor null"
  in
  Ok
    { op_number; op_title; op_head_branch; op_draft; op_checks; op_review
    ; op_mergeable; op_keeper
    }

let decode_repository_pulls json =
  let* rp_repository = required_string_field json "repository_id" in
  let* pulls = required_object_field json "pulls" in
  let* state = required_string_field pulls "state" in
  let* rp_state =
    match state with
    | "not_read" -> Ok Repo_pulls_not_read
    | "not_github" -> Ok Repo_not_github
    | "read" ->
        let* rows = required_list_field pulls "pulls" in
        let* server_undecodable = required_int_field pulls "undecodable" in
        let decoded, undecodable =
          List.fold_right
            (fun row (decoded, undecodable) ->
              match decode_open_pull row with
              | Ok pull -> (pull :: decoded, undecodable)
              | Error _ -> (decoded, undecodable + 1))
            rows ([], server_undecodable)
        in
        Ok (Repo_pulls_read { pulls = decoded; undecodable })
    | "failed" ->
        let* failure = required_object_field pulls "failure" in
        let* kind = required_string_field failure "kind" in
        (* The detail each kind carries: when a rate limit lifts, the HTTP
           status, the first GraphQL message, or a transport message. *)
        let member key = Yojson.Safe.Util.member key failure in
        let reset_at =
          match member "reset_at" with
          | `Float at -> Some at
          | `Int seconds -> Some (float_of_int seconds)
          | _ -> None
        in
        let detail =
          match (reset_at, member "status", member "messages", member "message") with
          | Some at, _, _, _ ->
              let tm = Unix.gmtime at in
              Some (Printf.sprintf "resets %02d:%02dZ" tm.Unix.tm_hour tm.Unix.tm_min)
          | None, `Int status, _, _ -> Some (Printf.sprintf "HTTP %d" status)
          | None, _, `List (`String first :: _), _ -> Some first
          | None, _, _, `String message -> Some message
          | None, _, _, _ -> None
        in
        Ok
          (Repo_pulls_failed
             (match detail with Some d -> kind ^ ": " ^ d | None -> kind))
    | other -> Error ("unknown repository pulls state " ^ other)
  in
  Ok { rp_repository; rp_state }

let decode_reading json =
  let* reader_json = required_object_field json "reader" in
  let* reader_state = required_string_field reader_json "state" in
  let* reader =
    match reader_state with
    | "ready" ->
        let* keeper = required_string_field reader_json "keeper" in
        Ok (Pulls_reader_ready keeper)
    | "not_declared" ->
        Ok
          (Pulls_reader_not_ready
             "not_declared (no [repositories] pr_reader read yet)")
    | "declaration_invalid" | "keeper_missing" | "token_unavailable" ->
        let* reason = optional_string_field reader_json "reason" in
        let* keeper = optional_string_field reader_json "keeper" in
        Ok
          (Pulls_reader_not_ready
             (String.concat " "
                (List.filter_map Fun.id
                   [ Some reader_state; keeper; reason ])))
    | other -> Error ("unknown pull request reader state " ^ other)
  in
  let* keepers_json = required_object_field json "keepers" in
  let* keepers_state = required_string_field keepers_json "state" in
  let* keepers =
    match keepers_state with
    | "not_listed" -> Ok Pulls_keepers_not_listed
    | "listed" -> Ok Pulls_keepers_listed
    | "list_failed" ->
        let* reason = required_string_field keepers_json "reason" in
        Ok (Pulls_keepers_failed reason)
    | other -> Error ("unknown Keeper list state " ^ other)
  in
  let* rows = required_list_field json "repositories" in
  (* Row by row: one repository this build cannot read says so on its own
     line instead of blanking every other repository's line. *)
  let repositories =
    List.mapi
      (fun index row ->
        match decode_repository_pulls row with
        | Ok decoded -> decoded
        | Error err ->
            let rp_repository =
              match Yojson.Safe.Util.member "repository_id" row with
              | `String id -> id
              | _ -> Printf.sprintf "repository #%d" (index + 1)
            in
            { rp_repository; rp_state = Repo_pulls_failed ("unreadable: " ^ err) })
      rows
  in
  let* repositories_error = optional_string_field json "repositories_error" in
  Ok (Overview_pulls_read { reader; keepers; repositories_error; repositories })


(* One line per registered GitHub repository the server reads pull requests
   for (RFC-0465): how many are open and how many need a person -- failing
   checks, changes requested -- beside the Keepers doing the work. A
   repository that is not on GitHub has nothing to say and draws nothing. A
   reader the server cannot use is one line saying why, which is the setup
   step left to take. *)
let lines (reading : overview_pulls_reading) =
  let dim text = Ansi.dim ^ text ^ Ansi.reset in
  match reading with
  | Overview_pulls_unread -> []
  | Overview_pulls_failed err ->
      [ dim ("\xe2\x87\x85 pull requests unread: " ^ Terminal_text.single_line err) ]
  | Overview_pulls_read { reader = Pulls_reader_not_ready reason; _ } ->
      [ dim ("\xe2\x87\x85 pull requests not read: " ^ Terminal_text.single_line reason) ]
  | Overview_pulls_read
      { reader = Pulls_reader_ready _; keepers; repositories_error; repositories } ->
      let stale =
        match repositories_error with
        | None -> []
        | Some err ->
            [ Printf.sprintf "%s\xe2\x87\x85 pull request rows may be old: %s%s"
                (Theme.warn ()) (Terminal_text.single_line err) Ansi.reset ]
      in
      (* Without the Keeper list a PR with no Keeper is not "nobody's"; the
         line says the list is missing instead of counting unmatched PRs. *)
      let keepers_line =
        match keepers with
        | Pulls_keepers_failed reason ->
            [ Printf.sprintf "%s\xe2\x87\x85 Keeper list unread, PRs not matched: %s%s"
                (Theme.warn ()) (Terminal_text.single_line reason) Ansi.reset ]
        | Pulls_keepers_listed | Pulls_keepers_not_listed -> []
      in
      let rows =
      List.filter_map
        (fun (row : repository_pulls_row) ->
          let repository = Terminal_text.single_line row.rp_repository in
          match row.rp_state with
          | Repo_not_github -> None
          | Repo_pulls_not_read ->
              Some (dim (Printf.sprintf "\xe2\x87\x85 %s  not read yet" repository))
          | Repo_pulls_failed failure ->
              Some
                (Printf.sprintf "%s\xe2\x87\x85%s %s  %snot read: %s%s" (Theme.warn ())
                   Ansi.reset repository Ansi.dim
                   (Terminal_text.single_line failure) Ansi.reset)
          | Repo_pulls_read { pulls; undecodable } ->
              let count predicate = List.length (List.filter predicate pulls) in
              let failing =
                count (fun (pull : open_pull) ->
                    match pull.op_checks with
                    | Pull_checks_failing -> true
                    | Pull_checks_passing | Pull_checks_running | Pull_checks_none -> false)
              in
              let changes =
                count (fun (pull : open_pull) ->
                    match pull.op_review with
                    | Pull_review_changes_requested -> true
                    | Pull_review_approved | Pull_review_waiting | Pull_review_none -> false)
              in
              let drafts = count (fun (pull : open_pull) -> pull.op_draft) in
              let conflicting =
                count (fun (pull : open_pull) ->
                    match pull.op_mergeable with
                    | Pull_conflicting -> true
                    | Pull_mergeable | Pull_mergeable_unknown -> false)
              in
              (* A PR no Keeper wrote is on no Team row; counting it here
                 keeps it from vanishing. Counted only when the Keeper list
                 was read, since otherwise every PR would look unmatched. *)
              let not_by_keeper =
                match keepers with
                | Pulls_keepers_listed ->
                    count (fun (pull : open_pull) -> Option.is_none pull.op_keeper)
                | Pulls_keepers_not_listed | Pulls_keepers_failed _ -> 0
              in
              let parts =
                List.filter_map Fun.id
                  [ Some (Printf.sprintf "%d open" (List.length pulls))
                  ; (if failing > 0 then
                       Some (Printf.sprintf "%s%d checks failing%s" (Theme.bad ()) failing Ansi.reset)
                     else None)
                  ; (if changes > 0 then
                       Some (Printf.sprintf "%s%d changes requested%s" (Theme.warn ()) changes Ansi.reset)
                     else None)
                  ; (if conflicting > 0 then
                       Some (Printf.sprintf "%s%d conflicting%s" (Theme.warn ()) conflicting Ansi.reset)
                     else None)
                  ; (if drafts > 0 then Some (Printf.sprintf "%d draft" drafts) else None)
                  ; (if not_by_keeper > 0 then
                       Some (Printf.sprintf "%s%d not by a Keeper%s" Ansi.dim not_by_keeper Ansi.reset)
                     else None)
                  ; (if undecodable > 0 then
                       Some (Printf.sprintf "%d unreadable" undecodable)
                     else None)
                  ]
              in
              Some
                (Printf.sprintf "%s\xe2\x87\x85%s %s  %s" (Theme.info ()) Ansi.reset
                   repository
                   (String.concat " \xc2\xb7 " parts)))
        repositories
      in
      (* A ready reader with nothing on GitHub to read says so; drawing no
         line would look the same as not having loaded. *)
      match stale @ keepers_line @ rows with
      | [] -> [ dim "\xe2\x87\x85 pull requests: no registered GitHub repository" ]
      | lines -> lines

