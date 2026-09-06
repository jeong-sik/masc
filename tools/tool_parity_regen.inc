(* Rule: regenerate tool definition parity artifacts
   
   Invoked manually: dune build @regen_tool_parity_artifacts
   Invoked by CI gate: CI script checks if outputs match committed baselines,
                       fails with instruction to run this rule if mismatch found.
   
   Targets: test/golden/tool_parity_*.txt (4 files)
   Generator: bin/tool_parity_generator.exe
*)

(rule
  (targets 
    ../test/golden/tool_parity_description.txt
    ../test/golden/tool_parity_params.txt
    ../test/golden/tool_parity_visibility.txt
    ../test/golden/tool_parity_availability.txt)
  (action 
    (chdir %{workspace_root}
      (run %{exe:../bin/tool_parity_generator.exe}))))

(alias
  (name regen_tool_parity_artifacts)
  (action (chdir %{workspace_root}
            (run %{exe:../bin/tool_parity_generator.exe}))))
