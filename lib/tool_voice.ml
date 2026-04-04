open Types

type 'a context = {
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

let schemas : tool_schema list = []

let dispatch (_ctx : 'a context) ~name:_ ~args:_ : (bool * string) option = None
