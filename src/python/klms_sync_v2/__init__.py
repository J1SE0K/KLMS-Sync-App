"""Feature-first KLMS sync v2 core.

This package is intentionally pure Python and side-effect free except at CLI
boundaries. Safari, Notes, Calendar, Reminders, and file downloads should call
into this layer rather than mixing parsing and app automation logic.
"""

from .models import Assignment, Event, Notice, Page, SyncState
from .pipeline import build_sync_state

__all__ = [
    "Assignment",
    "Event",
    "Notice",
    "Page",
    "SyncState",
    "build_sync_state",
]
