/*
======================================================================================
MODULE 52.2: LOCKING DEEP DIVE — TABLE LOCKS, TRANSACTIONS, AND BLOCKED SESSIONS
======================================================================================
MAPPED BEST PRACTICES (from PROCEDURE_OPTIMIZATION_BEST_PRACTICES_MASTER_FILE.md):
- Practice 80: Understand Redshift isolation and table-level locks.
- Practice 81: Keep transactions reasonably short — long transactions increase
  locking pressure.
- Practice 82: Design every operation to be retry-safe.
- Practice 83: Avoid partial target loads.
- Practice 104: Separate ETL/batch workloads from BI/dashboard queues.

TARGET AUDIENCE: Everyone who writes DML. Read after module 52 (table types) and
                 52.1 (join algorithms). Module 44 covers the DBA triage runbook;
                 this file covers the MECHANICS underneath it.

======================================================================================
THE ONE SENTENCE THAT EXPLAINS EVERYTHING BELOW
======================================================================================
  ** REDSHIFT LOCKS WHOLE TABLES. THERE ARE NO ROW LOCKS. **

If you come from PostgreSQL, MySQL, SQL Server or Oracle, this is the single
biggest adjustment. In an OLTP database two sessions updating two DIFFERENT rows
of the same table proceed happily in parallel, because the lock is on the row.
In Redshift they do not. The lock is on the TABLE, so the second session waits
for the first to finish its whole transaction.

That is not a defect. Redshift is a columnar MPP warehouse: data lives in 1 MB
immutable blocks spread across slices, and there is no row identity to lock. The
design assumes few, large, batch writes — not many small concurrent ones.

Everything else in this file follows from that sentence.

======================================================================================
THE THREE LOCK MODES
======================================================================================
┌──────────────────────┬──────────────────────────────┬───────────────────────────┐
│ Lock mode            │ Acquired by                  │ Blocks                    │
├──────────────────────┼──────────────────────────────┼───────────────────────────┤
│ AccessShareLock      │ SELECT, UNLOAD               │ ONLY AccessExclusiveLock  │
│                      │ (also the read phase of      │ Never blocks another      │
│                      │  UPDATE and DELETE)          │ reader or a writer.       │
├──────────────────────┼──────────────────────────────┼───────────────────────────┤
│ ShareRowExclusiveLock│ COPY, INSERT, UPDATE, DELETE │ AccessExclusiveLock and   │
│                      │                              │ other ShareRowExclusive.  │
│                      │                              │ Does NOT block readers.   │
├──────────────────────┼──────────────────────────────┼───────────────────────────┤
│ AccessExclusiveLock  │ ALTER TABLE, DROP TABLE,     │ EVERYTHING, including     │
│                      │ TRUNCATE, VACUUM,            │ plain SELECTs.            │
│                      │ LOCK TABLE                   │                           │
└──────────────────────┴──────────────────────────────┴───────────────────────────┘

THE CONFLICT MATRIX — "if A holds the row, can B take the column?"

                        │ B wants:  AccessShare  ShareRowExcl  AccessExclusive
    ────────────────────┼──────────────────────────────────────────────────────
    A holds AccessShare │              YES          YES            WAIT
    A holds ShareRowExcl│              YES          WAIT           WAIT
    A holds AccessExcl  │             WAIT          WAIT           WAIT

  READ THE FIRST COLUMN. A reader is almost never blocked, and almost never
  blocks anyone. Redshift readers and writers do not fight. Only DDL fights
  everybody. That is why the production incident is nearly always "somebody left
  a transaction open and then someone else ran an ALTER TABLE".

======================================================================================
THE OTHER HALF: LOCKS ARE HELD UNTIL THE TRANSACTION ENDS
======================================================================================
A lock is NOT released when the statement finishes. It is released at COMMIT or
ROLLBACK. With autocommit ON (the default), every statement is its own tiny
transaction, so locks appear and vanish instantly and you never notice them.

The moment somebody types BEGIN, that stops being true. The lock is now held for
as long as that session stays in the transaction — including while the developer
goes to lunch with the tab open. That is the whole shape of every locking
incident you will ever debug.

======================================================================================
!! HOW TO RUN THIS FILE — YOU NEED TWO SESSIONS !!
======================================================================================
Locking CANNOT be demonstrated in one session. A session never blocks itself.

  1. Open Redshift Query Editor v2.
  2. Open a SECOND TAB. Each tab is a separate session with its own connection.
  3. Confirm they really are different sessions — run this in both:
         SELECT pg_backend_pid();
     Two different numbers means you are ready. The same number means you are in
     one session and none of the demos below will block.

Every demo is choreographed as numbered steps: A1, B1, A2, B2 ... Run them in
NUMERIC order, in the session the label names. Do not run ahead.

A step marked [BLOCKS] will HANG. That hang is the lesson, not a failure.
Every demo ends with a step that releases it.

IF YOU GET STUCK: run Section 9's triage query from a third tab, find the pid,
and terminate it. Nothing here can damage anything outside these demo tables.

VERIFICATION NOTE: lock modes, isolation behaviour and the system views used here
are from the Redshift Database Developer Guide. This file has not been executed
on a live cluster -- these demos are exactly the kind you should run yourself,
which is the point of the module.
======================================================================================
*/


