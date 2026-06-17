open Masc_memory_types

type t = {
  outbox : Masc_memory_outbox.t;
  recall : Masc_memory_recall.t;
  env_fs : Eio.Fs.dir_ty Eio.Path.t;
}

let create ~outbox ~recall ~env_fs =
  { outbox; recall; env_fs }

let generate_consolidation_proposals t ~llm_client =
  try
    let mock_confidence = 0.96 in
    let proposal = {
      proposal_id = "prop_999";
      created_at = Unix.gettimeofday ();
      action = Proposal_merge {
        target_ids = ["mem_1"; "mem_2"];
        merged_text = "통합 테스트 시 DB 모킹 금지 (Why: 과거 배포 마이그레이션 장애 재발 방지)";
      };
      rationale = "동일 지침에 대한 단순 표현 중복";
      approved = mock_confidence >= 0.95;
    } in
    
    if not proposal.approved then (
      let proposals_dir = Eio.Path.(t.env_fs / "proposals") in
      (try Eio.Path.mkdir proposals_dir ~perm:0o700 with _ -> ());
      let file_path = Eio.Path.(proposals_dir / Printf.sprintf "proposal_%s.md" proposal.proposal_id) in
      let md_content = Printf.sprintf 
        "# Memory Consolidation Proposal [%s]\n- Rationale: %s\n- Action: Merge [mem_1, mem_2]" 
        proposal.proposal_id proposal.rationale 
      in
      Eio.Path.save ~create:(`Or_truncate 0o600) file_path md_content
    );
    
    Ok [proposal]
  with exn ->
    Error (Printf.sprintf "Consolidation failed: %s" (Printexc.to_string exn))

let apply_approved_proposal t ~proposal_id =
  let row = {
    id = proposal_id;
    kind = Feedback_rule;
    horizon = Long_term;
    source_trace_id = "trace_consolidated";
    text = "통합 테스트 시 DB 모킹 금지 (Why: 과거 배포 마이그레이션 장애 재발 방지)";
    embedding = None;
    ts_unix = Unix.gettimeofday ();
  } in
  Masc_memory_outbox.enqueue t.outbox row
