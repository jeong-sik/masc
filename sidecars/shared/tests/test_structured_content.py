"""Tests for shared structured GateResponse content projections."""

from __future__ import annotations

from gate_shared import structured_plain_text


class TestStructuredPlainText:
    def test_projects_dashboard_block_shapes(self) -> None:
        text = structured_plain_text(
            {
                "blocks": [
                    {"t": "p", "html": "hello &lt;world&gt;"},
                    {
                        "t": "code",
                        "cap": "python",
                        "html": "print(&quot;fallback&quot;)",
                        "source": 'print("<ok>")',
                    },
                    {
                        "t": "image",
                        "src": "https://example.com/chart.png",
                        "cap": "Chart",
                    },
                    {
                        "t": "link",
                        "url": "https://example.com/post",
                        "title": "Post",
                        "meta": "example.com",
                    },
                    {"t": "fusion", "board_post_id": "p-123", "run_id": "fus-9"},
                ]
            }
        )

        assert "hello <world>" in text
        assert '```python\nprint("<ok>")\n```' in text
        assert "Image: Chart" in text
        assert "https://example.com/chart.png" in text
        assert "Post\nhttps://example.com/post\nexample.com" in text
        assert "Fusion result\nboard_post_id: p-123\nrun_id: fus-9" in text

    def test_ignores_malformed_blocks(self) -> None:
        assert structured_plain_text({"blocks": [{"t": "image"}]}) == ""

    def test_rejects_missing_blocks_array(self) -> None:
        assert structured_plain_text({"blocks": "bad"}) == ""