-- ============================================================================
-- SECTION 0: SETUP — RUN THIS ONCE, IN SESSION A ONLY
-- ============================================================================
DROP TABLE IF EXISTS lock_accounts CASCADE;
CREATE TABLE lock_accounts (
    account_id  INT           NOT NULL,
    owner_name  VARCHAR(40)   NOT NULL,
    balance     DECIMAL(12,2) NOT NULL
)
DISTSTYLE ALL;

INSERT INTO lock_accounts (account_id, owner_name, balance) VALUES
    (1, 'Alice',   1000.00),
    (2, 'Bob',      500.00),
    (3, 'Charlie',  750.00),
    (4, 'Dana',    2000.00);

DROP TABLE IF EXISTS lock_ledger CASCADE;
CREATE TABLE lock_ledger (
    entry_id   INT           NOT NULL,
    account_id INT           NOT NULL,
    amount     DECIMAL(12,2) NOT NULL,
    entry_note VARCHAR(60)   NOT NULL
)
DISTSTYLE ALL;

INSERT INTO lock_ledger (entry_id, account_id, amount, entry_note) VALUES
    (1, 1, 1000.00, 'opening balance'),
    (2, 2,  500.00, 'opening balance'),
    (3, 3,  750.00, 'opening balance'),
    (4, 4, 2000.00, 'opening balance');

ANALYZE lock_accounts;
ANALYZE lock_ledger;

-- Confirm your two sessions are genuinely separate. Run in BOTH tabs:
SELECT pg_backend_pid() AS my_session_pid, current_user AS me;
-- Two DIFFERENT pids = ready. Same pid = you only have one session.


-- ============================================================================
-- SECTION 1: WHAT EACH STATEMENT ACQUIRES
-- ============================================================================
-- Before any two-session choreography, see the locks with your own eyes.
-- Open a transaction, run one statement, and look at what you are holding.

-- ┌─ SESSION A ────────────────────────────────────────────────────────────┐
-- A1. Open a transaction and read. Do NOT commit yet.
BEGIN;
SELECT COUNT(*) FROM lock_accounts;

-- A2. Look at what you now hold. Note the transaction is still open.
SELECT
    pid,
    txn_owner,
    txn_start,
    lock_mode,                 -- <-- the mode you just acquired
    lockable_object_type,      -- 'relation' = a table, 'transactionid' = the txn
    relation,
    granted
FROM svv_transactions
WHERE pid = pg_backend_pid()
ORDER BY lockable_object_type, relation;
/*
 Expect a row with lock_mode = AccessShareLock on the lock_accounts relation,
 plus an ExclusiveLock on lockable_object_type = 'transactionid'. That second
 one is normal and is on the transaction itself, not on any table -- every
 transaction holds one. Ignore it; it is not what blocks anybody.
*/

-- A3. Now write in the SAME transaction and look again:
UPDATE lock_accounts SET balance = balance + 1 WHERE account_id = 1;

SELECT pid, lock_mode, lockable_object_type, relation, granted
FROM svv_transactions
WHERE pid = pg_backend_pid()
ORDER BY lockable_object_type, relation;
-- The lock on lock_accounts has escalated. You now hold a write-level lock and
-- you will hold it until you end the transaction.

-- A4. Release everything:
ROLLBACK;

