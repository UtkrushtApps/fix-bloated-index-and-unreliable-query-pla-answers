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
echo " Dispatch DB — Cleanup Starting"
echo "========================================="

echo "[1/5] Stopping and removing containers, volumes, and orphans..."
compose down --volumes --remove-orphans || true

echo "[2/5] Removing explicit PostgreSQL container if still present..."
docker rm -f dispatch_postgres >/dev/null 2>&1 || true

echo "[3/5] Removing PostgreSQL image..."
docker image rm -f postgres:15-alpine >/dev/null 2>&1 || true

echo "[4/5] Removing PostgreSQL data directory..."
rm -rf "$PROJECT_DIR/data/pgdata" || true

echo "[5/5] Final Docker cleanup pass..."
docker volume prune -f >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1 || true

echo ""
echo "========================================="
echo " Cleanup completed successfully!"
echo "========================================="
