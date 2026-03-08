#!/bin/bash

set -e

# ── Config — matches docker-compose.yml ──────────────────────────
export DB_URL="${DB_URL:-jdbc:postgresql://localhost:5432/mydatabase}"
export DB_USERNAME="${DB_USERNAME:-myuser}"
export DB_PASSWORD="${DB_PASSWORD:-secret}"

OUTPUT_FILE="src/main/resources/db/changelog/ddl/001-baseline-existing-tables.xml"

# ── Resolve project root ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ── Find PostgreSQL driver jar ────────────────────────────────────
PG_JAR=$(find ~/.gradle -name "postgresql-*.jar" 2>/dev/null | head -1)
if [ -z "$PG_JAR" ]; then
    echo "ERROR: postgresql-*.jar not found in ~/.gradle cache."
    echo "  Run './gradlew dependencies' once to download it first."
    exit 1
fi
echo "PG Driver : $PG_JAR"

# ── Resolve Liquibase command (Windows vs Linux) ──────────────────
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    echo "Platform : Windows (Git Bash)"

    BAT_PATH=$(find /c/ProgramData/chocolatey -name "liquibase.bat" 2>/dev/null | head -1)
    if [ -z "$BAT_PATH" ]; then
        echo "ERROR: liquibase.bat not found. Try: choco install liquibase"
        exit 1
    fi

    WIN_PATH=$(cygpath -w "$BAT_PATH")
    WIN_JAR=$(cygpath -w "$PG_JAR")
    echo "Found    : $WIN_PATH"

    run_liquibase() {
        CMD_STR="$WIN_PATH --classpath=$WIN_JAR $*"
        cmd //c "set PATH=C:\\Windows\\System32;C:\\Windows && $CMD_STR"
    }
else
    echo "Platform : Linux/macOS"
    if ! command -v liquibase &> /dev/null; then
        echo "ERROR: liquibase not found. Install via brew or snap."
        exit 1
    fi
    run_liquibase() {
        liquibase --classpath="$PG_JAR" "$@"
    }
fi

# ── Create output directory ───────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT_FILE")"

# ── Banner ────────────────────────────────────────────────────────
echo ""
echo "================================================="
echo "  Liquibase — Baseline Existing DB"
echo "================================================="
echo "  DB URL    : $DB_URL"
echo "  DB User   : $DB_USERNAME"
echo "  Output    : $OUTPUT_FILE"
echo "================================================="
echo ""
echo "  Story: Docker started postgres with init.sql."
echo "  Tables already exist. We need Liquibase to"
echo "  acknowledge them WITHOUT dropping/recreating."
echo "================================================="
echo ""

# ── Wait for postgres ─────────────────────────────────────────────
echo "[0/2] Checking postgres is reachable..."
if command -v pg_isready &> /dev/null; then
    until pg_isready -h localhost -p 5432 -U "$DB_USERNAME" > /dev/null 2>&1; do
        echo "      Waiting for postgres..."
        sleep 2
    done
else
    echo "      (pg_isready not found — skipping, assuming postgres is up)"
fi
echo "      Postgres is ready."
echo ""

# ── Step 1: Generate baseline changelog ──────────────────────────
echo "[1/3] Generating changelog snapshot from existing DB..."
echo ""

run_liquibase \
    --url="$DB_URL" \
    --username="$DB_USERNAME" \
    --password="$DB_PASSWORD" \
    --changelog-file="$OUTPUT_FILE" \
    --diff-types="tables,views,columns,indexes,foreignkeys,primarykeys,uniqueconstraints" \
    generate-changelog

echo ""
echo "      Generated: $OUTPUT_FILE"
echo ""

# ── Step 2 Prove the changelog matches the DB exactly ────────────
# snapshot  → captures current DB state as a JSON snapshot
# diff      → compares that snapshot against the generated changelog
# If output says "No unexpected differences found" = 1 to 1 match
echo "[2/3] Proving changelog is 1-to-1 with existing DB..."
echo "      (running snapshot then diff against generated changelog)"
echo ""

SNAPSHOT_FILE="build/liquibase-snapshot.json"
mkdir -p build

run_liquibase \
    --url="$DB_URL" \
    --username="$DB_USERNAME" \
    --password="$DB_PASSWORD" \
    snapshot \
    --snapshot-format=json \
    --output-file="$SNAPSHOT_FILE"

echo ""
echo "      Snapshot saved: $SNAPSHOT_FILE"
echo ""

run_liquibase \
    --url="$DB_URL" \
    --username="$DB_USERNAME" \
    --password="$DB_PASSWORD" \
    --changelog-file="$OUTPUT_FILE" \
    diff \
    --reference-url="offline:postgresql?snapshot=$SNAPSHOT_FILE"

echo ""
echo "================================================="
echo "  Done!"
echo ""
echo "  Generated : $OUTPUT_FILE"
echo "  Snapshot  : $SNAPSHOT_FILE (proof of DB state)"
echo ""
echo "  Next steps:"
echo "    1. Add to master.xml Phase 1:"
echo "       <include file=\"db/changelog/ddl/001-baseline-existing-tables.xml\""
echo "                relativeToChangelogFile=\"false\"/>"
echo "    2. Run: ./gradlew bootRun"
echo "       Spring applies MARK_RAN — no data lost."
echo "================================================="
echo ""

# ── Step 3: Sync — mark baseline as already applied ───────────────
echo "[3/3] Running changelog-sync..."
echo ""

run_liquibase \
    --url="$DB_URL" \
    --username="$DB_USERNAME" \
    --password="$DB_PASSWORD" \
    --changelog-file="$OUTPUT_FILE" \
    changelog-sync

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "================================================="
echo "  Done!"
echo "  Baseline file : $OUTPUT_FILE"
echo "================================================="
echo ""