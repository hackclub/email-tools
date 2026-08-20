#!/bin/bash
set -e

# Remove a potentially pre-existing server.pid for Rails.
rm -f /app/tmp/pids/server.pid

# Wait for PostgreSQL to be ready (TCP check to avoid requiring credentials)
# Prefer DATABASE_URL for connectivity hints; fall back to DB_HOST/DB_PORT
if [ -n "${DATABASE_URL}" ]; then
  DB_HOST_FROM_URL=$(ruby -e "require 'uri'; u = URI(ENV['DATABASE_URL']); puts(u.host || '')" 2>/dev/null)
  DB_PORT_FROM_URL=$(ruby -e "require 'uri'; u = URI(ENV['DATABASE_URL']); puts(u.port || 5432)" 2>/dev/null)
fi
DB_HOST=${DB_HOST:-${DB_HOST_FROM_URL:-db}}
DB_PORT=${DB_PORT:-${DB_PORT_FROM_URL:-5432}}
echo "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
until nc -z "$DB_HOST" "$DB_PORT" 2>/dev/null; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 1
done
echo "PostgreSQL is up - continuing"

# Wait for Redis to be ready (using nc if redis-cli is not available)
echo "Waiting for Redis..."
# Prefer REDIS_URL for connectivity hints; fall back to redis:6379
if [ -n "${REDIS_URL}" ]; then
  REDIS_HOST_FROM_URL=$(ruby -e "require 'uri'; u = URI(ENV['REDIS_URL']); puts(u.host || '')" 2>/dev/null)
  REDIS_PORT_FROM_URL=$(ruby -e "require 'uri'; u = URI(ENV['REDIS_URL']); puts(u.port || 6379)" 2>/dev/null)
fi
REDIS_HOST=${REDIS_HOST:-${REDIS_HOST_FROM_URL:-redis}}
REDIS_PORT=${REDIS_PORT:-${REDIS_PORT_FROM_URL:-6379}}
until nc -z "$REDIS_HOST" "$REDIS_PORT" 2>/dev/null; do
  echo "Redis is unavailable - sleeping"
  sleep 1
done
echo "Redis is up - continuing"

# Ensure gems are installed (useful when volumes are mounted)
if [ -f /app/Gemfile ]; then
  echo "Checking bundle..."
  bundle check || bundle install
fi

# db:prepare acquires an advisory lock, so concurrent containers safely serialize.
echo "Running rails db:prepare..."
bundle exec rails db:prepare

# Then exec the container's main process (what's set as CMD in the Dockerfile).
exec "$@"