SELECT COUNT(*) FROM svv_transactions WHERE pid = pg_backend_pid();
-- Back to nothing (or just your own housekeeping rows). Locks are gone.
-- └───────────────────────────────────────────────────────────────────────┘

/*
THE POINT OF SECTION 1
  * A lock belongs to a TRANSACTION, not a statement.
  * Reading escalates nothing. Writing escalates the lock for the whole txn.
  * ROLLBACK releases just as well as COMMIT. If a session is blocking you and
    its work is worthless, ROLLBACK is the fastest safe fix.
*/


-- ============================================================================
-- DEMO 1: TWO READERS NEVER FIGHT   (AccessShare + AccessShare = OK)
-- ============================================================================
-- The baseline. Nothing blocks. Prove it before you look at anything that does.

-- A1  SESSION A:
BEGIN;
SELECT SUM(balance) FROM lock_accounts;

-- B1  SESSION B:  runs immediately, no wait
SELECT COUNT(*) FROM lock_accounts;

-- B2  SESSION B: even a long analytical read is fine
SELECT owner_name, balance, RANK() OVER (ORDER BY balance DESC) AS rnk
FROM lock_accounts;

-- A2  SESSION A:
COMMIT;

-- RESULT: no waiting at any point. Two AccessShareLocks coexist happily.
-- This is why a dashboard refreshing every 30 seconds does not slow your ETL.


-- ============================================================================
-- DEMO 2: A WRITER DOES NOT BLOCK A READER   ** THE BIG REDSHIFT SURPRISE **
-- ============================================================================
-- In many OLTP databases an uncommitted UPDATE makes readers wait, or forces
-- them to read an undo log. In Redshift the reader sails straight past.
-- And -- this is the important half -- it reads the OLD value.

-- A1  SESSION A: start writing, and DO NOT COMMIT.
BEGIN;
UPDATE lock_accounts SET balance = 9999.00 WHERE account_id = 1;
SELECT balance FROM lock_accounts WHERE account_id = 1;   -- A sees 9999.00

-- B1  SESSION B: [DOES NOT BLOCK] runs instantly
SELECT balance FROM lock_accounts WHERE account_id = 1;
/*
 balance
---------
 1000.00     <-- the OLD value. Not 9999. Not a wait. Not an error.
*/
-- Session B is reading the last COMMITTED state. Session A's uncommitted change
-- is invisible to everyone but A. No blocking, no dirty read.

-- A2  SESSION A: commit
COMMIT;

-- B2  SESSION B: read again
SELECT balance FROM lock_accounts WHERE account_id = 1;
-- Now 9999.00.

-- A3  SESSION A: put it back
UPDATE lock_accounts SET balance = 1000.00 WHERE account_id = 1;

/*
WHY THIS MATTERS OPERATIONALLY
  Your BI users are never blocked by your ETL. That is the good news.
  The bad news is the flip side: while a long load is running, every dashboard
  in the building is quietly serving PRE-LOAD numbers, with no indication that
  anything is in flight. "The report was wrong for twenty minutes" is usually
  this, not a bug.
  Demo 5 shows how far that staleness can stretch inside one transaction.
*/


-- ============================================================================
-- DEMO 3: TWO WRITERS DO FIGHT   (ShareRowExclusive x2 = WAIT)
-- ============================================================================
-- Two sessions writing to the SAME TABLE serialise, even when they touch
-- completely different rows. This is the row-lock assumption breaking.

-- A1  SESSION A:
BEGIN;
UPDATE lock_accounts SET balance = balance + 10 WHERE account_id = 1;   -- Alice

-- B1  SESSION B: [BLOCKS] — a DIFFERENT row, and it still waits
BEGIN;
UPDATE lock_accounts SET balance = balance + 20 WHERE account_id = 2;   -- Bob
-- ^ This hangs. In PostgreSQL it would not: different rows, different locks.
--   In Redshift there is one lock and it is on the table.

-- C1  A THIRD TAB (or wait and use Section 9): see the block in progress
SELECT
    t.pid,
    t.txn_owner,
    t.lock_mode,
    t.granted,                 -- f = THIS is the session that is waiting
    DATEDIFF(second, t.txn_start, GETDATE()) AS txn_age_seconds,
    c.relname AS table_name
