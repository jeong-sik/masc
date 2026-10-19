val handle : base_path:string -> author:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t

module For_testing : sig
  val handle_with_manifest :
    persist_manifest:(base_path:string -> Tool_result.result ->
      (Tool_result.result, Tool_bridge.externalization_error) result) ->
    base_path:string -> author:string -> args:Yojson.Safe.t -> Keeper_tool_execution.t
  (** Exercise receipt persistence failure after the real publication commits. *)
end
