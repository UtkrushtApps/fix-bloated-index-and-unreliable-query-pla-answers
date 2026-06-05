-- =============================================================
-- Sample Queries Demonstrating the Optimized Design
-- Run these with EXPLAIN (ANALYZE, BUFFERS) after startup.
-- =============================================================

-- ----------------------------------------------------
-- QUERY 1: Ops Unassigned Dashboard — City 3
-- Expected after optimization:
--   * Index Scan using idx_assignments_searching_city_sched
--   * No broad Seq Scan on courier_assignments
--   * No explicit Sort for the LIMIT path
--   * Indexed join into courier_locations by courier_id
-- ----------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
  ca.id,
  ca.order_id,
  ca.city_id,
  ca.scheduled_for,
  ca.state,
  cl.last_lat,
  cl.last_lon
FROM courier_assignments ca
LEFT JOIN courier_locations cl ON cl.courier_id = ca.courier_id
WHERE ca.city_id = 3
  AND ca.state = 'searching'
  AND ca.scheduled_for <= now()
ORDER BY ca.scheduled_for
LIMIT 200;

-- ----------------------------------------------------
-- QUERY 2: Same ops query, different city
-- Expected: same selective partial-index access path,
-- yielding stable low-latency plans across sessions.
-- ----------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
  ca.id,
  ca.order_id,
  ca.scheduled_for,
  ca.state
FROM courier_assignments ca
WHERE ca.city_id = 1
  AND ca.state = 'searching'
  AND ca.scheduled_for <= now()
ORDER BY ca.scheduled_for
LIMIT 200;

-- ----------------------------------------------------
-- QUERY 3: Historical assignments time-range report
-- Expected after optimization:
--   * RANGE partition pruning on created_at
--   * Only matching month partitions scanned
--   * No append across every archive partition
-- ----------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT
  city_id,
  state,
  COUNT(*) AS total,
  MIN(created_at) AS earliest,
  MAX(created_at) AS latest
FROM historical_assignments
WHERE created_at >= date_trunc('month', now()) - interval '3 months'
  AND created_at < date_trunc('month', now())
GROUP BY city_id, state
ORDER BY city_id, state;

-- ----------------------------------------------------
-- QUERY 4: Retention management for historical data
-- With RANGE partitioning, do not delete row-by-row.
-- Instead detach/drop old monthly partitions.
-- This query lists the partitions older than 90 days and
-- generates the DDL you can run during retention windows.
-- ----------------------------------------------------
WITH retention_cutoff AS (
  SELECT to_char(date_trunc('month', now()) - interval '3 months', 'YYYYMM') AS cutoff_yyyymm
)
SELECT
  child.relname AS droppable_partition,
  pg_size_pretty(pg_relation_size(child.oid)) AS partition_size,
  format(
    'ALTER TABLE historical_assignments DETACH PARTITION %I; DROP TABLE %I;',
    child.relname,
    child.relname
  ) AS retention_ddl
FROM pg_inherits i
JOIN pg_class parent ON parent.oid = i.inhparent
JOIN pg_class child  ON child.oid = i.inhrelid
CROSS JOIN retention_cutoff rc
WHERE parent.relname = 'historical_assignments'
  AND child.relname ~ '^historical_assignments_[0-9]{6}$'
  AND right(child.relname, 6) < rc.cutoff_yyyymm
ORDER BY child.relname;

-- ----------------------------------------------------
-- QUERY 5: Index size and usage analysis
-- Expected: only the PK plus the selective partial index
-- should remain on courier_assignments.
-- ----------------------------------------------------
SELECT
  i.relname                               AS index_name,
  pg_size_pretty(pg_relation_size(i.oid)) AS index_size,
  s.idx_scan                              AS scans,
  s.idx_tup_read                          AS tuples_read,
  s.idx_tup_fetch                         AS tuples_fetched,
  pg_get_indexdef(i.oid)                  AS definition
FROM pg_index ix
JOIN pg_class t  ON t.oid = ix.indrelid
JOIN pg_class i  ON i.oid = ix.indexrelid
JOIN pg_stat_all_indexes s ON s.indexrelid = ix.indexrelid
WHERE t.relname = 'courier_assignments'
ORDER BY pg_relation_size(i.oid) DESC;

-- ----------------------------------------------------
-- QUERY 6: Dead tuple and autovacuum status
-- Expected: low dead tuples after remediation and tuned
-- reloptions on courier_assignments.
-- ----------------------------------------------------
SELECT
  s.relname,
  s.n_live_tup,
  s.n_dead_tup,
  ROUND(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 2) AS dead_pct,
  s.last_vacuum,
  s.last_autovacuum,
  s.last_analyze,
  s.last_autoanalyze,
  s.autovacuum_count,
  c.reloptions
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
WHERE s.relname IN ('courier_assignments', 'courier_locations', 'historical_assignments')
ORDER BY s.n_dead_tup DESC;

-- ----------------------------------------------------
-- QUERY 7: Partition structure inspection
-- Expected: strategy = range and monthly bounds visible.
-- ----------------------------------------------------
SELECT
  pt.relname AS parent_table,
  CASE pp.partstrat
    WHEN 'r' THEN 'range'
    WHEN 'l' THEN 'list'
    WHEN 'h' THEN 'hash'
  END AS strategy,
  c.relname AS partition_name,
  pg_get_expr(c.relpartbound, c.oid) AS bounds,
  pg_size_pretty(pg_relation_size(c.oid)) AS partition_size
FROM pg_partitioned_table pp
JOIN pg_class pt ON pt.oid = pp.partrelid
JOIN pg_inherits i ON i.inhparent = pp.partrelid
JOIN pg_class c ON c.oid = i.inhrelid
WHERE pt.relname = 'historical_assignments'
ORDER BY c.relname;