FROM svv_transactions t
LEFT JOIN pg_class c ON c.oid = t.relation
WHERE c.relname = 'lock_accounts'
ORDER BY t.granted DESC, t.txn_start;
-- One row with granted = t (the holder, session A) and one with granted = f
-- (the waiter, session B). That pair IS the incident.

-- A2  SESSION A: release
COMMIT;
-- B1 now completes immediately. Watch it unblock.

-- B2  SESSION B:
COMMIT;

/*
THE LESSON
  Concurrency on a single Redshift table is effectively ONE WRITER AT A TIME.
  Design for it:
    * batch your writes -- one big INSERT beats a hundred small ones (module 23)
    * keep write transactions SHORT (module 35 batches with periodic COMMIT)
    * stage into separate per-job tables and publish once, so jobs never queue
      on the same target
*/


-- ============================================================================
-- DEMO 4: DDL BLOCKS EVERYTHING, INCLUDING PLAIN SELECTS
-- ============================================================================
-- AccessExclusiveLock is the only mode that blocks a reader. It is why an
-- innocent-looking ALTER TABLE can take an entire BI estate down.

-- A1  SESSION A: an ordinary, uncommitted read
BEGIN;
SELECT COUNT(*) FROM lock_accounts;

-- B1  SESSION B: [BLOCKS] DDL cannot start while ANY transaction holds the table
ALTER TABLE lock_accounts ADD COLUMN risk_score INT;
-- ^ Hangs behind a SELECT. Note session A is not even doing anything now --
--   it just has an open transaction.

-- C1  THIRD TAB: confirm what is happening
SELECT t.pid, t.lock_mode, t.granted,
       DATEDIFF(second, t.txn_start, GETDATE()) AS age_sec,
       c.relname
FROM svv_transactions t
LEFT JOIN pg_class c ON c.oid = t.relation
WHERE c.relname = 'lock_accounts'
ORDER BY t.granted DESC;

-- A2  SESSION A: release and B1 completes
COMMIT;

-- ** NOW THE PART THAT CAUSES OUTAGES **
-- Once the ALTER is WAITING, it queues ahead of new readers. Try this:

-- A1  SESSION A:
BEGIN;
SELECT COUNT(*) FROM lock_accounts;

-- B1  SESSION B: [BLOCKS] queues for AccessExclusive
ALTER TABLE lock_accounts ADD COLUMN risk_band VARCHAR(10);

-- C1  THIRD TAB: [BLOCKS TOO] — a brand new, ordinary SELECT
SELECT COUNT(*) FROM lock_accounts;
-- ^ This is the outage. One idle transaction + one DDL = every subsequent
--   reader piles up behind the DDL. Dashboards time out estate-wide, and the
--   root cause is a developer who typed BEGIN and walked away.

-- A2  SESSION A:
COMMIT;      -- the whole queue drains at once

-- Tidy up whichever columns actually got added:
ALTER TABLE lock_accounts DROP COLUMN IF EXISTS risk_score;
ALTER TABLE lock_accounts DROP COLUMN IF EXISTS risk_band;

/*
THE OPERATIONAL RULE
  Never run DDL against a busy table without first checking SVV_TRANSACTIONS
  for open transactions. Add a statement_timeout (Demo 10) so a blocked DDL
  gives up instead of building a queue behind itself.
*/


-- ============================================================================
-- DEMO 5: SNAPSHOT ISOLATION — WHY YOUR LONG TRANSACTION READS STALE DATA
-- ============================================================================
-- SNAPSHOT isolation is the DEFAULT in Redshift provisioned clusters and
-- serverless workgroups. A transaction sees the latest committed snapshot as of
-- the moment the TRANSACTION started -- not as of each statement.
--
-- Consequence: inside a long transaction, the world is frozen. Committed work by
-- other sessions is invisible to you until you end your own transaction. No
-- error, no warning, no blocking. Just quietly old numbers.

-- A1  SESSION A: open a transaction and take your first read
BEGIN;
SELECT balance FROM lock_accounts WHERE account_id = 2;
/*
 balance
---------
  500.00
*/

-- B1  SESSION B: change it and COMMIT — fully visible to the outside world
UPDATE lock_accounts SET balance = 5555.00 WHERE account_id = 2;
COMMIT;

-- B2  SESSION B: prove it is really committed
SELECT balance FROM lock_accounts WHERE account_id = 2;   -- 5555.00

