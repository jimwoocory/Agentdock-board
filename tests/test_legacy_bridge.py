from agentdock_board.legacy_bridge import normalize_event, normalize_snapshot


def test_normalize_legacy_event_aliases() -> None:
    event = normalize_event(
        {
            "taskId": "tsk_1",
            "eventType": "in-progress",
            "eventId": "evt_1",
            "name": "Visual review",
            "assignee": "lead",
            "percentage": 42,
            "currentStep": "shot plan",
        }
    )
    assert event is not None
    assert event["task_id"] == "tsk_1"
    assert event["event_type"] == "running"
    assert event["source_event_id"] == "legacy-event:evt_1"
    assert event["progress"] == 42
    assert event["message"] == "shot plan"


def test_normalize_legacy_snapshot() -> None:
    event = normalize_snapshot(
        {
            "id": "tsk_2",
            "status": "blocked",
            "title": "Final Review",
            "owner": "project-lead",
            "progress": 70,
            "message": "waiting on workspace",
            "last_sequence": 9,
        }
    )
    assert event is not None
    assert event["task_id"] == "tsk_2"
    assert event["event_type"] == "blocked"
    assert event["source_event_id"] == "legacy-model:tsk_2:9"
    assert event["progress"] == 70
