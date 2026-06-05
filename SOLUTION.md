# Solution Steps

1. Review the hot /ops/unassigned query pattern and align the access path to its real predicates: city_id equality, state = 'searching', scheduled_for <= now(), ordered by scheduled_for with a small LIMIT.

2. On courier_assignments, replace the broad state/city/scheduled composite index with a selective partial index that only contains rows where state = 'searching'. Use keys ordered as (city_id, scheduled_for, id) and INCLUDE the extra projected columns needed by the endpoint.

3. Drop the redundant legacy indexes on courier_assignments (the broad composite index plus the standalone city_id and state indexes) so updates stop maintaining unnecessary structures and write amplification falls.

4. Add a join-friendly index on courier_locations(courier_id), optionally with INCLUDE columns for the projected location fields, so dispatch joins no longer need to scan the whole table.

5. Tune table-level storage and maintenance settings for courier_assignments: lower autovacuum vacuum/analyze scale factors, set practical thresholds, and use a lower fillfactor to leave space for churn-heavy updates.

6. Improve planner stability by raising statistics targets on the hot predicate columns and creating extended statistics for the city/state combination, then run ANALYZE so the planner has accurate selectivity data.

7. Apply production-safe maintenance to reduce churn-related bloat: in a live system use REINDEX CONCURRENTLY (or pg_repack where appropriate) plus VACUUM (ANALYZE); in bootstrap or offline maintenance windows, regular REINDEX and VACUUM are acceptable.

8. Correct the archive design by partitioning historical_assignments by RANGE(created_at) instead of HASH(id), create monthly partitions, and add time-oriented archive indexes so date filters prune partitions efficiently.

9. For retention, stop deleting old historical rows one-by-one; instead detach and drop whole range partitions older than the cutoff window, which keeps cleanup fast and avoids needless table/index bloat.

10. Validate the fix with EXPLAIN (ANALYZE, BUFFERS): the hot query should consistently use the partial index, courier_locations should join through its courier_id index, and archive reports should prune down to only the relevant time partitions.

