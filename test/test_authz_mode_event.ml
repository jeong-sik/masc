(* Checks for the body of a mode event: the bytes it writes, that it reads back
   what it wrote, and every way a body fails to be one. A last case puts the
   body in a record and reads the record back. No files, clock, or network. *)

open Authz_types
open Authz_records
module M = Authz_mode_event
module R = Authz_record

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let workspace_of text = get (Workspace_id.of_string text)
let workspace_text = "workspace-1"
let workspace = workspace_of workspace_text

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let to_body_exn t =
  match M.to_body t with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

(* An exhaustive match, so a new event cannot be added without this file. *)
let ordinal = function
  | M.Fresh_bootstrap -> 0
  | M.Off -> 1
  | M.Reactivate -> 2
;;

let events_are_all_listed () =
  let sorted events = List.sort Int.compare (List.map ordinal events) in
  Alcotest.(check (list int)) "events names every event once" [ 0; 1; 2 ] (sorted M.events)
;;

(* The words that name an event on disk. Renaming one orphans every record
   written with it. *)
let labels_are_the_names_on_disk () =
  Alcotest.(check (list string))
    "labels"
    [ "fresh_bootstrap"; "off"; "reactivate" ]
    (List.map M.event_label M.events);
  List.iter
    (fun event ->
      match M.event_of_label (M.event_label event) with
      | Some back -> Alcotest.(check int) (M.event_label event) (ordinal event) (ordinal back)
      | None -> Alcotest.failf "label %s does not read back" (M.event_label event))
    M.events;
  List.iter
    (fun label ->
      Alcotest.(check bool) (label ^ " is no label") true (Option.is_none (M.event_of_label label)))
    [ ""; "Off"; "off "; " off"; "grant"; "Fresh_bootstrap" ]
;;

let bytes_of_the_body () =
  List.iter
    (fun (event, expected) ->
      Alcotest.(check string)
        (M.event_label event)
        expected
        (Authz_body.to_string (to_body_exn { M.event; workspace_id = workspace })))
    [ M.Fresh_bootstrap, {|{"event":"fresh_bootstrap","workspace_id":"workspace-1"}|}
    ; M.Off, {|{"event":"off","workspace_id":"workspace-1"}|}
    ; M.Reactivate, {|{"event":"reactivate","workspace_id":"workspace-1"}|}
    ]
;;

(* An id of one letter, one with every punctuation mark the alphabet allows, and
   the longest one. *)
let workspace_texts =
  [ workspace_text; "a"; "A.b_c:d-e"; String.make Authz_id.max_length 'w' ]
;;

let a_body_reads_back () =
  List.iter
    (fun event ->
      List.iter
        (fun text ->
          let t = { M.event; workspace_id = workspace_of text } in
          match M.of_body (to_body_exn t) with
          | Ok back ->
            Alcotest.(check bool) (M.event_label event ^ " in " ^ text) true (M.equal t back)
          | Error error -> Alcotest.failf "refused: %s" (M.error_to_string error))
        workspace_texts)
    M.events
;;

let equality_looks_at_both_members () =
  let t = { M.event = M.Off; workspace_id = workspace } in
  Alcotest.(check bool) "itself" true (M.equal t t);
  Alcotest.(check bool) "another event" false (M.equal t { t with M.event = M.Reactivate });
  Alcotest.(check bool)
    "another workspace"
    false
    (M.equal t { t with M.workspace_id = workspace_of "workspace-2" })
;;

(* ---- the bodies that are not mode events ---- *)

let id_error_name : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte %d" index
  | Authz_id.Path_segment -> "path segment"
;;

let error_name : M.error -> string = function
  | M.Not_an_object -> "not an object"
  | M.Wrong_members -> "wrong members"
  | M.Unknown_event label -> Printf.sprintf "unknown event %S" label
  | M.Invalid_workspace_id error -> "invalid workspace id: " ^ id_error_name error
;;

let event_member text = "event", `String text
let workspace_member text = "workspace_id", `String text

