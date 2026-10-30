export function resolution(name) {
 const path={path:`/fixture/${name}`,exists:true,source:'workspace'}
 return {status:'ready',warnings:[],base_path:path,workspace_path:path,resolved_base_path:path,data_root:path,prompt_markdown_dir:path,
 source_mismatch:false,server_workspace_mismatch:false,diagnostics:[],build:{release_version:'dev',started_at:'2026-10-04T00:00:00Z',uptime_seconds:1},
 keeper_runtime:null,fleet_safety:null,fd_accountant:null}
}
export function catalog(name) {return {providers:[
 {provider:'shared.model',runtime_id:'shared.model',provider_id:'shared',provider_display_name:`Account ${name}`,protocol:'claude-code',available:true,models:['model']},
 {provider:'http.model',runtime_id:'http.model',provider_id:'http',protocol:'openai-compatible-http',available:true,models:['model'],note:`workspace-${name}-spec`},
]}}
export function metrics(name) {return {window_minutes:60,models:[{model_id:`Only-${name}-metric`,success_count:1,error_count:0,
 total_input_tokens:123,total_output_tokens:12,p50_latency_ms:5,p95_latency_ms:8,usage_sample_count:1,usage_missing_count:0,telemetry_sample_count:1,telemetry_missing_count:0}]}}
export function usage(percent) {return {config_path:null,default_runtime:null,runtimes:[],lanes:[],assignments:[],
 provider_usage_windows:[{scope:'account:shared',providers:[{id:'shared',display_name:'shared'}],state:'reported',windows:[
 {window:{kind:'five_hour'},utilization:{unit:'percent',value:percent},resets_at:null,observed_at:1,limit_id:null,source:'fixture',role:'gates_model_calls'}]}]}}
export function probe(name) {return {generated_at:'2026-10-04T00:00:00Z',refreshed_at_unix:1,cache_ttl_sec:30,cache_hit:false,cache_age_sec:0,refresh_state:'fresh',
 probe:{source:'runtime.toml',status:'ok',checked_at:'2026-10-04T00:00:00Z',probe_ok:true,
 summary:{runtimes:1,probed:1,reachable:1,failed:0,skipped:0,default_runtime_id:'http.model'},providers:[{
 runtime_id:'http.model',provider_id:'http',provider_display_name:'HTTP fixture',model_id:'model',model_api_name:'model',protocol:'openai-compatible-http',runtime_kind:'http',transport:'http',
 auth_kind:'none',credential_required:false,auth_present:false,status:'reachable',reachable:true,http_status:200,latency_ms:5,model_count:1,content_type:'application/json',downloaded_bytes:128,
 endpoint_url:`https://${name.toLowerCase()}.example.invalid`,probe_url:`https://${name.toLowerCase()}.example.invalid/models`,error:null,checked_at:'2026-10-04T00:00:00Z'}],
 observations:[`workspace-${name}-probe`],errors:[],limitations:['Synthetic metadata-only response; no model execution.']}}}
export function login(name) {return {schema:'masc.dashboard.official-client-probe.v1',ok:true,runtime_id:'shared.model',client_kind:'claude_code',configured_model:'model',measured_at:1,
 login:{status:'ready',authenticated:true,evidence_source:'configured_executable_self_report',identity_verified:false,auth_method:'claude.ai',subscription_type:'max',api_provider:'firstParty',detail:`Only-${name}-login`},
 client:{user_agent:null},execution:{status:'not_measured',reason:'login_probe_does_not_submit_model_turn'}}}
