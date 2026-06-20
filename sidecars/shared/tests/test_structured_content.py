"""Tests for shared structured GateResponse content projections."""

from __future__ import annotations

from gate_shared import GateResponse, response_text, structured_plain_text


class TestStructuredPlainText:
    def test_projects_dashboard_block_shapes(self) -> None:
        text = structured_plain_text(
            {
                "blocks": [
                    {"t": "p", "html": "hello &lt;world&gt;"},
                    {"t": "h4", "html": "Plan"},
                    {"t": "ul", "items": ["one", "two"]},
                    {"t": "callout", "severity": "warn", "html": "careful"},
                    {
                        "t": "table",
                        "head": ["name", {"v": "count", "num": True}],
                        "rows": [["alpha", "2"]],
                    },
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
                    {"t": "mermaid", "source": "graph TD\nA-->B", "caption": "Flow"},
                    {"t": "svg", "svg": "<svg><path /></svg>", "cap": "Icon"},
                    {
                        "t": "link",
                        "url": "https://example.com/post",
                        "title": "Post",
                        "meta": "example.com",
                    },
                    {
                        "t": "voice",
                        "src": "https://example.com/a.mp3",
                        "transcript": "spoken memo",
                        "via": "tts",
                    },
                    {
                        "t": "attach",
                        "name": "clip.mp4",
                        "src": "https://example.com/clip.mp4",
                        "kind": "video",
                    },
                    {
                        "t": "video",
                        "src": "https://example.com/demo.mp4",
                        "cap": "Demo",
                    },
                    {"t": "fusion", "board_post_id": "p-123", "run_id": "fus-9"},
                ]
            }
        )

        assert "hello <world>" in text
        assert "## Plan" in text
        assert "- one\n- two" in text
        assert "Callout (warn): careful" in text
        assert "name | count\nalpha | 2" in text
        assert '```python\nprint("<ok>")\n```' in text
        assert "Image: Chart" in text
        assert "https://example.com/chart.png" in text
        assert "```mermaid\ngraph TD\nA-->B\n```" in text
        assert "```svg\n<svg><path /></svg>\n```" in text
        assert "Post\nhttps://example.com/post\nexample.com" in text
        assert "Audio (tts)\nspoken memo\nhttps://example.com/a.mp3" in text
        assert "Attachment (video): clip.mp4\nhttps://example.com/clip.mp4" in text
        assert "Video: Demo\nhttps://example.com/demo.mp4" in text
        assert "Fusion result\nboard_post_id: p-123\nrun_id: fus-9" in text

    def test_ignores_malformed_blocks(self) -> None:
        assert structured_plain_text({"blocks": [{"t": "image"}]}) == ""

    def test_rejects_missing_blocks_array(self) -> None:
        assert structured_plain_text({"blocks": "bad"}) == ""


class TestResponseText:
    def test_prefers_structured_text_when_reply_is_empty(self) -> None:
        response = GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured={"blocks": [{"t": "p", "html": "approved"}]},
        )

        assert response_text(response) == "approved"

    def test_falls_back_to_reply_without_structured_text(self) -> None:
        response = GateResponse(
            ok=True,
            keeper_name="sangsu",
            reply="plain reply",
            model_used="",
            duration_ms=0,
            tokens_used=0,
            error="",
            structured=None,
        )

        assert response_text(response) == "plain reply"