let refusals =
  [ "null", `Null, "not an object"
  ; "a string", `String "off", "not an object"
  ; "an integer", `Int 1, "not an object"
  ; "a boolean", `Bool true, "not an object"
  ; "a list", `List [ `String "off" ], "not an object"
  ; "an empty object", `Assoc [], "wrong members"
  ; "no workspace", `Assoc [ event_member "off" ], "wrong members"
  ; "no event", `Assoc [ workspace_member workspace_text ], "wrong members"
  ; ( "the members in another order"
    , `Assoc [ workspace_member workspace_text; event_member "off" ]
    , "wrong members" )
  ; ( "an extra member"
    , `Assoc [ event_member "off"; workspace_member workspace_text; "extra", `Int 1 ]
    , "wrong members" )
  ; ( "an event that is not a string"
    , `Assoc [ "event", `Int 1; workspace_member workspace_text ]
    , "wrong members" )
  ; ( "a workspace id that is not a string"
    , `Assoc [ event_member "off"; "workspace_id", `Int 1 ]
    , "wrong members" )
  ; ( "the label in capitals"
    , `Assoc [ event_member "Off"; workspace_member workspace_text ]
    , "unknown event \"Off\"" )
  ; ( "an empty label"
    , `Assoc [ event_member ""; workspace_member workspace_text ]
    , "unknown event \"\"" )
  ; ( "a label with a space"
    , `Assoc [ event_member "off "; workspace_member workspace_text ]
    , "unknown event \"off \"" )
  ; ( "the label of an event that is not a mode event"
    , `Assoc [ event_member "grant"; workspace_member workspace_text ]
    , "unknown event \"grant\"" )
  ; ( "an empty workspace id"
    , `Assoc [ event_member "off"; workspace_member "" ]
    , "invalid workspace id: empty" )
  ; ( "a workspace id that is a path segment"
    , `Assoc [ event_member "off"; workspace_member ".." ]
    , "invalid workspace id: path segment" )
  ; ( "a workspace id with a slash"
    , `Assoc [ event_member "off"; workspace_member "a/b" ]
    , "invalid workspace id: invalid byte 1" )
  ; ( "a workspace id that is too long"
    , `Assoc [ event_member "off"; workspace_member (String.make (Authz_id.max_length + 1) 'a') ]
    , "invalid workspace id: too long" )
  ; ( "the event is read before the workspace id"
    , `Assoc [ event_member "bogus"; workspace_member "" ]
    , "unknown event \"bogus\"" )
  ]
;;

let a_body_that_is_not_a_mode_event_is_refused () =
  List.iter
    (fun (label, json, expected) ->
      match M.of_body (body_of_json json) with
      | Ok _ -> Alcotest.failf "%s: the body was taken" label
      | Error error -> Alcotest.(check string) label expected (error_name error))
    refusals
;;

let contains ~sub text =
  let sub_length = String.length sub
  and length = String.length text in
  let rec at index =
    index + sub_length <= length && (String.equal (String.sub text index sub_length) sub || at (index + 1))
  in
  at 0
;;

(* A refusal names the label it did not know, so that the one who reads it can
   find the record. Each reason has its own text. *)
let errors_are_told_apart () =
  let texts =
    [ M.error_to_string M.Not_an_object
    ; M.error_to_string M.Wrong_members
    ; M.error_to_string (M.Unknown_event "bogus")
    ; M.error_to_string (M.Invalid_workspace_id Authz_id.Empty)
    ; M.error_to_string (M.Invalid_workspace_id Authz_id.Path_segment)
    ]
  in
  Alcotest.(check int)
    "each reason has its own text"
    (List.length texts)
    (List.length (List.sort_uniq String.compare texts));
  Alcotest.(check bool)
    "the label is in the text"
    true
    (contains ~sub:"bogus" (M.error_to_string (M.Unknown_event "bogus")))
;;

(* ---- the body in a record ---- *)

let a_record_carries_the_body () =
  List.iter
    (fun event ->
      let t = { M.event; workspace_id = workspace } in
      match
        R.make
          ~head:R.genesis
          ~at_ms:1000
          ~author:Author.Local_operator
          ~kind:R.Kind.Mode_event
          ~body:(to_body_exn t)
      with
      | Error (R.Author_not_admitted _) ->
        Alcotest.fail "the local operator may write a mode event"
      | Ok record ->
        (match R.of_line ~head:R.genesis (R.to_line record) with
         | Error _ -> Alcotest.fail "the line of the record is not read back"
         | Ok read ->
           Alcotest.(check string)
             "the kind"
             "mode_event"
             (R.Kind.to_string read.R.kind);
           (match M.of_body read.R.body with
            | Ok back ->
              Alcotest.(check bool) (M.event_label event) true (M.equal t back)
            | Error error -> Alcotest.failf "refused: %s" (M.error_to_string error))))
    M.events
;;

let () =
  Alcotest.run
    "authz_mode_event"
    [ ( "events"
      , [ Alcotest.test_case "all listed" `Quick events_are_all_listed
        ; Alcotest.test_case "labels on disk" `Quick labels_are_the_names_on_disk
        ] )
    ; ( "body"
      , [ Alcotest.test_case "bytes" `Quick bytes_of_the_body
        ; Alcotest.test_case "reads back" `Quick a_body_reads_back
        ; Alcotest.test_case "equality" `Quick equality_looks_at_both_members
        ; Alcotest.test_case "refusals" `Quick a_body_that_is_not_a_mode_event_is_refused
        ; Alcotest.test_case "texts" `Quick errors_are_told_apart
        ] )
    ; "record", [ Alcotest.test_case "carries the body" `Quick a_record_carries_the_body ]
    ]
;;