-- A2  SESSION A: read AGAIN, in the same still-open transaction
SELECT balance FROM lock_accounts WHERE account_id = 2;
/*
 balance
---------
  500.00     <-- STILL the old value, even though B committed. This is snapshot
             isolation. A is pinned to the snapshot from step A1.
*/

-- A3  SESSION A: end the transaction and read once more
COMMIT;
SELECT balance FROM lock_accounts WHERE account_id = 2;   -- NOW 5555.00

-- Put it back:
UPDATE lock_accounts SET balance = 500.00 WHERE account_id = 2;

/*
STALE vs FRESH — THE PRACTICAL RULES
  * A long-running report inside BEGIN...COMMIT is internally CONSISTENT (every
    query in it sees one coherent moment) but increasingly STALE.
  * That consistency is the point. A five-query report that spans a load would
    otherwise have query 1 and query 5 disagreeing, and the totals would not
    reconcile. Snapshot isolation is what makes multi-query reports add up.
  * If you want FRESH data, do not wrap reads in a transaction. With autocommit
    on, every statement gets its own new snapshot.
  * If you want CONSISTENT data across several queries, DO wrap them -- and
    accept the staleness deliberately rather than discovering it later.

  The choice is yours to make explicitly. Most "the numbers were wrong" tickets
  are somebody making it by accident.
*/


-- ============================================================================
-- DEMO 6: TRUNCATE COMMITS. IT WILL SURPRISE YOU.
-- ============================================================================
-- TRUNCATE takes an AccessExclusiveLock AND issues an implicit COMMIT.
-- That means it ends your transaction early, releases every lock you held, and
-- makes everything you had done so far permanent -- whether you wanted that or
-- not.

-- A1  SESSION A:
BEGIN;
INSERT INTO lock_ledger VALUES (99, 1, 42.00, 'work I intend to roll back');

SELECT COUNT(*) FROM lock_ledger WHERE entry_id = 99;   -- 1, uncommitted so far

-- A2  SESSION A: truncate a DIFFERENT table -- this still commits everything
TRUNCATE TABLE lock_ledger;
-- ^ implicit COMMIT fires here. The transaction that began at A1 is now over.

-- A3  SESSION A: try to undo
ROLLBACK;
-- No error, but nothing is undone -- there is no open transaction to roll back.

-- A4  Confirm the damage:
SELECT COUNT(*) FROM lock_ledger;
-- 0 rows. The TRUNCATE is permanent, AND the INSERT at A1 was committed by it
-- before the table was emptied. Neither is recoverable.

-- Rebuild for the remaining demos:
INSERT INTO lock_ledger (entry_id, account_id, amount, entry_note) VALUES
    (1, 1, 1000.00, 'opening balance'),
    (2, 2,  500.00, 'opening balance'),
    (3, 3,  750.00, 'opening balance'),
    (4, 4, 2000.00, 'opening balance');

/*
CONSEQUENCES WORTH KNOWING
  * TRUNCATE inside a stored procedure ends that procedure's transaction. Any
    "atomic" guarantee you thought the procedure had is gone from that point.
  * A procedure containing TRUNCATE cannot be CALLed from inside an explicit
    transaction block -- Redshift raises
        "TRUNCATE cannot be invoked from a procedure that is executing in an
         atomic context"
  * If you need emptiness AND rollback, use DELETE. It is slower and leaves
    ghost rows for VACUUM, but it is transactional.
*/


-- ============================================================================
-- DEMO 7: SERIALIZABLE ISOLATION AND ERROR 1023
-- ============================================================================
-- Redshift also offers SERIALIZABLE isolation. Under it, if two concurrent
-- transactions read and write the same table in a way that could not have
-- happened in ANY serial order, Redshift aborts one of them:
--
--    ERROR: 1023
--    DETAIL: Serializable isolation violation on table ...
--
-- This is not a lock. Nobody blocks. One transaction simply loses at commit
-- time and must be RETRIED.

-- Set the level for the session (do this in BOTH tabs before the demo):
-- SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- A1  SESSION A:
BEGIN;
SELECT SUM(balance) FROM lock_accounts;              -- read the whole table
INSERT INTO lock_ledger VALUES (101, 1, 1.00, 'from session A');

