(* Speculative — Cycle 27 / Tier A11 (sequential simulator).
   See speculative.mli for design rationale and the Eio deferral. *)

type budget_policy = {
  time_cap_ms : int;
  tokens_cap : int option;
  branches_max : int;
}

let default_budget =
  { time_cap_ms = 30_000; tokens_cap = None; branches_max = 4 }

type 'a branch = unit -> ('a, string) result

type 'a selection = {
  winner_index : int option;
  attempted : int;
  errors : string list;
}
[@@warning "-69"]

let take_n n xs =
  let rec aux k = function
    | [] -> []
    | _ when k <= 0 -> []
    | x :: rest -> x :: aux (k - 1) rest
  in
  aux (max 0 n) xs

let execute ~(budget : budget_policy) (branches : 'a branch list) :
    ('a, string) Shared_types.Resilience_outcome.t * 'a selection =
  let limited = take_n budget.branches_max branches in
  match limited with
  | [] ->
      let outcome =
        Shared_types.Resilience_outcome.graceful
          ~reason:"no_branches"
          ~recovery_strategy:"Speculate"
          ~confidence:Shared_types.Confidence.zero
          ()
      in
      let selection =
        { winner_index = None; attempted = 0; errors = [] }
      in
      (outcome, selection)
  | _ ->
      let rec try_each idx errors_rev = function
        | [] ->
            let outcome =
              Shared_types.Resilience_outcome.graceful
                ~reason:"all_branches_failed"
                ~recovery_strategy:"Speculate"
                ~confidence:Shared_types.Confidence.zero
                ()
            in
            let selection =
              {
                winner_index = None;
                attempted = idx;
                errors = List.rev errors_rev;
              }
            in
            (outcome, selection)
        | f :: rest -> (
            match f () with
            | Ok value ->
                let outcome =
                  Shared_types.Resilience_outcome.full ~value
                    ~confidence:Shared_types.Confidence.one
                    ~artifacts:[]
                in
                let selection =
                  {
                    winner_index = Some idx;
                    attempted = idx + 1;
                    errors = List.rev errors_rev;
                  }
                in
                (outcome, selection)
            | Error e -> try_each (idx + 1) (e :: errors_rev) rest)
      in
      try_each 0 [] limited
