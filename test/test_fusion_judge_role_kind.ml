(* The judge role kind is one closed set spelled once: the board writer and
   the TUI reader both go through [Fusion_types]. These pin that the spelling
   round-trips, that an unknown spelling is refused, and that the writer's
   ["judge_role"] field is exactly the kind label of the role it projects.
   The reader side is pinned in test_tui_decode, which decodes a node and a
   tool-trace actor through the same set. *)

open Alcotest

let kinds =
  [ Fusion_types.Judge_single
  ; Fusion_types.Judge_refine
  ; Fusion_types.Judge_first
  ; Fusion_types.Judge_meta
  ; Fusion_types.Judge_stage_meta
  ; Fusion_types.Judge_final_meta
  ]
;;

let kind = testable Fusion_types.pp_judge_role_kind Fusion_types.equal_judge_role_kind

let test_every_label_round_trips () =
  List.iter
    (fun k ->
       let label = Fusion_types.judge_role_kind_label k in
       check (result kind string) label (Ok k) (Fusion_types.judge_role_kind_of_label label))
    kinds
;;

let test_an_unknown_label_is_refused () =
  check
    (result kind string)
    "jury"
    (Error {|unknown fusion judge role "jury"|})
    (Fusion_types.judge_role_kind_of_label "jury")
;;

(* [tool_trace_meta] is the exported writer that carries a judge actor's role
   onto the wire; its ["judge_role"] must be the kind label, nothing else. *)
let test_the_writer_spells_the_kind_it_projects () =
  List.iter
    (fun (role : Fusion_types.judge_role) ->
       let trace =
         { Fusion_types.empty_tool_trace with
           observed_actors = [ Fusion_types.Judge_actor { role; identity = "lens" } ]
         }
       in
       let written =
         Masc.Fusion_sink.tool_trace_meta trace
         |> Yojson.Safe.Util.member "observed_actors"
         |> Yojson.Safe.Util.index 0
         |> Yojson.Safe.Util.member "judge_role"
         |> Yojson.Safe.Util.to_string
       in
       check
         string
         (Fusion_types.show_judge_role role)
         (Fusion_types.judge_role_kind_label (Fusion_types.judge_role_kind role))
         written)
    [ Fusion_types.Single
    ; Fusion_types.Refine_pass
    ; Fusion_types.First "panelist-a"
    ; Fusion_types.Meta
    ; Fusion_types.Stage_meta 2
    ; Fusion_types.Final_meta
    ]
;;

let () =
  run
    "fusion_judge_role_kind"
    [ ( "one spelling"
      , [ test_case "every label round-trips" `Quick test_every_label_round_trips
        ; test_case "an unknown label is refused" `Quick test_an_unknown_label_is_refused
        ; test_case
            "the writer spells the kind it projects"
            `Quick
            test_the_writer_spells_the_kind_it_projects
        ] )
    ]
;;
