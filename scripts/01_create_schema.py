"""
Step 1 — Create the SQLite database and run schema.sql.

Run from the project root:
    python scripts/01_create_schema.py

This is intentionally small: it only creates empty tables.
Step 2 (02_load_data.py) will populate them.
"""

import sqlite3
from pathlib import Path

# --- Resolve paths relative to THIS file, not the cwd ---------------------
# Why: lets you run the script from any directory without breaking.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH      = PROJECT_ROOT / "data" / "pharmacy.db"
SCHEMA_PATH  = PROJECT_ROOT / "sql"  / "schema.sql"


def main() -> None:
    # Make sure data/ exists. exist_ok=True so re-runs don't error.
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)

    # connect() will create the .db file if it does not exist.
    with sqlite3.connect(DB_PATH) as conn:
        # Foreign keys must be enabled per-connection in SQLite.
        conn.execute("PRAGMA foreign_keys = ON;")

        sql = SCHEMA_PATH.read_text()
        # executescript() runs multiple statements separated by ';'.
        # Plain execute() only runs ONE statement — easy beginner trap.
        conn.executescript(sql)
        conn.commit()

    # Sanity check: list the tables we just created.
    with sqlite3.connect(DB_PATH) as conn:
        tables = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
        ).fetchall()

    print(f"Created database at: {DB_PATH}")
    print("Tables:", [t[0] for t in tables])


if __name__ == "__main__":
    main()
