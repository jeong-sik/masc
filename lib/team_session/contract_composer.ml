let compose ~execution_scope
    ~(delivery_contract : Team_session_types.delivery_contract)
    ~(tool_names : string list) : Oas.Risk_contract.t =
  Cdal_contract_bridge.of_delivery_contract ~execution_scope ~delivery_contract
    ~tool_names
