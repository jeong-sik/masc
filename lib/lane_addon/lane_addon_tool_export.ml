type t = { instance_id : string; tool : Mcp_protocol.Mcp_types.tool }

let create ~instance_id ~tool = { instance_id; tool }
