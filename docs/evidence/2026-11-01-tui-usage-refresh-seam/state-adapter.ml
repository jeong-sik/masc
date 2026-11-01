type surface = Metrics | Overview
type usage_section = Usage_plan | Usage_trend | Usage_keepers
type provider_history = Provider_history_unread | Provider_history_read of int
type currency_authority = {car_generation:int;car_identity:Tui_decode.server_identity option}
type state = {
  mutable view:surface; mutable usage_telemetry_open:bool;
  mutable usage_section:usage_section; mutable provider_history_days:int;
  mutable provider_history:provider_history; mutable metrics_scroll:int;
  mutable usage_scope_id:string option; mutable workspace_authority:int;
  mutable http_refresh_order:Http_refresh_order.ticket;
  mutable http_surface_reads:Surface_read_order.t;
  candle_authority_generation:int; server_identity:Tui_decode.server_identity option;
  system_logs:unit; msg_scroll:int; msg_target_keeper_name:string option;
  credential_preparation:unit;local_base_path:string;port:int;
  mutable applied:int;mutable failed:int
}
let identity = Tui_decode.{sid_base_path="/workspace";sid_masc_root="/workspace/.masc";sid_state_ready=Some true}
let create () = {view=Metrics;usage_telemetry_open=false;usage_section=Usage_plan;
  provider_history_days=14;provider_history=Provider_history_read 14;metrics_scroll=5;
  usage_scope_id=Some "selected-account";workspace_authority=1;
  http_refresh_order=Http_refresh_order.initial;http_surface_reads=Surface_read_order.initial;
  candle_authority_generation=1;server_identity=Some identity;system_logs=();msg_scroll=0;
  msg_target_keeper_name=None;credential_preparation=();local_base_path="/workspace";port=8940;
  applied=0;failed=0}
let begin_asks_read _ = Some ()
let begin_keeper_roster_read _ = Some ()
let finish_http_surface_read state request =
  state.http_surface_reads <- Surface_read_order.finish state.http_surface_reads request
module Surface_read_context = struct
  type t = Surface_read_order.request
  let capture ~needs:_ ~board_query:_ request = request
end
