(* The TUI reads GET /api/v1/repositories/pulls with a decoder written by
   hand against the server's encoder (RFC-0465). These cases feed the
   server's own [snapshot_to_yojson] output to that decoder, so a word the
   server changes turns this suite red instead of blanking a repository
   line in the Overview. *)

open Alcotest
module Server = Server_repository_pulls
module Pulls = Masc_tui_repository_pulls
open Masc_tui_types

let pull ?(checks = Server.Checks_passing) ?(review = Server.Review_waiting)
    ?(draft = false) ?(mergeable = Server.Mergeable) ?(author = Some "someone")
    number : Server.pull_request =
  { repo_slug = "jeong-sik/masc"
  ; number
  ; title = Printf.sprintf "pull %d" number
  ; head_branch = Printf.sprintf "fix/%d" number
  ; draft
  ; checks
  ; review
  ; mergeable
  ; author
  ; updated_at = 1_790_000_000.
  }

let entry repository_id pulls : Server.repository_entry =
  { repository_id; url = "https://github.com/jeong-sik/" ^ repository_id; slug = None; pulls }

let observed_at = 1_790_000_000.

let every_state : Server.snapshot =
  { reader = Server.Reader_ready { keeper = "pr-updater" }
  ; repositories_error = None
  ; rejected_token_digest = None
  ; keepers = Server.Keepers_listed [ "k-author"; "k-idle" ]
  ; repositories =
      [ entry "masc"
          (Server.Pulls_read
             { observed_at
             ; undecodable = 1
             ; pulls =
                 [ pull 1
                 ; pull ~checks:Server.Checks_failing 2
                 ; pull ~review:Server.Review_changes_requested 3
                 ; pull ~checks:Server.Checks_running ~review:Server.Review_approved 4
                 ; pull ~checks:Server.Checks_none ~review:Server.Review_none ~draft:true 5
                 ; pull ~author:(Some "k-author") ~mergeable:Server.Conflicting 6
                 ; pull ~author:None ~mergeable:Server.Mergeable_unknown 7
                 ; pull ~author:(Some "k-author") ~checks:Server.Checks_failing 8
                 ]
             })
      ; entry "mirror" Server.Pulls_not_github
      ; entry "fresh" Server.Pulls_not_read
      ; entry "limited"
          (Server.Pulls_failed
             { observed_at; failure = Server.Rate_limited { reset_at = Some 1_790_003_600. } })
      ; entry "hidden" (Server.Pulls_failed { observed_at; failure = Server.Repository_not_visible })
      ; entry "refused" (Server.Pulls_failed { observed_at; failure = Server.Token_rejected })
      ; entry "policy" (Server.Pulls_failed { observed_at; failure = Server.Forbidden { status = 403 } })
      ; entry "broken" (Server.Pulls_failed { observed_at; failure = Server.Http_status { status = 502 } })
      ; entry "graphql"
          (Server.Pulls_failed { observed_at; failure = Server.Graphql_errors { messages = [ "boom" ] } })
      ; entry "wire" (Server.Pulls_failed { observed_at; failure = Server.Transport_failed "reset" })
      ; entry "shape"
          (Server.Pulls_failed { observed_at; failure = Server.Response_unreadable "no nodes" })
      ]
  }

let decode snapshot =
  match Pulls.decode_reading (Server.snapshot_to_yojson snapshot) with
  | Ok reading -> reading
  | Error err -> failf "the server's own JSON did not decode: %s" err

let strip text =
  let buf = Buffer.create (String.length text) in
  let rec go i =
    if i >= String.length text then ()
    else if text.[i] = '\027' then (
      let j = ref (i + 1) in
      while !j < String.length text && not (Char.equal text.[!j] 'm') do incr j done;
      go (!j + 1))
    else (Buffer.add_char buf text.[i]; go (i + 1))
  in
  go 0; Buffer.contents buf

let test_every_server_state_decodes () =
  match decode every_state with
  | Overview_pulls_read { reader = Pulls_reader_ready "pr-updater"; repositories; _ } ->
      let state_of id =
        (List.find (fun (row : repository_pulls_row) -> String.equal row.rp_repository id)
           repositories).rp_state
      in
      (match state_of "masc" with
       | Repo_pulls_read { pulls; undecodable } ->
           check int "every pull decodes" 8 (List.length pulls);
           let six = List.find (fun (p : open_pull) -> p.op_number = 6) pulls in
           check (option string) "the author join reaches the TUI" (Some "k-author")
             six.op_keeper;
           check bool "conflicting reaches the TUI" true
             (match six.op_mergeable with
              | Pull_conflicting -> true
              | Pull_mergeable | Pull_mergeable_unknown -> false);
           check int "the server's undecodable count survives" 1 undecodable
       | _ -> fail "a read repository decodes as read");
      (match state_of "mirror" with Repo_not_github -> () | _ -> fail "not_github");
      (match state_of "fresh" with Repo_pulls_not_read -> () | _ -> fail "not_read");
      List.iter
        (fun id ->
          match state_of id with
          | Repo_pulls_failed _ -> ()
          | _ -> failf "failure kind of %s did not decode as a failure" id)
        [ "limited"; "hidden"; "refused"; "policy"; "broken"; "graphql"; "wire"; "shape" ]
  | _ -> fail "a ready reader decodes as ready"

