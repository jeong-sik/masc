module Candidate = Keeper_board_attention_candidate
module Partition = Keeper_board_attention_partition

type inconsistency =
  | Ready_without_requeue_request
  | Ready_before_requeue_recorded
  | Ready_not_after_requeued_generation

type t =
  | Blocked_awaiting_request
  | Blocked_requeue_requested
  | Blocked_requeued
  | Blocked_unrecorded
  | Ready_requeued
  | Advanced_requeued
  | Advanced_without_requeue
  | Other_partition
  | Inconsistent of inconsistency

let classify (partition : Partition.t) (state : Candidate.quarantine_state) =
  let names_partition =
    String.equal state.quarantine.partition_id partition.partition_id
  in
  let at_quarantine =
    names_partition
    && Partition.Generation.equal
         state.quarantine.partition_generation
         partition.generation
  in
  let after_quarantine =
    Partition.Generation.is_later
      ~previous:state.quarantine.partition_generation
      partition.generation
  in
  match partition.state, state.phase with
  | Partition.Blocked _, Candidate.Quarantined when at_quarantine ->
    Blocked_awaiting_request
  | Partition.Blocked _, Candidate.Requeue_requested _ when at_quarantine ->
    Blocked_requeue_requested
  | Partition.Blocked _, Candidate.Requeued _ when at_quarantine ->
    Blocked_requeued
  | ( Partition.Blocked _
    , (Candidate.Quarantined | Candidate.Requeue_requested _ | Candidate.Requeued _)
    ) -> Blocked_unrecorded
  | ( ( Partition.Ready
      | Partition.Running _
      | Partition.Completed _
      | Partition.Settled _
      | Partition.Abandoned _ )
    , (Candidate.Quarantined | Candidate.Requeue_requested _ | Candidate.Requeued _)
    )
    when not names_partition -> Other_partition
  | Partition.Ready, Candidate.Requeued _ when after_quarantine -> Ready_requeued
  | Partition.Ready, Candidate.Requeued _ ->
    Inconsistent Ready_not_after_requeued_generation
  | Partition.Ready, Candidate.Quarantined ->
    Inconsistent Ready_without_requeue_request
  | Partition.Ready, Candidate.Requeue_requested _ ->
    Inconsistent Ready_before_requeue_recorded
  | ( ( Partition.Running _
      | Partition.Completed _
      | Partition.Settled _
      | Partition.Abandoned _ )
    , Candidate.Requeued _ ) -> Advanced_requeued
  | ( ( Partition.Running _
      | Partition.Completed _
      | Partition.Settled _
      | Partition.Abandoned _ )
    , (Candidate.Quarantined | Candidate.Requeue_requested _) ) ->
    Advanced_without_requeue
;;

let inconsistency_to_string = function
  | Ready_without_requeue_request ->
    "Ready partition has an unacknowledged quarantine"
  | Ready_before_requeue_recorded ->
    "Ready partition preceded candidate requeue authorization"
  | Ready_not_after_requeued_generation ->
    "Ready partition is not after the requeued quarantine generation"
;;
