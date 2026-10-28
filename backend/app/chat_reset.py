"""Erase only app/API conversations through Hermes' own deletion API, never CLI history."""

from urllib.parse import quote

import httpx


async def clear_api_history(urls: list[str], key: str) -> int:
    deleted = 0
    async with httpx.AsyncClient(timeout=20, headers={"Authorization": f"Bearer {key}"}) as client:
        for url in dict.fromkeys(urls):
            for _ in range(100):
                response = await client.get(f"{url}/api/sessions",
                    params={"source": "api_server", "limit": 200, "include_children": "true"})
                if response.status_code == 404 and "/p/marcel-" in url:
                    break  # This bot's profile was never created, or is already gone.
                response.raise_for_status()
                rows = response.json()["data"]
                if not rows:
                    break
                for row in rows:
                    # Check the returned source too: an incompatible server must never erase other channels.
                    if row.get("source") != "api_server" or not isinstance(row.get("id"), str):
                        raise ValueError("Unexpected Hermes session scope")
                    result = await client.delete(f"{url}/api/sessions/{quote(row['id'], safe='')}")
                    if result.status_code != 404:
                        result.raise_for_status()
                    deleted += 1
            else:
                raise ValueError("Hermes session cleanup did not converge")
    return deleted
