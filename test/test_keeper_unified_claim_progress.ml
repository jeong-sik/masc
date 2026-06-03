open Alcotest

module KTP = Masc.Keeper_tool_progress

let test_claim_tool_classification_covers_supported_claim_tools () =
  check
    bool
    "keeper claim is claim tool"
    true
    (KTP.is_claim_tool_name "keeper_task_claim");
  check
    bool
    "masc claim next is claim tool"
    true
    (KTP.is_claim_tool_name "masc_claim_next");
  check
    bool
    "removed claim task alias is not claim tool"
    false
    (KTP.is_claim_tool_name "masc_claim_task");
  check
    bool
    "task creation is not claim tool"
    false
    (KTP.is_claim_tool_name "keeper_task_create");
  check
    bool
    "task list is not claim tool"
    false
    (KTP.is_claim_tool_name "keeper_tasks_list")
;;

let () =
  run
    "keeper_unified_claim_progress"
    [ ( "claim_classification"
      , [ test_case
            "claim tool classification covers supported claim tools"
            `Quick
            test_claim_tool_classification_covers_supported_claim_tools
        ] )
    ]
;;
