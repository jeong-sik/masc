open Keeper_memory_os_types

let recorded_at fact = Masc_domain.iso8601_of_unix_seconds fact.first_seen

(* A Board source is rendered as the ids the Board tools accept, so the model
   can open it; no prose is added here. *)
let basis_label fact =
  match fact.basis with
  | Observed Transcript -> "observed"
  | Observed (Board { post_id; comment_id = None }) ->
    Printf.sprintf "observed board=%s" (Board_types.Post_id.to_string post_id)
  | Observed (Board { post_id; comment_id = Some comment_id }) ->
    Printf.sprintf
      "observed board=%s comment=%s"
      (Board_types.Post_id.to_string post_id)
      (Board_types.Comment_id.to_string comment_id)
  | Derived _ -> "derived"
;;

let render_fact fact =
  Printf.sprintf
    "- [category=%s recorded=%s origin=%s basis=%s] %s"
    (category_to_string fact.category)
    (recorded_at fact)
    (origin_kind_to_string fact.origin.kind)
    (basis_label fact)
    fact.claim
;;

let render_facts facts =
  facts |> List.map render_fact |> String.concat "\n"
;;

let facts_payload_bytes ~ordinary_facts ~source_lines =
  List.map render_fact ordinary_facts @ source_lines
  |> String.concat "\n"
  |> String.length
;;

type facts_source_usage =
  | No_source_memory
  | Source_memory of { bytes : int }

type facts_budget =
  { maximum_bytes : int
  ; ordinary_bytes : int
  ; source : facts_source_usage
  ; total_bytes : int
  }

let measure_facts_budget ~maximum_bytes ~ordinary_facts ~source_lines =
  { maximum_bytes
  ; ordinary_bytes = facts_payload_bytes ~ordinary_facts ~source_lines:[]
  ; source =
      (match source_lines with
       | [] -> No_source_memory
       | _ :: _ ->
         Source_memory { bytes = facts_payload_bytes ~ordinary_facts:[] ~source_lines })
  ; total_bytes = facts_payload_bytes ~ordinary_facts ~source_lines
  }
;;

let facts_budget_fits budget = budget.total_bytes <= budget.maximum_bytes

let hard_backstop_multiplier = 4

let hard_backstop_bytes ~maximum_bytes =
  if maximum_bytes <= 0
  then 0
  else if maximum_bytes > max_int / hard_backstop_multiplier
  then max_int
  else maximum_bytes * hard_backstop_multiplier
;;

type molt_receiver_unavailable_reason =
  | Receiver_uninstalled
  | Receiver_stopped

type facts_budget_outcome =
  | Within_threshold of facts_budget
  | Molt_recommended of facts_budget
  | Backstop_exceeded of
      { budget : facts_budget
      ; hard_limit_bytes : int
      ; reason : molt_receiver_unavailable_reason
      }

let receiver_unavailable_label = function
  | Receiver_uninstalled -> "uninstalled"
  | Receiver_stopped -> "stopped"
;;

let backstop_rejection_message ~budget ~hard_limit_bytes ~reason =
  Printf.sprintf
    "memory os emergency backstop exceeded: payload=%d bytes exceeds hard_backstop=%d bytes \
     (%dx soft threshold=%d bytes) while Librarian molt receiver is %s; resume/install \
     Librarian or retract facts before growing further"
    budget.total_bytes
    hard_limit_bytes
    hard_backstop_multiplier
    budget.maximum_bytes
    (receiver_unavailable_label reason)
;;

let on_molt_requested
    : (keeper_id:string -> facts_budget -> unit) option Atomic.t
  =
  Atomic.make None
;;

let is_molt_receiver_stopped : (keeper_id:string -> bool) option Atomic.t =
  Atomic.make None
;;

let set_on_molt_requested cb = Atomic.set on_molt_requested cb
let set_is_molt_receiver_stopped cb = Atomic.set is_molt_receiver_stopped cb

let evaluate_facts_budget ~keeper_id ~previous_bytes ~ordinary_facts ~source_lines =
  let budget =
    measure_facts_budget
      ~maximum_bytes:(Env_config.KeeperMemoryOs.facts_max_bytes ())
      ~ordinary_facts
      ~source_lines
  in
  if facts_budget_fits budget || budget.total_bytes <= previous_bytes
  then Within_threshold budget
  else (
    let unavailable_reason =
      match Atomic.get on_molt_requested with
      | None -> Some Receiver_uninstalled
      | Some _ ->
        (match Atomic.get is_molt_receiver_stopped with
         | Some check when check ~keeper_id -> Some Receiver_stopped
         | Some _ | None -> None)
    in
    match unavailable_reason with
    | None -> Molt_recommended budget
    | Some reason ->
      let hard_limit_bytes = hard_backstop_bytes ~maximum_bytes:budget.maximum_bytes in
      if budget.total_bytes > hard_limit_bytes
      then (
        Log.Keeper.warn
          ~keeper_name:keeper_id
          "%s"
          (backstop_rejection_message ~budget ~hard_limit_bytes ~reason);
        Backstop_exceeded { budget; hard_limit_bytes; reason })
      else Molt_recommended budget)
;;

let notify_molt_if_recommended ~keeper_id = function
  | Within_threshold _ | Backstop_exceeded _ -> ()
  | Molt_recommended budget ->
    (match Atomic.get on_molt_requested with
     | None ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "memory os structural molt recommended (payload=%d bytes threshold=%d bytes) \
          but molt receiver is uninstalled; emergency hard backstop enforced at %d bytes"
         budget.total_bytes
         budget.maximum_bytes
         (hard_backstop_bytes ~maximum_bytes:budget.maximum_bytes)
     | Some cb ->
       (try cb ~keeper_id budget with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Log.Keeper.warn
            ~keeper_name:keeper_id
            "memory os structural molt notification failed: %s"
            (Printexc.to_string exn)))
;;
