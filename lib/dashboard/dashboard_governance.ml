(** Dashboard Governance — council module removed, stubs only. *)

type detail_status = [ `OK | `Not_found ]

let _option_to_yojson = Json_util.option_to_yojson
let _iso_of_unix = Dashboard_utils.iso_of_unix

let factual_snapshot_json ~base_path:_ =
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("items", `List []);
      ("activity", `List []);
      ("note", `String "Council module removed. Governance cases are no longer tracked.");
    ]

let dashboard_json ~base_path:_ ~limit:_ ~offset:_ ~status_filter:_ =
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("summary",
        `Assoc
          [
            ("cases_open", `Int 0);
            ("pending_ruling", `Int 0);
            ("ready_auto_execute", `Int 0);
            ("needs_human_gate", `Int 0);
            ("executed", `Int 0);
            ("blocked", `Int 0);
            ("ready_to_execute", `Int 0);
            ("oldest_open_case_age_s", `Null);
            ("last_activity_age_s", `Null);
            ("judge_online", `Bool false);
            ("judge_last_seen_at", `Null);
          ]);
      ("items", `List []);
      ("activity", `List []);
      ("judge", `Assoc [
        ("judge_online", `Bool false);
        ("refreshing", `Bool false);
        ("generated_at", `Null);
        ("expires_at", `Null);
        ("model_used", `Null);
        ("keeper_name", `String Dashboard_governance_judge.keeper_name);
        ("last_error", `Null);
      ]);
      ("judgments", `List []);
      ("pending_actions", `List []);
      ("cases", `List []);
    ]

let cases_json ~base_path:_ ~limit ~offset ~status_filter:_ ~include_test:_ =
  ignore (limit, offset);
  `Assoc
    [
      ("cases", `List []);
      ("count", `Int 0);
      ("limit", `Int limit);
      ("offset", `Int offset);
    ]

let case_detail_json ~base_path:_ ~case_id =
  ignore case_id;
  (`Not_found, `Assoc [ ("error", `String "Council module removed") ])
