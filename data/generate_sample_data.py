"""Generate the parent/child sample CSVs.

Defaults are deliberately small so the whole pipeline runs in minutes on a
2-worker Glue job. Scale up with --customers/--orders once the team is
comfortable and you want to make shuffle behaviour visible.

    python generate_sample_data.py                      # 500 / 5000
    python generate_sample_data.py --customers 200000 --orders 4000000

The data is seeded, so every learner gets byte-identical files and query
results can be compared across the room.

Deliberate defects are injected (see --dirty-rate) because the bronze job's
quarantine path and the silver job's orphan count are only teachable if the
data actually contains bad rows:

    * orphan orders      customer_id with no parent row
    * duplicate customers same customer_id twice, different signup_date
    * null required      missing customer_name
    * bad quantity       zero / negative
"""
import argparse
import csv
import random
from datetime import datetime, timedelta
from pathlib import Path

SEGMENTS = ["Enterprise", "MidMarket", "SMB", "Public Sector"]
COUNTRIES = ["US", "CA", "GB", "DE", "FR", "IN", "AU", "JP", "BR", "AE"]
STATUSES = ["COMPLETED", "COMPLETED", "COMPLETED", "PENDING", "CANCELLED", "REFUNDED"]
FIRST = ["Ada", "Grace", "Alan", "Ken", "Barbara", "Linus", "Margaret", "Dennis",
         "Radia", "Vint", "Anita", "Tim", "Katherine", "Donald", "Frances"]
LAST = ["Lovelace", "Hopper", "Turing", "Thompson", "Liskov", "Torvalds",
        "Hamilton", "Ritchie", "Perlman", "Cerf", "Borg", "Berners-Lee",
        "Johnson", "Knuth", "Allen"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--customers", type=int, default=500)
    ap.add_argument("--orders", type=int, default=5000)
    ap.add_argument("--dirty-rate", type=float, default=0.01)
    ap.add_argument("--seed", type=int, default=369)
    ap.add_argument("--out", default="seed")
    a = ap.parse_args()

    rng = random.Random(a.seed)
    out = Path(__file__).parent / a.out
    (out / "parent").mkdir(parents=True, exist_ok=True)
    (out / "child").mkdir(parents=True, exist_ok=True)

    # ---------------------------- parent ----------------------------------
    base = datetime(2023, 1, 1)
    customers = []
    for cid in range(1, a.customers + 1):
        customers.append({
            "customer_id": cid,
            "customer_name": f"{rng.choice(FIRST)} {rng.choice(LAST)}",
            "segment": rng.choice(SEGMENTS),
            "country": rng.choice(COUNTRIES),
            "signup_date": (base + timedelta(days=rng.randint(0, 900))).date().isoformat(),
        })

    dirty = max(1, int(a.customers * a.dirty_rate))
    # duplicate customer_id, newer signup_date -> bronze dedup must pick this one
    for c in rng.sample(customers, dirty):
        dup = dict(c)
        dup["signup_date"] = (
            datetime.fromisoformat(c["signup_date"]) + timedelta(days=30)
        ).date().isoformat()
        dup["segment"] = "Enterprise"
        customers.append(dup)
    # missing required field -> quarantine
    for c in rng.sample(customers[: a.customers], dirty):
        c["customer_name"] = ""

    p = out / "parent" / "customers.csv"
    with p.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(customers[0].keys()))
        w.writeheader()
        w.writerows(customers)

    # ----------------------------- child ----------------------------------
    orders = []
    for oid in range(1, a.orders + 1):
        cid = rng.randint(1, a.customers)
        orders.append({
            "order_id": oid,
            "customer_id": cid,
            "order_ts": (base + timedelta(
                days=rng.randint(0, 1000), seconds=rng.randint(0, 86399)
            )).isoformat(sep=" "),
            "status": rng.choice(STATUSES),
            "quantity": rng.randint(1, 25),
            "unit_price": f"{rng.uniform(4.99, 899.99):.2f}",
        })

    dirty_o = max(1, int(a.orders * a.dirty_rate))
    # orphans -> silver LEFT join must report them
    for o in rng.sample(orders, dirty_o):
        o["customer_id"] = a.customers + rng.randint(1000, 9999)
    # non-positive quantity -> a DQ rule the team writes on day 3
    for o in rng.sample(orders, dirty_o):
        o["quantity"] = rng.choice([0, -1, -5])

    q = out / "child" / "orders.csv"
    with q.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(orders[0].keys()))
        w.writeheader()
        w.writerows(orders)

    print(f"parent -> {p}  ({len(customers)} rows, {dirty} dup + {dirty} null-name)")
    print(f"child  -> {q}  ({len(orders)} rows, {dirty_o} orphan + {dirty_o} bad-qty)")


if __name__ == "__main__":
    main()
