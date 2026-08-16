"""
title: HolmesGPT
description: Kubernetes investigation agent backed directly by HolmesGPT
author: mini-platform
version: 0.1.0
"""

import json
import os
from typing import Any, AsyncGenerator, Awaitable, Callable, Optional

import aiohttp


class Pipe:
    def __init__(self):
        self.name = "HolmesGPT"
        self.url = os.getenv(
            "HOLMES_URL",
            "http://holmes-holmes.mini-platform.svc.cluster.local/api/chat",
        )
        self.api_key = os.getenv("HOLMES_API_KEY", "")
        self.timeout = float(os.getenv("HOLMES_REQUEST_TIMEOUT_SECONDS", "900"))

    @staticmethod
    def _text(content: Any) -> str:
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\n".join(
                part.get("text", "")
                for part in content
                if isinstance(part, dict) and part.get("type") == "text"
            )
        return str(content or "")

    def _payload(self, body: dict, metadata: Optional[dict]) -> dict:
        messages = body.get("messages") or []
        user_indexes = [
            index for index, message in enumerate(messages)
            if message.get("role") == "user"
        ]
        if not user_indexes:
            raise ValueError("HolmesGPT requires a user message")

        current_index = user_indexes[-1]
        ask = self._text(messages[current_index].get("content")).strip()
        history = [
            {"role": "system", "content": "Conversation from Open WebUI."}
        ]
        history.extend(
            {
                "role": message["role"],
                "content": self._text(message.get("content")),
            }
            for message in messages[:current_index]
            if message.get("role") in {"user", "assistant"}
            and self._text(message.get("content")).strip()
        )

        metadata = metadata or body.get("metadata") or {}
        conversation_id = metadata.get("chat_id") or body.get("chat_id")
        payload = {
            "ask": ask,
            "stream": True,
            "request_source": "open-webui-pipe",
        }
        if len(history) > 1:
            payload["conversation_history"] = history
        if conversation_id:
            payload["conversation_id"] = str(conversation_id)
        return payload

    @staticmethod
    async def _status(
        emitter: Optional[Callable[[dict], Awaitable[None]]],
        description: str,
        done: bool = False,
        level: str = "info",
    ) -> None:
        if emitter:
            await emitter(
                {
                    "type": "status",
                    "data": {
                        "description": description,
                        "done": done,
                        "level": level,
                    },
                }
            )

    async def _stream(
        self,
        payload: dict,
        emitter: Optional[Callable[[dict], Awaitable[None]]],
    ) -> AsyncGenerator[str, None]:
        if not self.api_key:
            raise RuntimeError("HOLMES_API_KEY is not configured")

        timeout = aiohttp.ClientTimeout(total=self.timeout)
        headers = {"X-API-Key": self.api_key, "Accept": "text/event-stream"}
        await self._status(emitter, "HolmesGPT is investigating the cluster")

        event_type = "message"
        emitted_answer = False
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(self.url, json=payload, headers=headers) as response:
                if response.status >= 400:
                    detail = (await response.text())[:1000]
                    raise RuntimeError(f"HolmesGPT returned HTTP {response.status}: {detail}")

                buffer = ""
                async for chunk in response.content.iter_any():
                    buffer += chunk.decode("utf-8", errors="replace")
                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        line = line.rstrip("\r")
                        if line.startswith("event:"):
                            event_type = line[6:].strip()
                        elif line.startswith("data:"):
                            try:
                                data = json.loads(line[5:].strip())
                            except json.JSONDecodeError:
                                continue
                            event = data.get("event", event_type)
                            event_payload = data.get("payload", data)
                            if event == "ai_message":
                                content = event_payload.get("content", "")
                                if content:
                                    emitted_answer = True
                                    yield content
                            elif event == "ai_answer_end" and not emitted_answer:
                                content = event_payload.get("analysis", "")
                                if content:
                                    emitted_answer = True
                                    yield content
                            elif event == "start_tool_calling":
                                tool = event_payload.get("tool_name", "cluster tool")
                                await self._status(emitter, f"Running {tool}")
                            elif event == "approval_required":
                                yield "\n\nHolmesGPT requires approval to continue this investigation."
                            elif event == "error":
                                detail = event_payload.get("message") or str(event_payload)
                                raise RuntimeError(f"HolmesGPT stream error: {detail}")
                        elif not line:
                            event_type = "message"

        await self._status(emitter, "HolmesGPT investigation complete", done=True)

    async def pipe(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __metadata__: Optional[dict] = None,
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
        **_: Any,
    ) -> AsyncGenerator[str, None]:
        try:
            payload = self._payload(body, __metadata__)
            async for content in self._stream(payload, __event_emitter__):
                yield content
        except Exception as error:
            await self._status(
                __event_emitter__, str(error), done=True, level="error"
            )
            yield f"HolmesGPT request failed: {error}"
