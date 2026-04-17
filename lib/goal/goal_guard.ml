type budget = {
  max_depth : int;
  parallel_children : int;
  parallel_grandchildren : int;
  fanout_short : int;
  fanout_mid : int;
  fanout_long : int;
  require_approval : bool;
}

let int_env name ~default ~min_v ~max_v =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      try
        let parsed = int_of_string (String.trim raw) in
        max min_v (min max_v parsed)
      with Failure _ -> default)

let bool_env name ~default = Env_config_core.get_bool ~default name

let load_budget () =
  {
    max_depth = int_env "MASC_GOAL_MAX_DEPTH" ~default:2 ~min_v:1 ~max_v:3;
    parallel_children =
      int_env "MASC_GOAL_PARALLEL_CHILDREN" ~default:12 ~min_v:1 ~max_v:128;
    parallel_grandchildren =
      int_env "MASC_GOAL_PARALLEL_GRANDCHILDREN" ~default:24 ~min_v:1 ~max_v:256;
    fanout_short = int_env "MASC_GOAL_FANOUT_SHORT" ~default:6 ~min_v:1 ~max_v:64;
    fanout_mid = int_env "MASC_GOAL_FANOUT_MID" ~default:4 ~min_v:1 ~max_v:64;
    fanout_long = int_env "MASC_GOAL_FANOUT_LONG" ~default:2 ~min_v:1 ~max_v:64;
    require_approval = bool_env "MASC_GOAL_REQUIRE_APPROVAL" ~default:true;
  }

let clamp_depth t requested =
  max 1 (min t.max_depth requested)

let approval_required t ~execute ~approved =
  execute && t.require_approval && (not approved)
