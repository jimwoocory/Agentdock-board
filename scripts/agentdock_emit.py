from __future__ import annotations

import argparse

from agentdock_board.client import BoardClient


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Emit a real task event to AgentDock Task Board 2.0"
    )
    parser.add_argument(
        "event_type",
        help="created/running/progress/blocked/completed/failed/...",
    )
    parser.add_argument("task_id")
    parser.add_argument("--title")
    parser.add_argument("--owner")
    parser.add_argument("--progress", type=float)
    parser.add_argument("--message")
    parser.add_argument("--source", default="agentdock")
    parser.add_argument("--source-event-id")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    result = BoardClient().emit(
        task_id=args.task_id,
        event_type=args.event_type,
        source=args.source,
        source_event_id=args.source_event_id,
        title=args.title,
        owner=args.owner,
        progress=args.progress,
        message=args.message,
    )
    print(result)


if __name__ == "__main__":
    main()
