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
    ?(draft = false) number : Server.pull_request =
  { repo_slug = "jeong-sik/masc"
  ; number
  ; title = Printf.sprintf "pull %d" number
  ; head_branch = Printf.sprintf "fix/%d" number
  ; draft
  ; checks
  ; review
  ; mergeable = Server.Mergeable
  ; author = Some "someone"
  ; updated_at = 1_790_000_000.
  }

let entry repository_id pulls : Server.repository_entry =
  { repository_id; url = "https://github.com/jeong-sik/" ^ repository_id; slug = None; pulls }

let observed_at = 1_790_000_000.

let every_state : Server.snapshot =
  { reader = Server.Reader_ready { keeper = "pr-updater" }
  ; repositories_error = None
  ; rejected_token_digest = None
  ; keepers = Server.Keepers_listed []
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
           check int "every pull decodes" 5 (List.length pulls);
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

let test_lines_say_what_needs_a_person () =
  let lines = lines_of every_state in
  let has needle =
    List.exists
      (fun line ->
        let n = String.length needle and l = String.length line in
        let rec at i = i + n <= l && (String.sub line i n = needle || at (i + 1)) in
        at 0)
      lines
  in
  check bool "failing checks are counted" true (has "1 checks failing");
  check bool "changes requested are counted" true (has "1 changes requested");
  check bool "drafts are counted" true (has "1 draft");
  check bool "undecodable rows are counted" true (has "1 unreadable");
  check bool "a repository not on GitHub draws nothing" false (has "mirror");
  check bool "a failed repository says why" true (has "refused  not read: token_rejected");
  let not_ready = lines_of { every_state with reader = Server.Reader_not_declared } in
  check int "a reader not ready is one line" 1 (List.length not_ready)

let () =
  run "tui_repository_pulls"
    [ ( "server JSON"
      , [ test_case "every repository state decodes" `Quick test_every_server_state_decodes
        ; test_case "every reader state decodes" `Quick test_every_reader_state_decodes
        ; test_case "lines say what needs a person" `Quick test_lines_say_what_needs_a_person
        ] )
    ]
