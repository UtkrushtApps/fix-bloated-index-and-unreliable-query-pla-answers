-- =============================================================
-- Dispatch Platform Database
-- Optimized implementation for high-churn dispatch workload.
--
-- Key fixes applied:
--   1) Replace broad courier_assignments indexes with a partial
--      hot-path index only for state = 'searching'.
--   2) Remove redundant single-column and broad composite indexes.
--   3) Tune autovacuum and statistics for the churn-heavy table.
--   4) Add the missing courier_locations(courier_id) join index.
--   5) Use RANGE partitioning on historical_assignments by created_at
--      so time pruning and partition retirement are cheap.
--   6) Run maintenance (reindex + vacuum analyze) after churn simulation.
--
-- Note:
--   This bootstrap script uses regular CREATE/DROP INDEX and REINDEX
--   because it runs on an isolated fresh instance. In production,
--   prefer CREATE INDEX CONCURRENTLY / DROP INDEX CONCURRENTLY and
--   REINDEX ... CONCURRENTLY during controlled maintenance.
-- =============================================================

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ------------------------------------
-- Lookup Tables
-- ------------------------------------
CREATE TABLE cities (
  id          SERIAL PRIMARY KEY,
  name        VARCHAR(100) NOT NULL,
  country     VARCHAR(60)  NOT NULL,
  timezone    VARCHAR(60)  NOT NULL DEFAULT 'UTC',
  is_active   BOOLEAN      NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE restaurants (
  id            SERIAL PRIMARY KEY,
  city_id       INT          NOT NULL REFERENCES cities(id),
  name          VARCHAR(150) NOT NULL,
  address       TEXT,
  cuisine_type  VARCHAR(80),
  rating        NUMERIC(3,2),
  is_active     BOOLEAN      NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE couriers (
  id              SERIAL PRIMARY KEY,
  city_id         INT          NOT NULL REFERENCES cities(id),
  full_name       VARCHAR(150) NOT NULL,
  phone           VARCHAR(30),
  vehicle_type    VARCHAR(30)  NOT NULL DEFAULT 'bicycle',
  is_active       BOOLEAN      NOT NULL DEFAULT true,
  onboarded_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id              BIGSERIAL    PRIMARY KEY,
  restaurant_id   INT          NOT NULL REFERENCES restaurants(id),
  city_id         INT          NOT NULL REFERENCES cities(id),
  customer_ref    VARCHAR(60)  NOT NULL,
  total_amount    NUMERIC(10,2),
  status          VARCHAR(30)  NOT NULL DEFAULT 'placed',
  placed_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ------------------------------------
-- Core High-Churn Table
-- ------------------------------------
CREATE TABLE courier_assignments (
  id              BIGSERIAL    PRIMARY KEY,
  order_id        BIGINT       NOT NULL REFERENCES orders(id),
  courier_id      INT          REFERENCES couriers(id),
  city_id         INT          NOT NULL REFERENCES cities(id),
  state           VARCHAR(30)  NOT NULL DEFAULT 'searching',
  scheduled_for   TIMESTAMPTZ  NOT NULL,
  offered_at      TIMESTAMPTZ,
  accepted_at     TIMESTAMPTZ,
  completed_at    TIMESTAMPTZ,
  cancelled_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
) WITH (
  fillfactor = 90,
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_analyze_scale_factor = 0.005,
  autovacuum_analyze_threshold = 500
);

-- Legacy indexes are created first so the dataset reflects the inherited
-- anti-pattern before the remediation section replaces them.
CREATE INDEX idx_assignments_state_city_sched
  ON courier_assignments (state, city_id, scheduled_for);

CREATE INDEX idx_assignments_city_id
  ON courier_assignments (city_id);

CREATE INDEX idx_assignments_state
  ON courier_assignments (state);

-- ------------------------------------
-- Courier Location Table
-- ------------------------------------
CREATE TABLE courier_locations (
  id           BIGSERIAL   PRIMARY KEY,
  courier_id   INT         NOT NULL REFERENCES couriers(id),
  last_lat     NUMERIC(9,6),
  last_lon     NUMERIC(9,6),
  recorded_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ------------------------------------
-- Historical Archive Table
-- Corrected to RANGE partitioning on created_at.
-- Monthly partitions make pruning and retention drops cheap.
-- ------------------------------------
CREATE TABLE historical_assignments (
  id              BIGINT       NOT NULL,
  order_id        BIGINT       NOT NULL,
  courier_id      INT,
  city_id         INT          NOT NULL,
  state           VARCHAR(30)  NOT NULL,
  scheduled_for   TIMESTAMPTZ  NOT NULL,
  created_at      TIMESTAMPTZ  NOT NULL,
  archived_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);

DO $$
DECLARE
  partition_start DATE := (date_trunc('month', now()) - interval '12 months')::date;
  partition_end   DATE := (date_trunc('month', now()) + interval '2 months')::date;
BEGIN
  WHILE partition_start < partition_end LOOP
    EXECUTE format(
      'CREATE TABLE %I PARTITION OF historical_assignments FOR VALUES FROM (%L) TO (%L);',
      'historical_assignments_' || to_char(partition_start, 'YYYYMM'),
      partition_start::timestamptz,
      (partition_start + interval '1 month')::date::timestamptz
    );

    partition_start := (partition_start + interval '1 month')::date;
  END LOOP;
END $$;

CREATE INDEX idx_hist_created_at
  ON historical_assignments (created_at);

CREATE INDEX idx_hist_city_state_created_at
  ON historical_assignments (city_id, state, created_at);

-- =============================================================
-- DATA POPULATION
-- =============================================================

-- Cities
INSERT INTO cities (name, country, timezone) VALUES
  ('Mumbai',    'India', 'Asia/Kolkata'),
  ('Delhi',     'India', 'Asia/Kolkata'),
  ('Bangalore', 'India', 'Asia/Kolkata'),
  ('Hyderabad', 'India', 'Asia/Kolkata'),
  ('Chennai',   'India', 'Asia/Kolkata'),
  ('Pune',      'India', 'Asia/Kolkata'),
  ('Kolkata',   'India', 'Asia/Kolkata'),
  ('Ahmedabad', 'India', 'Asia/Kolkata');

-- Restaurants (200 rows)
INSERT INTO restaurants (city_id, name, cuisine_type, rating, is_active)
SELECT
  (random() * 7 + 1)::int,
  'Restaurant_' || i,
  (ARRAY['Indian','Chinese','Italian','Mexican','Thai','Japanese'])[ceil(random() * 6)::int],
  round((3.0 + random() * 2.0)::numeric, 2),
  true
FROM generate_series(1, 200) i;

-- Couriers (2,000 rows)
INSERT INTO couriers (city_id, full_name, vehicle_type, is_active)
SELECT
  (random() * 7 + 1)::int,
  'Courier_' || i,
  (ARRAY['bicycle','motorcycle','car','scooter'])[ceil(random() * 4)::int],
  true
FROM generate_series(1, 2000) i;

-- Orders (80,000 rows)
INSERT INTO orders (restaurant_id, city_id, customer_ref, total_amount, status, placed_at)
SELECT
  (random() * 199 + 1)::int,
  (random() * 7 + 1)::int,
  'CUST-' || (random() * 50000 + 1)::int,
  round((50 + random() * 950)::numeric, 2),
  (ARRAY['placed','confirmed','preparing','picked_up','delivered','cancelled'])[ceil(random() * 6)::int],
  now() - (random() * interval '90 days')
FROM generate_series(1, 80000);

-- courier_assignments: 300,000 rows
-- searching ~3% of rows and is the hot operational state.
INSERT INTO courier_assignments
  (order_id, courier_id, city_id, state, scheduled_for, offered_at, accepted_at, completed_at, cancelled_at, created_at, updated_at)
SELECT
  ((random() * 79999)::int + 1),
  CASE WHEN random() > 0.15 THEN ((random() * 1999)::int + 1) ELSE NULL END,
  (random() * 7 + 1)::int,
  CASE
    WHEN rnd < 0.03 THEN 'searching'
    WHEN rnd < 0.08 THEN 'offered'
    WHEN rnd < 0.18 THEN 'accepted'
    WHEN rnd < 0.90 THEN 'completed'
    WHEN rnd < 0.97 THEN 'cancelled'
    ELSE                'expired'
  END,
  now() - (random() * interval '30 days') + (random() * interval '2 hours'),
  CASE WHEN rnd >= 0.03 THEN now() - (random() * interval '28 days') ELSE NULL END,
  CASE WHEN rnd >= 0.08 THEN now() - (random() * interval '27 days') ELSE NULL END,
  CASE WHEN rnd >= 0.18 AND rnd < 0.90 THEN now() - (random() * interval '26 days') ELSE NULL END,
  CASE WHEN rnd >= 0.90 AND rnd < 0.97 THEN now() - (random() * interval '26 days') ELSE NULL END,
  now() - (random() * interval '30 days'),
  now() - (random() * interval '5 days')
FROM (
  SELECT random() AS rnd FROM generate_series(1, 300000)
) sub;

-- courier_locations: one latest location row per active courier
INSERT INTO courier_locations (courier_id, last_lat, last_lon, recorded_at)
SELECT
  id,
  18.5 + random() * 10,
  72.8 + random() * 10,
  now() - (random() * interval '1 hour')
FROM couriers
WHERE is_active = true;

-- historical_assignments: 400,000 rows spanning 12 months
INSERT INTO historical_assignments
  (id, order_id, courier_id, city_id, state, scheduled_for, created_at, archived_at)
SELECT
  i,
  ((random() * 79999)::int + 1),
  ((random() * 1999)::int + 1),
  (random() * 7 + 1)::int,
  (ARRAY['completed','cancelled','expired'])[ceil(random() * 3)::int],
  now() - (random() * interval '365 days'),
  now() - (random() * interval '365 days'),
  now() - (random() * interval '30 days')
FROM generate_series(1, 400000) i;

-- Simulate post-peak churn and dead tuples on courier_assignments.
UPDATE courier_assignments
   SET updated_at = now(), state = 'offered'
 WHERE state = 'searching'
   AND city_id IN (1, 2, 3)
   AND id % 2 = 0;

UPDATE courier_assignments
   SET updated_at = now(), state = 'accepted'
 WHERE state = 'offered'
   AND city_id IN (1, 2, 3)
   AND id % 3 = 0;

UPDATE courier_assignments
   SET updated_at = now(), state = 'completed'
 WHERE state = 'accepted'
   AND city_id IN (1, 2, 3)
   AND id % 4 = 0;

-- Deliberately weak stats before remediation, mirroring the unstable planner state.
ALTER TABLE courier_assignments ALTER COLUMN state SET STATISTICS 10;
ANALYZE courier_assignments;
ANALYZE courier_locations;
ANALYZE historical_assignments;

-- =============================================================
-- REMEDIATION
-- =============================================================

-- 1) Create the selective partial index that matches the hot ops query.
CREATE INDEX idx_assignments_searching_city_sched
  ON courier_assignments (city_id, scheduled_for, id)
  INCLUDE (order_id, courier_id)
  WHERE state = 'searching';

-- 2) Add the missing join index on courier_locations.
CREATE INDEX idx_courier_locations_courier_id
  ON courier_locations (courier_id)
  INCLUDE (last_lat, last_lon, recorded_at);

-- 3) Remove broad, redundant indexes that add write amplification and bloat.
DROP INDEX IF EXISTS idx_assignments_state_city_sched;
DROP INDEX IF EXISTS idx_assignments_city_id;
DROP INDEX IF EXISTS idx_assignments_state;

-- 4) Improve planner selectivity estimates for the hot predicate columns.
ALTER TABLE courier_assignments ALTER COLUMN state SET STATISTICS 500;
ALTER TABLE courier_assignments ALTER COLUMN city_id SET STATISTICS 500;
ALTER TABLE courier_assignments ALTER COLUMN scheduled_for SET STATISTICS 500;

CREATE STATISTICS st_courier_assignments_city_state (mcv)
  ON city_id, state
  FROM courier_assignments;

-- 5) Maintenance to clean up post-churn bloat and refresh stats.
REINDEX TABLE courier_assignments;
VACUUM (ANALYZE) courier_assignments;
VACUUM (ANALYZE) courier_locations;
VACUUM (ANALYZE) historical_assignments;
