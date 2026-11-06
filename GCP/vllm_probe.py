"""Smoke-test and measure an OpenAI-compatible vLLM endpoint (stdlib only).

Checks, in order: ``GET /v1/models``, a non-streaming chat completion with a tool
definition (verifies ``tool_calls`` parsing), a streaming completion (time to first
token and decode tokens/s), and N concurrent streaming completions (aggregate
tokens/s). Prints a JSON summary to stdout.

Usage::

    python3 vllm_probe.py --base-url https://... --model Qwen3.8-27B \
        --bearer "$(gcloud auth print-identity-token)" --concurrency 4
"""

from __future__ import annotations

import argparse
import json
import logging
import statistics
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass

logger = logging.getLogger(__name__)

REQUEST_TIMEOUT_S = 900
TOOL_SPEC: list[dict] = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a file from the repository and return its contents.",
            "parameters": {
                "type": "object",
                "properties": {"path": {"type": "string", "description": "Repository-relative path"}},
                "required": ["path"],
            },
        },
    }
]


@dataclass
class StreamResult:
    """Timing for one streaming chat completion."""

    ttft_s: float
    total_s: float
    completion_tokens: int
    decode_tok_s: float
    finish_reason: str | None


class EndpointError(RuntimeError):
    """Raised when the endpoint returns a non-2xx response."""


def _request(base_url: str, path: str, bearer: str | None, body: dict | None = None) -> urllib.request.Request:
    headers = {"Content-Type": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    data = json.dumps(body).encode() if body is not None else None
    return urllib.request.Request(base_url.rstrip("/") + path, data=data, headers=headers, method="POST" if body else "GET")


def _call_json(base_url: str, path: str, bearer: str | None, body: dict | None = None) -> dict:
    req = _request(base_url, path, bearer, body)
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:  # pragma: no cover - network
        raise EndpointError(f"{path}: HTTP {exc.code}: {exc.read()[:500]!r}") from exc


def list_models(base_url: str, bearer: str | None) -> list[str]:
    """Return the model ids served by the endpoint."""
    payload = _call_json(base_url, "/v1/models", bearer)
    return [m["id"] for m in payload.get("data", [])]


def tool_call_check(base_url: str, model: str, bearer: str | None) -> dict:
    """Ask a question that requires the tool and report whether a parsed tool call came back."""
    body = {
        "model": model,
        "messages": [{"role": "user", "content": "Use the read_file tool to open README.md, then stop."}],
        "tools": TOOL_SPEC,
        "tool_choice": "auto",
        "max_tokens": 512,
        "temperature": 0.0,
    }
    started = time.perf_counter()
    payload = _call_json(base_url, "/v1/chat/completions", bearer, body)
    elapsed = time.perf_counter() - started
    message = payload["choices"][0]["message"]
    calls = message.get("tool_calls") or []
    return {
        "seconds": round(elapsed, 2),
        "tool_calls": [c["function"] for c in calls],
        "reasoning_present": bool(message.get("reasoning_content") or message.get("reasoning")),
        "finish_reason": payload["choices"][0].get("finish_reason"),
        "usage": payload.get("usage"),
    }


def stream_once(base_url: str, model: str, bearer: str | None, prompt: str, max_tokens: int) -> StreamResult:
    """Run one streaming completion and measure TTFT and decode rate."""
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = _request(base_url, "/v1/chat/completions", bearer, body)
    started = time.perf_counter()
    first_token_at: float | None = None
    completion_tokens = 0
    finish_reason: str | None = None
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
            for raw in resp:
                line = raw.decode().strip()
                if not line.startswith("data:") or line == "data: [DONE]":
                    continue
                chunk = json.loads(line[5:])
                if chunk.get("usage"):
                    completion_tokens = chunk["usage"].get("completion_tokens", completion_tokens)
                for choice in chunk.get("choices", []):
                    delta = choice.get("delta", {})
                    if first_token_at is None and (delta.get("content") or delta.get("reasoning_content")):
                        first_token_at = time.perf_counter()
                    if choice.get("finish_reason"):
                        finish_reason = choice["finish_reason"]
    except urllib.error.HTTPError as exc:  # pragma: no cover - network
        raise EndpointError(f"stream: HTTP {exc.code}: {exc.read()[:500]!r}") from exc
    ended = time.perf_counter()
    ttft = (first_token_at or ended) - started
    decode_window = max(ended - (first_token_at or started), 1e-6)
    return StreamResult(
        ttft_s=round(ttft, 3),
        total_s=round(ended - started, 2),
        completion_tokens=completion_tokens,
        decode_tok_s=round(completion_tokens / decode_window, 1),
        finish_reason=finish_reason,
    )


def concurrent_streams(base_url: str, model: str, bearer: str | None, n: int, max_tokens: int) -> dict:
    """Run ``n`` streaming completions at once and aggregate throughput."""
    prompt = "Write a detailed, well-commented Python implementation of an LRU cache with tests."
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=n) as pool:
        results = list(pool.map(lambda _: stream_once(base_url, model, bearer, prompt, max_tokens), range(n)))
    wall = time.perf_counter() - started
    total_tokens = sum(r.completion_tokens for r in results)
    return {
        "streams": n,
        "wall_s": round(wall, 2),
        "aggregate_tok_s": round(total_tokens / wall, 1),
        "ttft_s_median": round(statistics.median(r.ttft_s for r in results), 3),
        "per_stream_decode_tok_s_median": round(statistics.median(r.decode_tok_s for r in results), 1),
        "completion_tokens_total": total_tokens,
    }


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--bearer", default=None, help="Bearer token (Google ID token or VLLM_API_KEY)")
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--skip-concurrency", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)

    summary: dict = {"base_url": args.base_url, "model": args.model}
    logger.info("GET /v1/models")
    summary["models"] = list_models(args.base_url, args.bearer)
    logger.info("tool-call check")
    summary["tool_call"] = tool_call_check(args.base_url, args.model, args.bearer)
    logger.info("single stream")
    single = stream_once(
        args.base_url,
        args.model,
        args.bearer,
        "Explain how a Mamba/Gated DeltaNet layer differs from softmax attention, in about 300 words.",
        args.max_tokens,
    )
    summary["single_stream"] = asdict(single)
    if not args.skip_concurrency:
        logger.info("%d concurrent streams", args.concurrency)
        summary["concurrent"] = concurrent_streams(args.base_url, args.model, args.bearer, args.concurrency, args.max_tokens)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
