#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

compose() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    docker compose "$@"
  fi
}

echo "========================================="
echo " Dispatch DB — Starting Infrastructure"
echo "========================================="

echo "[1/5] Creating data directory for PostgreSQL volume..."
mkdir -p ./data/pgdata

echo "[2/5] Starting Docker containers..."
compose up -d

echo "[3/5] Waiting for PostgreSQL to be ready..."
MAX_ATTEMPTS=60
ATTEMPT=0
until docker exec dispatch_postgres pg_isready -U dispatch_user -d dispatch_db -q 2>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]; then
    echo "ERROR: PostgreSQL did not become ready within expected time."
    echo "Check container logs: docker logs dispatch_postgres"
    exit 1
  fi
  echo "  Waiting for PostgreSQL... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
  sleep 3
done

echo "[4/5] Validating optimized schema..."
TABLE_COUNT=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';")
PARTIAL_INDEX=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'courier_assignments' AND indexname = 'idx_assignments_searching_city_sched';")
LEGACY_INDEXES=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'courier_assignments' AND indexname IN ('idx_assignments_state_city_sched', 'idx_assignments_city_id', 'idx_assignments_state');")
LOCATION_INDEX=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'courier_locations' AND indexname = 'idx_courier_locations_courier_id';")
PARTITION_STRATEGY=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT pp.partstrat FROM pg_partitioned_table pp JOIN pg_class c ON c.oid = pp.partrelid WHERE c.relname = 'historical_assignments';")
PARTITION_COUNT=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -tAc \
  "SELECT COUNT(*) FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = 'historical_assignments';")

echo "  Tables found in public schema: $TABLE_COUNT"
echo "  Partial hot-path index present: $PARTIAL_INDEX"
echo "  Legacy courier_assignments indexes remaining: $LEGACY_INDEXES"
echo "  courier_locations join index present: $LOCATION_INDEX"
echo "  historical_assignments partition strategy: $PARTITION_STRATEGY"
echo "  historical_assignments partition count: $PARTITION_COUNT"

if [ "$PARTIAL_INDEX" != "1" ] || [ "$LEGACY_INDEXES" != "0" ] || [ "$LOCATION_INDEX" != "1" ] || [ "$PARTITION_STRATEGY" != "r" ]; then
  echo "ERROR: Optimization validation failed."
  echo "Inspect schema manually: docker exec -it dispatch_postgres psql -U dispatch_user -d dispatch_db"
  exit 1
fi

echo "[5/5] Capturing representative hot-query plan..."
HOT_PLAN=$(docker exec dispatch_postgres psql -U dispatch_user -d dispatch_db -Atqc "EXPLAIN (COSTS OFF) SELECT ca.id, ca.order_id, ca.city_id, ca.scheduled_for, ca.state FROM courier_assignments ca WHERE ca.city_id = 3 AND ca.state = 'searching' AND ca.scheduled_for <= now() ORDER BY ca.scheduled_for LIMIT 20;" | paste -sd ' ' -)
echo "  Plan snippet: $HOT_PLAN"

echo ""
echo "========================================="
echo " Deployment Complete!"
echo "========================================="
echo " Host:     localhost"
echo " Port:     5432"
echo " Database: dispatch_db"
echo " Username: dispatch_user"
echo " Password: dispatch_pass"
echo ""
echo " Connect: psql -h localhost -p 5432 -U dispatch_user -d dispatch_db"
echo "========================================="
