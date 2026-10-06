const laneIds = ['board_attention_exact','hitl_auto_judge','librarian_exact','verifier_exact','workspace_curator_exact','browser_stagehand_exact','candle_appraiser']
const lanes = { schema: 'masc.standalone_llm_lanes.v2', generated_at:'2026-10-04T00:00:00Z', observed_at_unix:20,
  observation_only:true, exact_run_projection_count:0, exact_run_source_total:0, exact_run_projection_truncated:false,
  lanes:laneIds.map(lane_id=>({lane_id,label:lane_id,purpose:lane_id,required:false,observation_only:true,configured:true,
    configuration_state:'ready',admitted_slots:[],cli_slots:[],dropped_slots:[],declared_slots:[],declared_cli_slots:[],admission_error:null,
    status:'no_retained_observation',retained_run_count:0,running_count:0,succeeded_count:0,failed_count:0,cancelled_count:0,
    last_started_at:null,last_terminal_at:null,last_outcome:null,p50_elapsed_s:null,selected_slots:[],
    ...(lane_id==='board_attention_exact'?{jev:{state:'off'}}:{})})) }
export { lanes }
