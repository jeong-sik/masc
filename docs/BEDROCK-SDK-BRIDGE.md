# AWS Bedrock SDK transport

`scripts/bedrock-sdk.py` accepts one JSON object on stdin and writes JSON-lines responses. It requires the official `boto3` Python package. Boto3 owns profile/SSO/role credentials, signing, token refresh and AWS EventStream decoding. The bridge never accepts access keys or endpoint overrides in its input and does not change AWS configuration.

Input fields are `protocol: "masc.bedrock-sdk.v1"`, `operation`, optional `profile`/`region`, and `request` containing native AWS operation arguments. Supported operations:

- `profiles`: local SDK profile and region choices, no cloud request.
- `models`: current text foundation models and all inference-profile pages.
- `availability`: `modelId`; returns distinct authorization, entitlement, region and agreement status. It does not claim response/tool verification.
- `converse`: native Converse arguments and response.
- `converse_stream`: native Converse arguments; each SDK stream event is emitted immediately. Clean closure requires a messageStop event; truncated streams fail. Native model stop reasons remain in their original event for the OCaml codec to validate.

Ordinary results use `event: "response"`; streaming uses `event: "stream"` and a final `event: "stream_closed"`. A safe failure uses `event: "error"` and a fixed code, exiting 2. AWS exception messages and transport metadata are not printed. Tool use/result bodies retain the native AWS shape.

This bridge is a transport dependency. The native MASC codec/runtime adapter, distribution packaging and actual account/imp verification are separate required integration work. Presence of this script is not Bedrock readiness.

Official interfaces: [Converse](https://docs.aws.amazon.com/boto3/latest/reference/services/bedrock-runtime/client/converse.html), [ConverseStream](https://docs.aws.amazon.com/boto3/latest/reference/services/bedrock-runtime/client/converse_stream.html), [model availability](https://docs.aws.amazon.com/boto3/latest/reference/services/bedrock/client/get_foundation_model_availability.html). The AWS CLI cannot perform ConverseStream, which is why the bridge uses the SDK.
