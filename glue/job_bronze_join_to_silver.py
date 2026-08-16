"""Glue 5.0 — bronze parent+child join  ->  silver Iceberg table.

This is the job that teaches the single most important distributed-join
lesson: a parent/child join is a broadcast join when the parent is small,
and getting Spark to do that is the difference between 20 seconds and
20 minutes.

Silver rules:
  1. Silver is JOINED and CONFORMED. Business keys resolved, types final.
  2. Silver is REBUILDABLE from bronze. It carries no state bronze lacks.
  3. Silver is where derived measures first appear (gross_amount).
  4. Orphan children are surfaced, not dropped — a LEFT join plus an
     explicit orphan count, because "rows vanished" is the bug the team
     will otherwise spend a day chasing on the real project.
"""
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["JOB_NAME", "NAMESPACE"])
NS = args["NAMESPACE"]
CATALOG = "s3tables"

sc = SparkContext()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

customers = spark.table(f"{CATALOG}.{NS}.bronze_customers")
orders = spark.table(f"{CATALOG}.{NS}.bronze_orders")

# ---------------------------------------------------------------------------
# The join.
#
# broadcast() forces the small parent side to every executor, turning a
# shuffle-hash join into a broadcast-hash join. Rule of thumb: broadcast when
# the small side fits comfortably under spark.sql.autoBroadcastJoinThreshold
# (10 MB default). A dimension of a few hundred thousand rows usually does.
# Read the plan afterwards to confirm — never assume.
# ---------------------------------------------------------------------------
joined = (
    orders.alias("o")
    .join(F.broadcast(customers.alias("c")), on="customer_id", how="left")
    .select(
        F.col("o.order_id"),
        # UNQUALIFIED, deliberately. `on="customer_id"` is a USING-style join:
        # Spark coalesces the key into a SINGLE output column that belongs to
        # neither alias. `F.col("o.customer_id")` here is ambiguous and can
        # fail analysis with "cannot resolve 'o.customer_id'" depending on the
        # Spark version. Every other column below is unique to one side, so
        # the alias resolves fine there.
        F.col("customer_id"),
        F.col("c.customer_name"),
        F.col("c.segment"),
        F.col("c.country"),
        F.col("o.order_ts"),
        F.col("o.status"),
        F.col("o.quantity"),
        F.col("o.unit_price"),
        (F.col("o.quantity") * F.col("o.unit_price")).cast("decimal(18,2)").alias("gross_amount"),
        F.current_timestamp().alias("joined_at"),
    )
)

# Rule 4 — count orphans loudly rather than losing them.
orphans = joined.filter(F.col("customer_name").isNull()).count()
total = joined.count()
if orphans:
    print(f"[WARN] {orphans}/{total} orders have no matching customer (orphan children)")
else:
    print(f"[ok] all {total} orders matched a parent")

# Show the physical plan so learners can see the broadcast in the output.
joined.explain(mode="formatted")

# Full rebuild each run (rule 2). Iceberg makes this atomic — readers see the
# old snapshot until the overwrite commits.
joined.writeTo(f"{CATALOG}.{NS}.silver_customer_orders").overwritePartitions()

print(f"[silver] wrote {total} rows to {CATALOG}.{NS}.silver_customer_orders")
job.commit()
