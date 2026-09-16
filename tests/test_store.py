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


def test_failed_task_can_retry(tmp_path: Path) -> None:
    store = Store(tmp_path / "board.db")
    store.append_event(
        {
            "task_id": "tsk_retry",
            "type": "created",
            "source_event_id": "evt-1",
        }
    )
    failed = store.append_event(
        {
            "task_id": "tsk_retry",
            "type": "failed",
            "source_event_id": "evt-2",
            "message": "worker disconnected",
        }
    )
    assert failed["task"]["status"] == "failed"

    retried = store.append_event(
        {
            "task_id": "tsk_retry",
            "type": "retrying",
            "source_event_id": "evt-3",
            "message": "worker restored",
        }
    )
    assert retried["task"]["status"] == "running"
    assert retried["task"]["message"] == "worker restored"


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
    claimed = store.pending_actions(consumer="agentdock", lease_seconds=30)
    assert claimed[0]["action_id"] == action["action_id"]
    assert claimed[0]["status"] == "claimed"
    assert claimed[0]["claim_count"] == 1
    assert claimed[0]["lease_until"] is not None

    acked = store.ack_action(action["action_id"], True, {"ok": True})
    assert acked is not None
    assert acked["status"] == "done"
    assert acked["lease_until"] is None


def test_expired_action_lease_is_reclaimed(tmp_path: Path) -> None:
    store = Store(tmp_path / "board.db")
    store.append_event(
        {
            "task_id": "tsk_lease",
            "type": "created",
            "source_event_id": "evt-a",
        }
    )
    action = store.create_action("tsk_lease", "resume", {})
    first_claim = store.pending_actions(consumer="agentdock", lease_seconds=30)
    assert first_claim[0]["action_id"] == action["action_id"]
    assert first_claim[0]["claim_count"] == 1

    with store._connect() as conn:
        conn.execute(
            "UPDATE actions SET lease_until='2000-01-01T00:00:00+00:00' WHERE action_id=?",
            (action["action_id"],),
        )

    second_claim = store.pending_actions(consumer="agentdock-restored", lease_seconds=30)
    assert second_claim[0]["action_id"] == action["action_id"]
    assert second_claim[0]["consumer"] == "agentdock-restored"
    assert second_claim[0]["claim_count"] == 2
