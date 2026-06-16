open Masc_memory_types

type t = {
  outbox : Masc_memory_outbox.t;
  recall : Masc_memory_recall.t;
  env_fs : Eio.Fs.dir Eio.Path.t;
}

let create ~outbox ~recall ~env_fs =
  { outbox; recall; env_fs }

let generate_consolidation_proposals t ~llm_client =
  try
    (* 1. 모호한 유사도 구간의 메모리 쌍 스캔 및 LLM Judge 호출 가정 *)
    let mock_confidence = 0.96 in (* 0.95 초과로 Auto-Approve 됨 *)
    let proposal = {
      proposal_id = "prop_999";
      created_at = Unix.gettimeofday ();
      action = Proposal_merge {
        target_ids = ["mem_1"; "mem_2"];
        merged_text = "통합 테스트 시 DB 모킹 금지 (Why: 과거 배포 마이그레이션 장애 재발 방지)";
      };
      rationale = "동일 지침에 대한 단순 표현 중복";
      approved = mock_confidence >= 0.95; (* Auto-Approve 적용 *)
    } in
    
    (* 2. 신뢰도가 낮은 것은 Deletion/Merge 제안서(Proposal Draft) 마크다운으로 Proposals 폴더에 보존 *)
    if not proposal.approved then (
      let file_path = Eio.Path.(t.env_fs / "proposals" / Printf.sprintf "proposal_%s.md" proposal.proposal_id) in
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
  (* 승인된 제안을 읽어 outbox 큐에 인큐 *)
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