-- B1  SESSION B: interleaved read + write on the same pair of tables
BEGIN;
SELECT SUM(balance) FROM lock_accounts;
INSERT INTO lock_ledger VALUES (102, 2, 2.00, 'from session B');

-- A2  SESSION A:
COMMIT;                                              -- succeeds

-- B2  SESSION B:
COMMIT;
-- May fail with: ERROR: 1023 Serializable isolation violation on table lock_ledger

/*
HOW TO SURVIVE 1023 IN PRODUCTION
  1. RETRY. It is a transient, expected outcome, not a bug. Wrap the whole
     transaction in application-level retry with a short backoff. Practice 82,
     "design every operation to be retry-safe", exists mostly for this.
  2. SHORTEN transactions. The smaller the window, the smaller the chance of
     overlap.
  3. STOP MIXING reads and writes of the same table inside one long transaction.
  4. STAY ON SNAPSHOT unless you have a specific reason not to. It is the
     default precisely because it avoids this class of failure.

  Lock conflicts (as opposed to isolation violations) are logged here:
*/
SELECT * FROM stl_tr_conflict ORDER BY xact_start_ts DESC LIMIT 10;


-- ============================================================================
-- DEMO 8: DEADLOCK — TWO SESSIONS, TWO TABLES, OPPOSITE ORDER
-- ============================================================================
-- A deadlock needs two tables and two sessions that grab them in opposite
-- orders. Redshift detects the cycle and kills one of them automatically.

-- A1  SESSION A: take lock_accounts first
BEGIN;
UPDATE lock_accounts SET balance = balance + 1 WHERE account_id = 3;

-- B1  SESSION B: take lock_ledger first  (the OPPOSITE order)
BEGIN;
UPDATE lock_ledger SET amount = amount + 1 WHERE entry_id = 3;

-- A2  SESSION A: [BLOCKS] now wants lock_ledger, which B holds
UPDATE lock_ledger SET amount = amount + 1 WHERE entry_id = 4;

-- B2  SESSION B: [DEADLOCK] now wants lock_accounts, which A holds
UPDATE lock_accounts SET balance = balance + 1 WHERE account_id = 4;
/*
 One of the two sessions is chosen as the victim and aborted:
   ERROR: deadlock detected
   DETAIL: Process NNN waits for ExclusiveLock on ...; blocked by process MMM.
 The survivor proceeds. The victim must retry its whole transaction.
*/

-- Clean up whichever survived:
ROLLBACK;    -- in BOTH sessions

/*
THE FIX IS ALWAYS THE SAME: A CONSISTENT LOCK ORDER.
  Agree an order for your tables -- alphabetical is fine, as long as everyone
  follows it -- and have every job take them in that order. A deadlock is
  impossible when nobody ever holds B while waiting for A.
  Demo 9 shows how to enforce that up front.
*/


