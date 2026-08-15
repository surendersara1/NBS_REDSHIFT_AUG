/*
======================================================================================
MODULE 59: MACHINE LEARNING IN SQL (AMAZON REDSHIFT ML & SAGEMAKER INTEGRATION)
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 103: Redshift ML pushdown — train and infer directly in SQL without moving data to external Python servers.
- Practice 97: Instrument and audit machine learning inference latencies.
- Practice 16: Select only necessary feature columns for model training.

TARGET AUDIENCE: Application Developers & Senior Data Engineers
BUSINESS SCENARIO: 
We want to predict customer churn probability (`will_churn: 0 or 1`) based on 
user tenure, monthly spend, support tickets, and contract type. 

THE PROBLEM:
Traditionally, data scientists export millions of rows to S3, download them into a Python 
Jupyter notebook, train an XGBoost model, and deploy a REST API endpoint. 
When data engineers run batch scoring, sending millions of rows over HTTP to a REST endpoint 
takes hours and costs thousands of dollars in egress and API gateway fees.

THE GOAL:
1. Master Amazon Redshift ML: Train SageMaker models directly using standard SQL (`CREATE MODEL`).
2. Run high-throughput SQL inference functions compiled directly onto compute slices.
3. Track model inference metrics and score predictions in batch pipelines.
======================================================================================
*/

-- ===================================================================================
-- 1. DATA GENERATION BLOCK (Training & Inference Features)
-- ===================================================================================
DROP TABLE IF EXISTS ml_customer_churn_training CASCADE;
CREATE TABLE ml_customer_churn_training (
    customer_id BIGINT NOT NULL,
    tenure_months INT NOT NULL,
    monthly_spend DECIMAL(10,2) NOT NULL,
    support_tickets_last_90d INT NOT NULL,
    contract_type VARCHAR(20) NOT NULL,
    has_autopay BOOLEAN NOT NULL,
    churned INT NOT NULL -- TARGET VARIABLE (0 = Retained, 1 = Churned)
)
DISTSTYLE KEY
DISTKEY (customer_id);

-- Populate 10,000 training examples with synthetic churn correlation:
INSERT INTO ml_customer_churn_training (
    customer_id, tenure_months, monthly_spend, support_tickets_last_90d, contract_type, has_autopay, churned
)
SELECT 
    s.n AS customer_id,
    (1 + (s.n % 60)) AS tenure_months,
    (20.00 + (s.n % 180))::DECIMAL(10,2) AS monthly_spend,
    (s.n % 8) AS support_tickets_last_90d,
    CASE WHEN (s.n % 3) = 0 THEN 'MONTH_TO_MONTH' WHEN (s.n % 3) = 1 THEN 'ONE_YEAR' ELSE 'TWO_YEAR' END AS contract_type,
    CASE WHEN (s.n % 2) = 0 THEN TRUE ELSE FALSE END AS has_autopay,
    -- Synthetic target rule: high tickets & month-to-month = higher churn probability
    CASE WHEN (s.n % 8) >= 4 AND (s.n % 3) = 0 THEN 1 ELSE 0 END AS churned
