"""Regenerate the retained fixture output and HTML from the actual report worker."""
import html
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

repo = Path(__file__).resolve().parents[1]
evidence_path = repo / "docs/evidence/fusion-report-20260930/composition.json"
preview_path = repo / "docs/design/fusion-report-preview.html"
capture = json.loads(evidence_path.read_text())
detail = capture["capture"]
detail_bytes = json.dumps(detail, ensure_ascii=False, separators=(",", ":")).encode()
detail_digest = hashlib.sha256(detail_bytes).hexdigest()
source = {"source_id": "fusion", "incarnation": detail["run"]["run_id"],
          "cursor": detail_digest, "complete": True, "detail": "Synthetic exact-run capture for stdio composition",
          "observations": [{"id": detail_digest, "kind": "fusion_run", "observed_at": 120,
                            "actor": None, "evidence": [{"uri": "lane-evidence:" + detail_digest,
                                                          "sha256": detail_digest}], "detail": detail}]}
project_request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
    "name": "lane_observe", "arguments": {"binding": {"sources": []}, "sources": [source]}}}
projected = subprocess.run([sys.executable, str(repo / "addons/fusion-results/server.py")],
                          input=json.dumps(project_request, ensure_ascii=False) + "\n",
                          text=True, capture_output=True, check=True)
if projected.stderr:
    raise RuntimeError(projected.stderr)
projected_response = json.loads(projected.stdout)["result"]
if projected_response["isError"]:
    raise RuntimeError(projected_response["content"])
output = projected_response["structuredContent"]
producer = capture["report_input"]["observations"][0]["producer"]
producer.update(output_id=None, output_selection={"all_lanes": True}, coverage_scope="whole_producer")
instance, sequence = producer["instance_id"], producer["observation_seq"]
for item in output["rows"]:
    item["id"] = f"{instance}/{sequence}/" + item["id"]
    item["lane_id"] = instance + "/" + item["lane_id"]
    item["related_ids"] = [f"{instance}/{sequence}/" + identity for identity in item["related_ids"]]
output_bytes = json.dumps({"producer": producer, "output": output},
                         ensure_ascii=False, separators=(",", ":")).encode()
output_digest = hashlib.sha256(output_bytes).hexdigest()
capture["report_input"]["observations"][0].update(
    producer=producer, output=output,
    evidence=[{"uri": "lane-evidence:" + output_digest, "sha256": output_digest}])
request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
    "name": "lane_observe", "arguments": {"binding": {"sources": []},
                                           "sources": [capture["report_input"]]}}}
result = subprocess.run([sys.executable, str(repo / "addons/fusion-report/server.py")],
                        input=json.dumps(request, ensure_ascii=False) + "\n",
                        text=True, capture_output=True, check=True)
if result.stderr:
    raise RuntimeError(result.stderr)
response = json.loads(result.stdout)["result"]
if response["isError"]:
    raise RuntimeError(response["content"])
capture["report_output"] = response["structuredContent"]
report = next(item for item in capture["report_output"]["rows"] if item["lane_id"] == "fusion/report")
context = next(item for item in capture["report_output"]["rows"] if item["id"] in report["related_ids"])
fields = report["fields"]
document = preview_path.read_text()
blocks = [
    ("report-body", html.escape(fields["body"])),
    ("report-lineage", html.escape(json.dumps({
        "producer": context["fields"]["producer"], "upstream_rows": context["fields"]["upstream_rows"],
        "upstream_output_evidence": context["evidence"]},
        ensure_ascii=False, indent=2))),
]
for index, (identity, content) in enumerate(blocks):
    pattern = r'<pre id="' + identity + r'">.*?</pre>'
    replacement = f'<pre id="{identity}">{content}</pre>'
    if re.search(pattern, document, flags=re.S):
        document = re.sub(pattern, lambda _match: replacement, document, count=1, flags=re.S)
    else:
        matches = list(re.finditer(r'<pre(?: [^>]*)?>.*?</pre>', document, flags=re.S))
        match = matches[index]
        document = document[:match.start()] + replacement + document[match.end():]
delivery = '<p id="delivery-state" class="note">' + html.escape(fields["delivery_label"]) + '</p>'
if 'id="delivery-state"' in document:
    document = re.sub(r'<p id="delivery-state".*?</p>', lambda _match: delivery, document, count=1, flags=re.S)
else:
    document = document.replace('</pre><details>', '</pre>' + delivery + '<details>', 1)
evidence_path.write_text(json.dumps(capture, ensure_ascii=False, indent=2) + "\n")
preview_path.write_text(document)
print("Regenerated fixture composition and report preview from the final stdio worker")
