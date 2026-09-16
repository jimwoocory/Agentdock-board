from agentdock_board.native_task_bridge import normalize_native_task


def test_native_active_task_maps_to_created() -> None:
    task = {
        "id": "tsk_demo",
        "title": "Demo task",
        "status": "active",
        "phase": "check",
        "steps": [
            {
                "id": "s1",
                "title": "Inspect",
                "phase": "check",
                "status": "pending",
                "updated_at": "2026-09-16T00:00:00Z",
            }
        ],
        "updated_at": "2026-09-16T00:00:00Z",
    }
    event = normalize_native_task(task)
    assert event is not None
    assert event["event_type"] == "created"
    assert event["progress"] == 0.0
    assert event["metadata"]["native_agentdock_task"] is True


def test_native_running_task_uses_step_progress() -> None:
    task = {
        "id": "tsk_run",
        "title": "Running task",
        "status": "active",
        "phase": "execute",
        "steps": [
            {
                "id": "s1",
                "title": "Inspect",
                "phase": "check",
                "status": "completed",
                "updated_at": "2026-09-16T00:01:00Z",
            },
            {
                "id": "s2",
                "title": "Implement",
                "phase": "execute",
                "status": "in_progress",
                "updated_at": "2026-09-16T00:02:00Z",
            },
        ],
        "updated_at": "2026-09-16T00:02:00Z",
    }
    event = normalize_native_task(task)
    assert event is not None
    assert event["event_type"] == "running"
    assert event["progress"] == 50.0
    assert event["message"] == "Implement"


def test_native_blocked_task_maps_blocker() -> None:
    task = {
        "id": "tsk_blocked",
        "title": "Blocked task",
        "status": "blocked",
        "phase": "execute",
        "blocker": "Waiting for approval",
        "steps": [],
        "updated_at": "2026-09-16T00:03:00Z",
    }
    event = normalize_native_task(task)
    assert event is not None
    assert event["event_type"] == "blocked"
    assert event["message"] == "Waiting for approval"


def test_native_completed_task_is_100_percent() -> None:
    task = {
        "id": "tsk_done",
        "title": "Done task",
        "status": "completed",
        "phase": "closeout",
        "steps": [],
        "updated_at": "2026-09-16T00:04:00Z",
        "completed_at": "2026-09-16T00:04:00Z",
    }
    event = normalize_native_task(task)
    assert event is not None
    assert event["event_type"] == "completed"
    assert event["progress"] == 100.0
