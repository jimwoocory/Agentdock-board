from pathlib import Path

from agentdock_board.store import Store


def test_event_projection_and_dedupe(tmp_path: Path) -> None:
    store = Store(tmp_path / "board.db")

    first = store.append_event(
        {
            "task_id": "tsk_demo",
            "type": "created",
            "source": "agentdock",
            "source_event_id": "evt-1",
            "title": "Demo",
            "owner": "lead",
        }
    )
    assert first["duplicate"] is False
    assert first["sequence"] == 1
    assert first["task"]["status"] == "queued"

    duplicate = store.append_event(
        {
            "task_id": "tsk_demo",
            "type": "created",
            "source": "agentdock",
            "source_event_id": "evt-1",
            "title": "Demo",
        }
    )
    assert duplicate["duplicate"] is True
    assert duplicate["sequence"] == 1

    running = store.append_event(
        {
            "task_id": "tsk_demo",
            "type": "running",
            "source": "agentdock",
            "source_event_id": "evt-2",
            "progress": 25,
            "message": "visual_review",
        }
    )
    assert running["task"]["status"] == "running"
    assert running["task"]["progress"] == 25
    assert running["task"]["message"] == "visual_review"
    assert store.latest_sequence() == 2


def test_completed_task_and_action_queue(tmp_path: Path) -> None:
    store = Store(tmp_path / "board.db")
    store.append_event(
        {
            "task_id": "tsk_final",
            "type": "created",
            "source_event_id": "evt-a",
        }
    )
    completed = store.append_event(
        {
            "task_id": "tsk_final",
            "type": "completed",
            "source_event_id": "evt-b",
        }
    )
    assert completed["task"]["status"] == "completed"
    assert completed["task"]["progress"] == 100

    action = store.create_action("tsk_final", "open", {"requested_from": "test"})
    claimed = store.pending_actions(consumer="agentdock")
    assert claimed[0]["action_id"] == action["action_id"]
    assert claimed[0]["status"] == "claimed"

    acked = store.ack_action(action["action_id"], True, {"ok": True})
    assert acked is not None
    assert acked["status"] == "done"