-- ============================================================================
-- DEMO 9: LOCK TABLE — TAKING LOCKS DELIBERATELY, UP FRONT
-- ============================================================================
-- LOCK acquires an AccessExclusiveLock immediately, before you touch any data.
-- Redshift's LOCK takes no mode argument: it is always ACCESS EXCLUSIVE.
--
-- Two legitimate uses:
--   1. Grab every table you will need, in a fixed order, so deadlock is
--      impossible (Demo 8's fix).
--   2. Fail FAST. If you cannot get the lock now, you would rather know at the
--      start of a two-hour job than ninety minutes in.

-- A1  SESSION A: declare your intentions before doing any work
BEGIN;
LOCK lock_accounts, lock_ledger;      -- both, in one statement, one order

-- A2  SESSION A: now do the work. Nothing can interleave.
UPDATE lock_accounts SET balance = balance - 100 WHERE account_id = 1;
INSERT INTO lock_ledger VALUES (201, 1, -100.00, 'transfer out');
UPDATE lock_accounts SET balance = balance + 100 WHERE account_id = 2;
INSERT INTO lock_ledger VALUES (202, 2,  100.00, 'transfer in');

-- B1  SESSION B: [BLOCKS] even a SELECT waits — AccessExclusive blocks all
SELECT * FROM lock_accounts;

-- A3  SESSION A:
COMMIT;      -- B1 unblocks

/*
THE TRADE-OFF, STATED PLAINLY
  LOCK TABLE is a sledgehammer. It blocks readers as well as writers, so it
  turns a normally invisible write into a visible outage for anyone querying
  that table. Use it for short, critical, multi-table consistency windows --
  a transfer, a publish, a swap -- and never around anything slow.

  For most ETL you do NOT want this. You want the opposite: stage in a private
  table where nobody contends with you, then publish in one fast statement.
*/


-- ============================================================================
-- DEMO 10: GUARDRAILS — DO NOT WAIT FOREVER
-- ============================================================================
-- By default a blocked statement waits indefinitely. In a pipeline that means a
-- job hangs all night and you find out from the morning dashboards.

-- Set a ceiling on how long any statement will wait (milliseconds):
SET statement_timeout = 30000;         -- 30 seconds

-- Prove it. With SESSION A holding an open write transaction on lock_accounts:
-- A1  SESSION A:
BEGIN;
UPDATE lock_accounts SET balance = balance + 1 WHERE account_id = 1;

-- B1  SESSION B: waits 30 seconds, then gives up cleanly instead of hanging
SET statement_timeout = 30000;
BEGIN;
UPDATE lock_accounts SET balance = balance + 2 WHERE account_id = 2;
-- ERROR: canceling statement due to statement timeout

-- A2  SESSION A:
ROLLBACK;
-- B2  SESSION B:
ROLLBACK;

-- Reset to no limit for the rest of your session:
SET statement_timeout = 0;

/*
WHERE TO PUT THIS
  * At the top of every ETL procedure that touches a shared table.
  * In the WLM queue configuration, so it applies estate-wide without relying on
    each developer remembering.
  A job that fails at 30 seconds with a clear timeout is infinitely easier to
  operate than one that hangs until somebody notices.
*/


-- ============================================================================
-- DEMO 11: MERGE AND LOCKING
-- ============================================================================
-- MERGE reads and writes the target in one statement, so it holds a write-level
-- lock on the target for the whole statement -- and, if you are inside an
-- explicit transaction, for the whole transaction.

DROP TABLE IF EXISTS lock_staging CASCADE;
CREATE TABLE lock_staging (
    account_id INT           NOT NULL,
    balance    DECIMAL(12,2) NOT NULL
) DISTSTYLE ALL;

INSERT INTO lock_staging VALUES (1, 1111.00), (2, 2222.00), (5, 5555.00);

-- A1  SESSION A:
BEGIN;
MERGE INTO lock_accounts
USING lock_staging AS s
ON lock_accounts.account_id = s.account_id
WHEN MATCHED THEN UPDATE SET balance = s.balance
WHEN NOT MATCHED THEN INSERT (account_id, owner_name, balance)
                      VALUES (s.account_id, 'New Account', s.balance);

-- B1  SESSION B: reads are STILL fine — no block, old values
SELECT account_id, balance FROM lock_accounts ORDER BY account_id;

-- B2  SESSION B: [BLOCKS] another writer on the same target must wait
BEGIN;
UPDATE lock_accounts SET balance = 0 WHERE account_id = 3;

-- A2  SESSION A:
COMMIT;      -- B2 unblocks

-- B3  SESSION B:
ROLLBACK;

/*
PRACTICAL NOTES
  * Keep the source of a MERGE small and pre-deduplicated. The longer the MERGE
    runs, the longer every other writer on that target waits.
  * Redshift's MERGE grammar takes NO alias on the target and has NO
    "WHEN MATCHED AND <condition>" clause -- see module 52.1 and module 73.
  * A MERGE inside a long transaction with other statements holds the target for
    all of it. Put the MERGE last, or give it its own transaction.
*/


-- ============================================================================
-- SECTION 9: THE TRIAGE TOOLKIT — WHEN SOMETHING IS STUCK RIGHT NOW
-- ============================================================================
-- Run these from a THIRD session while the other two are tangled.
-- Module 44 has the full DBA runbook; this is the short version.

-- (1) WHO IS BLOCKED, AND WHO IS BLOCKING THEM?
--     SVV_TRANSACTIONS is the view AWS points at for lock contention, and the
--     only one carrying lock_mode / txn_start / relation / granted.
--     (STV_LOCKS has just table_id, lock_owner, lock_owner_pid, lock_status --
--      and is superuser-only.)
SELECT
    t.pid,
    t.txn_owner,
    t.txn_db,
    t.granted,                  -- f = WAITING. These are your victims.
    t.lock_mode,
    t.lockable_object_type,
    c.relname                       AS table_name,
    t.txn_start,
    DATEDIFF(second, t.txn_start, GETDATE()) AS txn_age_seconds
FROM svv_transactions t
LEFT JOIN pg_class c ON c.oid = t.relation   -- LEFT: relation is NULL for txn locks
ORDER BY t.granted, t.txn_start;

-- (2) THE OLDEST OPEN TRANSACTION — nine times out of ten, this is the culprit
SELECT
    pid,
    txn_owner,
    txn_start,
    DATEDIFF(minute, txn_start, GETDATE()) AS open_for_minutes
FROM svv_transactions
GROUP BY pid, txn_owner, txn_start
ORDER BY txn_start
LIMIT 5;

-- (3) WHAT IS THAT SESSION ACTUALLY DOING?
SELECT pid, user_name, starttime, LEFT(query, 200) AS current_query
FROM stv_recents
WHERE status = 'Running'
ORDER BY starttime;

-- (4) KILL IT. Last resort -- this rolls back all of that session's work.
--     Take the pid from query (1) where granted = t and the age is absurd.
-- SELECT pg_terminate_backend(<pid>);

-- (5) AFTERWARDS: what conflicted, historically?
SELECT * FROM stl_tr_conflict ORDER BY xact_start_ts DESC LIMIT 20;


-- ============================================================================
-- SECTION 10: SUMMARY
-- ============================================================================
/*
┌──────────────────────┬───────────────────────────┬────────────────────────────┐
│ You run…             │ You take…                 │ You block…                 │
├──────────────────────┼───────────────────────────┼────────────────────────────┤
│ SELECT / UNLOAD      │ AccessShareLock           │ only DDL                   │
│ INSERT / UPDATE      │ ShareRowExclusiveLock     │ other writers + DDL        │
│ DELETE / COPY / MERGE│ ShareRowExclusiveLock     │ other writers + DDL        │
│ ALTER / DROP / VACUUM│ AccessExclusiveLock       │ EVERYONE, readers included │
│ TRUNCATE             │ AccessExclusiveLock       │ EVERYONE — and it COMMITS  │
│ LOCK <table>         │ AccessExclusiveLock       │ EVERYONE, deliberately     │
└──────────────────────┴───────────────────────────┴────────────────────────────┘

THE SIX THINGS TO REMEMBER
  1. Redshift locks TABLES, not rows. Two writers on one table serialise even
     when they touch different rows.
  2. Locks are held until COMMIT or ROLLBACK, not until the statement ends.
     BEGIN is where every locking incident starts.
  3. Readers are almost never blocked, and almost never block. Only DDL fights
     everybody.
  4. A reader inside an open transaction sees the snapshot from when the
     transaction STARTED. Consistent, but increasingly stale, silently.
  5. TRUNCATE commits. It ends your transaction and makes prior work permanent.
  6. A blocked DDL queues new readers behind ITSELF. One idle BEGIN plus one
     ALTER TABLE is an estate-wide outage.

DESIGN RULES THAT FOLLOW
  * Keep write transactions short. Batch with periodic COMMIT (module 35).
  * Stage in a private table, publish in one fast statement. Never have two
    jobs contend for one target.
  * Set statement_timeout on anything touching a shared table.
  * Take multi-table locks in a consistent order, or LOCK them all up front.
  * Run DDL in a maintenance window, after checking SVV_TRANSACTIONS.
  * Make every write retry-safe. Under SERIALIZABLE, 1023 is expected, not
    exceptional.

RELATED MODULES
  44    the DBA triage runbook and the lock-incident log table
  35    batching large loads with periodic COMMIT
  22    transaction blocks, rollback, and why Redshift has no SAVEPOINTs
  52.1  join algorithms — what the query does once it HAS the data
  73    SCD patterns, and why the MERGE grammar is narrower than you expect
*/


-- ============================================================================
-- CLEANUP
-- ============================================================================
-- Run in EVERY session you opened, first, to make sure nothing is left open:
-- ROLLBACK;
-- SET statement_timeout = 0;
--
-- DROP TABLE IF EXISTS lock_accounts CASCADE;
-- DROP TABLE IF EXISTS lock_ledger CASCADE;
-- DROP TABLE IF EXISTS lock_staging CASCADE;
