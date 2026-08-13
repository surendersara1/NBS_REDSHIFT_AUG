"""Glue 5.0 — raw CSV  ->  bronze Iceberg tables in S3 Tables.

Bronze rules for this platform (state them to the team on day 2, they are
the reason bronze exists at all):

  1. Bronze is TYPED but not JOINED. One raw file -> one bronze table.
  2. Bronze is IDEMPOTENT. Re-running the job for the same source must not
     duplicate rows. Here that is a MERGE on the natural key.
  3. Bronze keeps provenance. ingested_at is stamped at write time and is
     never sourced from the file.
  4. Bronze does not drop bad rows silently. They go to a quarantine prefix.

Run:
    aws glue start-job-run --job-name nbs-coaching-raw-to-bronze-dev
"""
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.types import (
    DateType,
    DecimalType,
    IntegerType,
    LongType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)

args = getResolvedOptions(sys.argv, ["JOB_NAME", "RAW_BUCKET", "NAMESPACE"])
RAW_BUCKET = args["RAW_BUCKET"]
NS = args["NAMESPACE"]
CATALOG = "s3tables"

sc = SparkContext()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

# ---------------------------------------------------------------------------
# Explicit schemas. inferSchema on CSV is a correctness bug waiting to happen:
# it samples, so a column that is integer in the first 1000 rows and
# alphanumeric in row 50000 flips type between runs.
# ---------------------------------------------------------------------------
customers_schema = StructType([
    StructField("customer_id", LongType(), False),
    StructField("customer_name", StringType(), False),
    StructField("segment", StringType(), True),
    StructField("country", StringType(), True),
    StructField("signup_date", DateType(), True),
])

orders_schema = StructType([
    StructField("order_id", LongType(), False),
    StructField("customer_id", LongType(), False),
    StructField("order_ts", TimestampType(), True),
    StructField("status", StringType(), True),
    StructField("quantity", IntegerType(), True),
    StructField("unit_price", DecimalType(18, 2), True),
])


def read_csv(prefix: str, schema: StructType):
    """PERMISSIVE + _corrupt_record is what makes rule 4 enforceable."""
    corrupt = StructType(schema.fields + [StructField("_corrupt_record", StringType(), True)])
    return (
        spark.read.option("header", "true")
        .option("mode", "PERMISSIVE")
        .option("columnNameOfCorruptRecord", "_corrupt_record")
        .schema(corrupt)
        .csv(f"s3://{RAW_BUCKET}/{prefix}/")
    )


def split_valid(df, required_cols):
    """Split into (good, bad) with a single predicate and its negation.

    Using ~is_bad rather than df.subtract(bad) matters: subtract is a
    distinct-set operation, so it would both shuffle the whole frame and
    silently collapse legitimate duplicate rows.
    """
    is_bad = F.col("_corrupt_record").isNotNull()
    for c in required_cols:
        is_bad = is_bad | F.col(c).isNull()

    bad = df.filter(is_bad)
    good = df.filter(~is_bad).drop("_corrupt_record")
    return good, bad


def quarantine(bad_df, name: str):
    if bad_df.head(1):
        (
            bad_df.withColumn("quarantined_at", F.current_timestamp())
            .write.mode("append")
            .parquet(f"s3://{RAW_BUCKET}/_quarantine/{name}/")
        )
        print(f"[quarantine] {name}: {bad_df.count()} rows failed validation")


def merge_into(df, table: str, key_cols: list):
    """Iceberg MERGE — this is what makes the job idempotent (rule 2).

    Spark's saveAsTable(mode='append') would duplicate on re-run; MERGE
    matches on the natural key and updates in place.
    """
    tmp = f"stg_{table}"
    df.createOrReplaceTempView(tmp)
    on_clause = " AND ".join([f"t.{c} = s.{c}" for c in key_cols])
    update_cols = [c for c in df.columns if c not in key_cols]
    set_clause = ", ".join([f"t.{c} = s.{c}" for c in update_cols])
    insert_cols = ", ".join(df.columns)
    insert_vals = ", ".join([f"s.{c}" for c in df.columns])

    spark.sql(f"""
        MERGE INTO {CATALOG}.{NS}.{table} AS t
        USING {tmp} AS s
          ON {on_clause}
        WHEN MATCHED THEN UPDATE SET {set_clause}
        WHEN NOT MATCHED THEN INSERT ({insert_cols}) VALUES ({insert_vals})
    """)
    print(f"[bronze] merged into {CATALOG}.{NS}.{table}")


# --------------------------- parent: customers -----------------------------
raw_customers = read_csv("parent", customers_schema)
good_c, bad_c = split_valid(raw_customers, ["customer_id", "customer_name"])
quarantine(bad_c, "customers")

bronze_customers = (
    good_c
    # Late-arriving duplicates of the same customer_id: keep the newest signup.
    .withColumn(
        "_rn",
        F.row_number().over(
            Window.partitionBy("customer_id").orderBy(
                F.col("signup_date").desc_nulls_last()
            )
        ),
    )
    .filter(F.col("_rn") == 1)
    .drop("_rn")
    .withColumn("ingested_at", F.current_timestamp())
)
merge_into(bronze_customers, "bronze_customers", ["customer_id"])

# ----------------------------- child: orders -------------------------------
raw_orders = read_csv("child", orders_schema)
good_o, bad_o = split_valid(raw_orders, ["order_id", "customer_id"])
quarantine(bad_o, "orders")

bronze_orders = good_o.dropDuplicates(["order_id"]).withColumn(
    "ingested_at", F.current_timestamp()
)
merge_into(bronze_orders, "bronze_orders", ["order_id"])

print(f"[bronze] customers={bronze_customers.count()} orders={bronze_orders.count()}")
job.commit()
