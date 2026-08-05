import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, when, abs as spark_abs, round as spark_round

# --- Job initialization ---
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'database_name',
    'table_name',
    'output_path'
])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# --- Read from the Data Catalog ---
dyf = glueContext.create_dynamic_frame.from_catalog(
    database=args['database_name'],
    table_name=args['table_name']
)
df = dyf.toDF()

# --- Data quality rules ---
df = df.filter(col("amount") > 0)
df = df.dropDuplicates()

# Round monetary fields to 2 decimals (accounting standard: cents)
df = df.withColumn("amount", spark_round(col("amount"), 2)) \
       .withColumn("oldbalanceorg", spark_round(col("oldbalanceorg"), 2)) \
       .withColumn("newbalanceorig", spark_round(col("newbalanceorig"), 2)) \
       .withColumn("oldbalancedest", spark_round(col("oldbalancedest"), 2)) \
       .withColumn("newbalancedest", spark_round(col("newbalancedest"), 2))

# Expected balance: add if CASH_IN (money comes in), subtract otherwise (money goes out)
df = df.withColumn(
    "expected_balance",
    spark_round(
        when(col("type") == "CASH_IN", col("oldbalanceorg") + col("amount"))
        .otherwise(col("oldbalanceorg") - col("amount")),
        2
    )
)

# Consistency check: rounding removes most decimal noise,
# the 1-cent tolerance stays as an extra safety margin
df = df.withColumn(
    "balance_consistency_flag",
    spark_round(spark_abs(col("expected_balance") - col("newbalanceorig")), 2) <= 0.01
)

df = df.drop("expected_balance")

# --- Derived field: risk flag ---
df = df.withColumn(
    "risk_flag",
    when(
        (col("type").isin("TRANSFER", "CASH_OUT")) &
        (col("amount") > 200000) &
        (spark_round(spark_abs(col("oldbalanceorg") - col("amount")), 2) <= 0.01),
        1
    ).otherwise(0)
)

# --- Write to curated zone, partitioned by type ---
df.write.mode("overwrite").partitionBy("type").parquet(
    args['output_path']
)

job.commit()