FROM (
    SELECT ROW_NUMBER() OVER () AS n
    FROM (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c
    CROSS JOIN (SELECT 0 UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d
    LIMIT 10000
) s;

ANALYZE ml_customer_churn_training;

-- Live Customers for Scoring:
DROP TABLE IF EXISTS ml_active_customers_scoring CASCADE;
CREATE TABLE ml_active_customers_scoring (
    customer_id BIGINT NOT NULL,
    tenure_months INT NOT NULL,
    monthly_spend DECIMAL(10,2) NOT NULL,
    support_tickets_last_90d INT NOT NULL,
    contract_type VARCHAR(20) NOT NULL,
    has_autopay BOOLEAN NOT NULL
)
DISTSTYLE KEY
DISTKEY (customer_id);

INSERT INTO ml_active_customers_scoring
SELECT customer_id, tenure_months, monthly_spend, support_tickets_last_90d, contract_type, has_autopay
FROM ml_customer_churn_training WHERE customer_id <= 1000;

DROP TABLE IF EXISTS rpt_churn_predictions CASCADE;
CREATE TABLE rpt_churn_predictions (
    customer_id BIGINT NOT NULL,
    predicted_churn_flag INT NOT NULL,
    scored_at TIMESTAMP DEFAULT SYSDATE
);


-- ===================================================================================
-- 2. REDSHIFT ML MODEL CREATION (SQL DDL Pattern)
-- ===================================================================================
/*
HOW IT WORKS:
1. `CREATE MODEL` exports feature training data to your designated S3 bucket.
2. Automatically invokes Amazon SageMaker Autopilot to train, optimize, and tune algorithms (XGBoost / Random Forest).
3. Compiles the trained model artifact directly into Redshift compute node memory as a SQL scalar function (`fn_predict_churn`).
*/

-- DDL Syntax (Requires IAM Role with SageMaker & S3 permissions):
/*
CREATE MODEL ml_churn_xgboost_model
FROM (
    SELECT 
        tenure_months,
        monthly_spend,
        support_tickets_last_90d,
        contract_type,
        has_autopay,
        churned
    FROM ml_customer_churn_training
)
TARGET churned
FUNCTION fn_predict_churn
IAM_ROLE 'arn:aws:iam::123456789012:role/RedshiftMLSageMakerRole'
AUTO ON
MODEL_TYPE XGBOOST
PROBLEM_TYPE BINARY_CLASSIFICATION
OBJECTIVE 'F1'
SETTINGS (
    S3_BUCKET 'my-redshift-ml-bucket-us-east-1',
    MAX_RUNTIME 3600
);
*/


-- ===================================================================================
-- 3. THE PRODUCTION BATCH INFERENCE STORED PROCEDURE
-- ===================================================================================
/*
WHY IN-DATABASE INFERENCE IS 100x FASTER:
- The SQL function `fn_predict_churn(...)` runs locally on every compute slice in parallel.
- Zero network hops to external Python microservices.
- Can score 100 million customers in under 30 seconds!
*/
CREATE OR REPLACE PROCEDURE prc_batch_score_churn_risk()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_scored BIGINT := 0;
BEGIN
    RAISE INFO 'Starting distributed in-database ML batch inference...';

    TRUNCATE TABLE rpt_churn_predictions;

    -- In production with active Redshift ML model:
    -- INSERT INTO rpt_churn_predictions (customer_id, predicted_churn_flag, scored_at)
    -- SELECT 
    --     customer_id,
    --     fn_predict_churn(tenure_months, monthly_spend, support_tickets_last_90d, contract_type, has_autopay),
    --     SYSDATE
    -- FROM ml_active_customers_scoring;

    -- Emulated SQL heuristic inference for standalone sandbox testing:
    INSERT INTO rpt_churn_predictions (customer_id, predicted_churn_flag, scored_at)
    SELECT 
        customer_id,
        CASE WHEN support_tickets_last_90d >= 4 AND contract_type = 'MONTH_TO_MONTH' THEN 1 ELSE 0 END,
        SYSDATE
    FROM ml_active_customers_scoring;

    GET DIAGNOSTICS v_rows_scored = ROW_COUNT;
    RAISE INFO 'ML Batch inference complete: % customer scores generated in parallel.', v_rows_scored;

EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'prc_batch_score_churn_risk failed: %', SQLERRM;
END;
$$;


-- ===================================================================================
-- 4. MODEL MONITORING & CATALOG QUERIES
-- ===================================================================================

-- (a) Inspect Model Status and Training Progress in Catalog:
SELECT model_name, model_state_type, estimated_cost, model_type, problem_type
FROM stv_ml_model_info;

-- (b) Check Model Metrics (F1 score, Accuracy, Precision, Recall):
-- SELECT * FROM svv_ml_model_info WHERE model_name = 'ml_churn_xgboost_model';

-- (c) Run Batch Inference:
-- CALL prc_batch_score_churn_risk();
-- SELECT predicted_churn_flag, COUNT(1) FROM rpt_churn_predictions GROUP BY 1;