let test_every_reader_state_decodes () =
  List.iter
    (fun (reader, label) ->
      match decode { every_state with reader } with
      | Overview_pulls_read { reader = Pulls_reader_not_ready _; _ } -> ()
      | _ -> failf "%s must decode as not ready" label)
    [ (Server.Reader_not_declared, "not declared")
    ; (Server.Reader_declaration_invalid "bad", "declaration invalid")
    ; (Server.Reader_keeper_missing { keeper = "k" }, "keeper missing")
    ; (Server.Reader_token_unavailable { keeper = "k"; reason = "none" }, "token unavailable")
    ]

let lines_of snapshot = List.map strip (Pulls.lines (decode snapshot))

let contains needle line =
  let n = String.length needle and l = String.length line in
  let rec at i = i + n <= l && (String.equal (String.sub line i n) needle || at (i + 1)) in
  at 0

let test_lines_say_what_needs_a_person () =
  let lines = lines_of every_state in
  let has needle = List.exists (contains needle) lines in
  check bool "failing checks are counted" true (has "2 checks failing");
  check bool "changes requested are counted" true (has "1 changes requested");
  check bool "drafts are counted" true (has "1 draft");
  check bool "conflicts are counted" true (has "1 conflicting");
  check bool "PRs no Keeper wrote are counted" true (has "6 not by a Keeper");
  check bool "undecodable rows are counted" true (has "1 unreadable");
  check bool "a repository not on GitHub draws nothing" false (has "mirror");
  check bool "a failed repository says why" true (has "refused  not read: token_rejected");
  let not_ready = lines_of { every_state with reader = Server.Reader_not_declared } in
  check int "a reader not ready is one line" 1 (List.length not_ready)

let test_keeper_list_states () =
  (match decode { every_state with keepers = Server.Keepers_not_listed } with
   | Overview_pulls_read { keepers = Pulls_keepers_not_listed; _ } -> ()
   | _ -> fail "not_listed decodes");
  (match decode { every_state with keepers = Server.Keepers_list_failed "EACCES" } with
   | Overview_pulls_read { keepers = Pulls_keepers_failed "EACCES"; _ } -> ()
   | _ -> fail "list_failed decodes with its reason");
  let lines =
    lines_of { every_state with keepers = Server.Keepers_list_failed "EACCES" }
  in
  check bool "an unread Keeper list is said, not counted as unmatched" true
    (List.exists (contains "Keeper list unread") lines)

(* The Team row tag: a Keeper with PRs gets its first PR's number and a
   "+N" for the rest; a Keeper with none, and every Keeper while the list
   was not read, gets nothing. *)
let test_keeper_tag () =
  let tag = Pulls.keeper_tag (decode every_state) in
  let author = strip (tag "k-author") in
  check bool "the Keeper's first PR is tagged" true (contains "#6" author);
  check bool "its second PR is counted" true (contains "+1" author);
  (* The glyph is the first PR's check state, not a fixed mark. k-author's
     first PR (6) passes and its second (8) fails, so the tag carries the
     passing glyph and not the failing one. *)
  check bool "the first PR's passing checks are drawn" true (contains "\xe2\x9c\x93" author);
  check bool "a later failing PR does not change the first glyph" false
    (contains "\xe2\x9c\x97" author);
  (* A reading whose first PR fails separates "the glyph comes from the state"
     from "the glyph is a fixed mark": a hard-coded "\xe2\x9c\x93" would pass
     both checks above, but not this one. *)
  let failing_first =
    { every_state with
      repositories =
        [ entry "masc"
            (Server.Pulls_read
               { observed_at
               ; undecodable = 0
               ; pulls = [ pull ~author:(Some "k-author") ~checks:Server.Checks_failing 6 ]
               })
        ]
    }
  in
  let failing = strip (Pulls.keeper_tag (decode failing_first) "k-author") in
  check bool "a failing first PR draws the failing glyph" true (contains "\xe2\x9c\x97" failing);
  check bool "a failing first PR does not draw the passing glyph" false
    (contains "\xe2\x9c\x93" failing);
  check string "a Keeper with no PR gets no tag" "" (tag "k-idle");
  check string "a PR author who is no Keeper is on no row" "" (tag "someone");
  let unread =
    Pulls.keeper_tag (decode { every_state with keepers = Server.Keepers_list_failed "x" })
  in
  (* The server nulls every PR's keeper while its list is unread; this
     checks the two sides together. *)
  check string "an unread Keeper list attaches nothing" "" (unread "k-author")

let () =
  run "tui_repository_pulls"
    [ ( "server JSON"
      , [ test_case "every repository state decodes" `Quick test_every_server_state_decodes
        ; test_case "every reader state decodes" `Quick test_every_reader_state_decodes
        ; test_case "lines say what needs a person" `Quick test_lines_say_what_needs_a_person
        ; test_case "keeper list states" `Quick test_keeper_list_states
        ; test_case "keeper tag" `Quick test_keeper_tag
        ] )
    ]
