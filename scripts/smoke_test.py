from __future__ import annotations

import argparse
import time
import uuid

from agentdock_board.client import BoardClient


def main() -> None:
    parser = argparse.ArgumentParser(description="AgentDock Task Board 2.0 smoke test")
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    args = parser.parse_args()

    client = BoardClient(args.url)
    health = client.health()
    assert health.get("ok") is True, health

    task_id = f"tsk_smoke_{uuid.uuid4().hex[:8]}"
    client.emit(
        task_id=task_id,
        event_type="created",
        title="Task Board 2.0 Smoke Test",
        owner="smoke-test",
        message="created",
    )
    client.emit(
        task_id=task_id,
        event_type="running",
        progress=40,
        message="running",
    )
    client.emit(
        task_id=task_id,
        event_type="blocked",
        progress=40,
        message="simulated block",
    )
    client.emit(
        task_id=task_id,
        event_type="resumed",
        progress=60,
        message="resumed",
    )
    client.emit(
        task_id=task_id,
        event_type="completed",
        progress=100,
        message="completed",
    )

    time.sleep(0.2)
    print(f"SMOKE_OK task_id={task_id} last_sequence={client.health()['last_sequence']}")


if __name__ == "__main__":
    main()
