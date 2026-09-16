# AgentDock Task Board 2.0 — Local Mode

Local mode does not require ChatGPT, a public URL, or Secure MCP Tunnel.

## Architecture

```text
AgentDock Task Engine
      |
      | TaskReporter / BoardClient
      v
127.0.0.1:8765
AgentDock Task Board 2.0
      |
      +-- SQLite event store + read model
      +-- WebSocket browser UI
      +-- durable action queue
      ^
      |
ActionWorker -> AgentDock Task Engine
```

## Install on Windows

From an existing checkout:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_local.ps1
```

The installer checks `AGENTDOCK_HOME` first, then common AgentDock locations. When AgentDock is detected, the board is installed under:

```text
<AgentDock home>\services\Agentdock-board
```

If AgentDock is not detected, the board is installed as a local sidecar under:

```text
%LOCALAPPDATA%\Agentdock-board
```

Both modes use the same local endpoint:

```text
http://127.0.0.1:8765
```

The browser opens automatically after the health check passes.

## AgentDock lifecycle hooks

Import the integration adapter from the installed package:

```python
from agentdock_board.integration import TaskReporter

reporter = TaskReporter(
    task_id=task.id,
    title=task.title,
    owner=task.owner,
    metadata={"project": task.project_id},
)

reporter.created("queued")
reporter.assigned(task.owner)
reporter.running(progress=task.progress, message=task.current_step)
```

At real task-engine transitions call only the matching real event:

```python
reporter.progress(task.progress, task.current_step)
reporter.blocked(task.block_reason)
reporter.paused("paused by operator")
reporter.resumed("resumed")
reporter.retrying("retry requested")
reporter.failed(str(error))
reporter.completed("Final Review passed")
reporter.cancelled("cancelled")
```

Do not generate synthetic percentages or infer task state from logs.

## Local action worker

Wire the durable board actions back to the existing AgentDock controller:

```python
from agentdock_board.integration import ActionWorker


def execute_board_action(item):
    task_id = item["task_id"]
    action = item["action"]

    if action == "pause":
        task_manager.pause(task_id)
    elif action == "resume":
        task_manager.resume(task_id)
    elif action == "retry":
        task_manager.retry(task_id)
    elif action == "cancel":
        task_manager.cancel(task_id)
    else:
        raise ValueError(f"unsupported board action: {action}")

    return {"task_id": task_id, "action": action}


worker = ActionWorker(execute_board_action)
worker.start_daemon()
```

The action queue uses leases. If AgentDock crashes after claiming an action, an expired lease makes the action available again.

## First acceptance task

Use the existing MediaGo task and resume from its `visual_review` checkpoint. Do not create a replacement task and do not rerun already-passed stages.

The board must show the real task id, owner, current step, status, progress, blocking reason and event sequence. Browser refresh and board-service restart must preserve state.

## Stop local mode

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop_local.ps1
```

## Health checks

```text
http://127.0.0.1:8765/api/health
http://127.0.0.1:8765/api/tasks
```

A valid live integration must have `last_sequence > 0` after AgentDock emits its first real task event.
