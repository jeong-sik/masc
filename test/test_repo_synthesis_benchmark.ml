open Masc_mcp

let answers_path repo_root name =
  Filename.concat
    repo_root
    (Filename.concat "test/fixtures/repo_synthesis_benchmark" name)
;;

let () =
  let repo_root = Sys.getcwd () in
  let questions = Repo_synthesis_benchmark.load_question_set ~repo_root in
  let baseline_answers =
    Repo_synthesis_benchmark.load_answers_from_file
      (answers_path repo_root "baseline_answers.json")
  in
  let swarm_answers =
    Repo_synthesis_benchmark.load_answers_from_file
      (answers_path repo_root "swarm_answers.json")
  in
  let baseline =
    Repo_synthesis_benchmark.score_answers
      ~label:"baseline"
      ~questions
      ~answers:baseline_answers
  in
  let swarm =
    Repo_synthesis_benchmark.score_answers
      ~label:"swarm"
      ~questions
      ~answers:swarm_answers
  in
  let improved =
    swarm.composite_score > baseline.composite_score
    && swarm.claim_coverage > baseline.claim_coverage
    && swarm.evidence_precision > baseline.evidence_precision
    && swarm.unsupported_claim_penalty <= baseline.unsupported_claim_penalty
  in
  let summary =
    `Assoc
      [ ( "question_set_path"
        , `String (Repo_synthesis_benchmark.default_question_set_path ~repo_root) )
      ; "question_count", `Int (List.length questions)
      ; "baseline", Repo_synthesis_benchmark.score_summary_to_yojson baseline
      ; "swarm", Repo_synthesis_benchmark.score_summary_to_yojson swarm
      ; "swarm_beats_baseline", `Bool improved
      ]
  in
  Yojson.Safe.pretty_to_channel stdout summary;
  print_newline ();
  if not improved then exit 1
;;
