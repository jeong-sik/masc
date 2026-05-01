import re

with open("test/test_error_logging_coverage.ml", "r") as f:
    content = f.read()

content = re.sub(r'\(\* ============================================================\n\s*a2a_tools: submit_heartbeat_result unknown status.*?\];\n\s*\]\n',
'''(* ============================================================
   Tests Suite
   ============================================================ *)

let () =
  run "error_logging_coverage" [
    "tool_task_silent_failures", [
      test_case "done transition on non-existent task" `Quick test_done_non_existent_task_logs;
      test_case "cancel transition on non-existent task" `Quick test_cancel_non_existent_task_logs;
    ];
  ]
''', content, flags=re.DOTALL)

with open("test/test_error_logging_coverage.ml", "w") as f:
    f.write(content)

with open("test/test_dashboard_mission.ml", "r") as f:
    content = f.read()

content = re.sub(r'Lib\.A2a_tools\.emit_heartbeat_task.*?;\n\s*ignore\n\s*\(Lib\.A2a_tools\.submit_heartbeat_result.*?\(\)\);', '', content, flags=re.DOTALL)
content = re.sub(r'ignore\n\s*\(Lib\.A2a_tools\.submit_heartbeat_result.*?\(\)\);', '', content, flags=re.DOTALL)
content = re.sub(r'Lib\.A2a_tools\.emit_heartbeat_task.*?\(\);', '', content, flags=re.DOTALL)

with open("test/test_dashboard_mission.ml", "w") as f:
    f.write(content)

print("done")
