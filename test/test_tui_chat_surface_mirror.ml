(** [Masc_tui_keeper_chat_history.Surface] mirrors [Surface_ref.t].

    The TUI chat-history decoder is a small library with no [masc] dependency,
    so it cannot name the server's type and keeps its own copy of the
    vocabulary. A copy drifts silently: a surface added to [Surface_ref] would
    reach the pane as a row with no origin, which is the state this whole
    change came out of — 92 rows from 23 speakers all drawn as "you".

    So drive the real encoder. Every [Surface_ref.t] variant is serialised with
    its own [to_json] and pushed through the decoder; a kind the copy was not
    taught comes back unlabelled and fails here. *)

open Alcotest
module History = Masc_tui_keeper_chat_history

(* One value per constructor. Adding a variant to Surface_ref without adding it
   here fails to compile: the match below is exhaustive over the same type. *)
let every_surface : Masc.Surface_ref.t list =
  [ Masc.Surface_ref.Dashboard { session_id = Some "s1" }
  ; Masc.Surface_ref.Discord
      { guild_id = Some "g"
      ; channel_id = "c"
      ; channel_name = None
      ; parent_channel_id = None
      ; thread_id = None
      }
  ; Masc.Surface_ref.Slack
      { team_id = Some "t"
      ; channel_id = "c"
      ; channel_name = Some "kinossam-dev"
      ; thread_ts = None
      }
  ; Masc.Surface_ref.Webhook { source = "gh"; event_id = "e" }
  ; Masc.Surface_ref.Agent
  ; Masc.Surface_ref.Broadcast
  ; Masc.Surface_ref.Gate { label = "ops-room"; address = [] }
  ]
;;

let constructor_name : Masc.Surface_ref.t -> string = function
  | Masc.Surface_ref.Dashboard _ -> "Dashboard"
  | Masc.Surface_ref.Discord _ -> "Discord"
  | Masc.Surface_ref.Slack _ -> "Slack"
  | Masc.Surface_ref.Webhook _ -> "Webhook"
  | Masc.Surface_ref.Agent -> "Agent"
  | Masc.Surface_ref.Broadcast -> "Broadcast"
  | Masc.Surface_ref.Gate _ -> "Gate"
;;

let decoded_surface surface =
  let payload =
    `List
      [ `Assoc
          [ "id", `String "row"
          ; "role", `String "user"
          ; "content", `String "hello"
          ; "ts", `Float 1.0
          ; "speaker_name", `String "someone"
          ; "surface", Masc.Surface_ref.to_json surface
          ]
      ]
  in
  match History.rows_of_json payload with
  | Error detail -> failf "decode failed: %s" detail
  | Ok { History.rows = [ row ]; _ } ->
    (match row.History.kind with
     | History.Addressed_to_keeper { surface; _ } -> surface
     | History.Said_by_keeper | History.Autonomous_reply
     | History.Delivery_failed _ | History.Tool_calls _
     | History.Skill_activity _ | History.Reasoning _
     | History.Gate_activity _ | History.Memory_activity _ ->
       failf "expected an addressed row")
  | Ok _ -> failf "expected exactly one row"
;;

let test_every_server_surface_decodes () =
  List.iter
    (fun surface ->
      let name = constructor_name surface in
      check bool
        (name ^ " reaches the pane as an origin rather than nothing")
        true
        (Option.is_some (decoded_surface surface)))
    every_surface
;;

(* Dashboard is the one surface that deliberately adds no badge: a row typed at
   an operator surface is the operator, and saying so twice is noise. It still
   has to decode — [None] there would mean "unknown kind", which is a different
   fact and would hide a real drift. *)
let test_dashboard_decodes_but_adds_no_badge () =
  let dashboard = Masc.Surface_ref.Dashboard { session_id = None } in
  check bool "dashboard decodes" true
    (Option.is_some (decoded_surface dashboard));
  check string "and contributes no surface half" "vincent"
    (History.addressed_label (History.Named "vincent") (decoded_surface dashboard))
;;

let () =
  run
    "tui_chat_surface_mirror"
    [ ( "mirror"
      , [ test_case "every Surface_ref variant decodes" `Quick
            test_every_server_surface_decodes
        ; test_case "dashboard decodes without a badge" `Quick
            test_dashboard_decodes_but_adds_no_badge
        ] )
    ]
;;
