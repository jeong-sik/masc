#!/usr/bin/env python3
import io
import json
import math
import sys
import unittest
from contextlib import redirect_stderr

import wake_payload_stats as stats


def valid_record():
    return json.loads(
        '{"record_type":"wake_payload","timestamp":1.5,"keeper_name":"k","trace_id":"t","turn_index":1,"context_window":4096,"system_prompt_bytes":3,"tool_schema_json_bytes":4,"message_content_bytes":5,"message_count":2,"tool_count":1,"role_counts":{"user":1,"assistant":1},"has_compact_happened":false}'
    )


class WakePayloadStatsTest(unittest.TestCase):
    def parse(self, records):
        previous, warnings = sys.stdin, io.StringIO()
        try:
            sys.stdin = io.StringIO("".join(json.dumps(r) + "\n" for r in records))
            with redirect_stderr(warnings):
                parsed = list(stats.iter_records(["-"]))
        finally:
            sys.stdin = previous
        return parsed, warnings.getvalue()

    def test_invalid_exact_records_are_warned_and_skipped(self):
        valid = valid_record()
        legacy = {**valid, "tool_defs_bytes": 4, "messages_bytes": 5}
        legacy.pop("tool_schema_json_bytes")
        legacy.pop("message_content_bytes")
        invalid = [
            legacy,
            {**valid, "system_prompt_bytes": "3"},
            {**valid, "tool_count": True},
            {**valid, "tool_count": -1},
            {**valid, "role_counts": {"user": 1}},
            {**valid, "timestamp": math.nan},
            {**valid, "record_type": "other"},
        ]
        parsed, warnings = self.parse([valid, *invalid])
        self.assertEqual([valid], parsed)
        for expected in (
            "tool_schema_json_bytes",
            "must be an integer",
            "non-negative",
            "does not equal",
            "finite",
            "unexpected record_type",
        ):
            self.assertIn(expected, warnings)


if __name__ == "__main__":
    unittest.main()
