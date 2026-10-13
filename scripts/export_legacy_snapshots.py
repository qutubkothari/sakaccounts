"""Export named read-only SQLite snapshots as CSV for PostgreSQL COPY.

Usage: python scripts/export_legacy_snapshots.py OWNER_UUID OUT.csv NAME=PATH [NAME=PATH...]
The output contains real financial data. Store it outside Git and delete it after import.
"""
import csv
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

TABLES = (
    "bank_accounts", "businesses", "doc_counters", "documents",
    "expense_types", "inventory_items", "payment_events", "settings",
    "transactions", "vendors",
)


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    owner, destination, *sources = sys.argv[1:]
    with Path(destination).open("w", newline="", encoding="utf-8") as target:
        writer = csv.writer(target)
        for source in sources:
            name, filename = source.split("=", 1)
            connection = sqlite3.connect(f"file:{Path(filename).resolve().as_posix()}?mode=ro", uri=True)
            connection.row_factory = sqlite3.Row
            for table in TABLES:
                available = connection.execute("select 1 from sqlite_master where type='table' and name=?", (table,)).fetchone()
                if not available:
                    continue
                key_name = "key" if table == "settings" else "id"
                for row in connection.execute(f"select * from {table}"):
                    record = dict(row)
                    payload = json.dumps(record, sort_keys=True, ensure_ascii=False, default=str, separators=(",", ":"))
                    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
                    writer.writerow((owner, name, table, str(record[key_name]), payload, digest))
            connection.close()


if __name__ == "__main__":
    main()
