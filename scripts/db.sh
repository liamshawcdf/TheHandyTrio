#!/usr/bin/env bash
set -e
if docker ps -a --format '{{.Names}}' | grep -q '^handytrio-db$'; then
  docker start handytrio-db >/dev/null
else
  docker run -d --name handytrio-db \
    -e POSTGRES_USER=handy -e POSTGRES_PASSWORD=handy -e POSTGRES_DB=handytrio \
    -p 5433:5432 -v handytrio-data:/var/lib/postgresql/data postgres:16 >/dev/null
fi
echo "Waiting for database..."
until docker exec handytrio-db pg_isready -U handy -d handytrio >/dev/null 2>&1; do sleep 1; done
echo "Database ready"
