#!/usr/bin/env bash

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

SQLITE_DB="$ROOT/ledger.db"
VIEW_SQL="$(mktemp)"
TEST_SQL="$(mktemp)"

cleanup() {
    rm -f "$VIEW_SQL" "$TEST_SQL"
}

trap cleanup EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v sqlite3 >/dev/null 2>&1 ||
    die "sqlite3 is required"

if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
else
    die "docker compose or docker-compose is required"
fi

cat > "$VIEW_SQL" <<'SQL'
DROP VIEW IF EXISTS balances;

CREATE VIEW balances AS
SELECT
    accounts.account_id,
    accounts.name,
    COALESCE(credits.credits, 0) AS credits,
    COALESCE(debits.debits, 0) AS debits,
    COALESCE(credits.num_transactions, 0)
        + COALESCE(debits.num_transactions, 0) AS num_transactions,
    COALESCE(credits.credits, 0)
        - COALESCE(debits.debits, 0) AS balance
FROM accounts
LEFT JOIN (
    SELECT
        credit_account_id AS account_id,
        COUNT(*) AS num_transactions,
        SUM(amount) AS credits
    FROM transactions
    GROUP BY credit_account_id
) AS credits USING (account_id)
LEFT JOIN (
    SELECT
        debit_account_id AS account_id,
        COUNT(*) AS num_transactions,
        SUM(amount) AS debits
    FROM transactions
    GROUP BY debit_account_id
) AS debits USING (account_id)
ORDER BY accounts.account_id;
SQL

echo "== Checking required files =="

[[ -f ledger.sql ]] || die "ledger.sql not found"

echo
echo "== Setting up SQLite =="

rm -f "$SQLITE_DB"

sqlite3 "$SQLITE_DB" < ledger.sql
sqlite3 "$SQLITE_DB" < "$VIEW_SQL"

echo "SQLite row counts:"
sqlite3 -header -column "$SQLITE_DB" <<'SQL'
SELECT 'accounts' AS table_name, COUNT(*) AS row_count
FROM accounts
UNION ALL
SELECT 'transactions', COUNT(*)
FROM transactions;
SQL

echo
echo "SQLite balances:"
sqlite3 -header -column "$SQLITE_DB" \
    "SELECT * FROM balances;"

echo
echo "SQLite total balance:"
sqlite3 "$SQLITE_DB" \
    "SELECT COALESCE(SUM(balance), 0) FROM balances;"

echo
echo "== Setting up PostgreSQL =="

"${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${DC[@]}" up -d --build pg

echo "Waiting for PostgreSQL..."

pg_ready=0

for attempt in $(seq 1 60); do
    if "${DC[@]}" exec -T pg psql -Atqc "SELECT 1" \
        >/dev/null 2>&1
    then
        pg_ready=1
        break
    fi

    sleep 1
done

[[ "$pg_ready" -eq 1 ]] ||
    die "PostgreSQL did not become ready"

"${DC[@]}" exec -T pg psql \
    -v ON_ERROR_STOP=1 < ledger.sql

"${DC[@]}" exec -T pg psql \
    -v ON_ERROR_STOP=1 < "$VIEW_SQL"

echo "PostgreSQL row counts:"
"${DC[@]}" exec -T pg psql -c "
    SELECT 'accounts' AS table_name, COUNT(*) AS row_count
    FROM accounts
    UNION ALL
    SELECT 'transactions', COUNT(*)
    FROM transactions;
"

echo
echo "PostgreSQL balances:"
"${DC[@]}" exec -T pg psql -c \
    "SELECT * FROM balances;"

echo
echo "PostgreSQL total balance:"
"${DC[@]}" exec -T pg psql -Atc \
    "SELECT COALESCE(SUM(balance), 0) FROM balances;"

echo
echo "== Setting up MySQL =="

"${DC[@]}" up -d mysql

echo "Waiting for MySQL..."

mysql_ready=0

for attempt in $(seq 1 60); do
    if "${DC[@]}" exec -T mysql mysql \
        --protocol=TCP \
        -Dexample \
        -pexample \
        -e "SELECT 1" \
        >/dev/null 2>&1
    then
        mysql_ready=1
        break
    fi

    sleep 2
done

[[ "$mysql_ready" -eq 1 ]] ||
    die "MySQL did not become ready"

"${DC[@]}" exec -T mysql mysql \
    --protocol=TCP \
    -Dexample \
    -pexample < ledger.sql

"${DC[@]}" exec -T mysql mysql \
    --protocol=TCP \
    -Dexample \
    -pexample < "$VIEW_SQL"

echo "MySQL row counts:"
"${DC[@]}" exec -T mysql mysql \
    --protocol=TCP \
    -Dexample \
    -pexample \
    -e "
        SELECT 'accounts' AS table_name, COUNT(*) AS row_count
        FROM accounts
        UNION ALL
        SELECT 'transactions', COUNT(*)
        FROM transactions;
    "

echo
echo "MySQL balances:"
"${DC[@]}" exec -T mysql mysql \
    --protocol=TCP \
    -Dexample \
    -pexample \
    -e "SELECT * FROM balances;"

echo
echo "MySQL total balance:"
"${DC[@]}" exec -T mysql mysql \
    --protocol=TCP \
    -Dexample \
    -pexample \
    -N -B \
    -e "SELECT COALESCE(SUM(balance), 0) FROM balances;"

# ----------------------------------------------------------------------
# Database command helpers
# ----------------------------------------------------------------------

run_sqlite() {
    sqlite3 "$SQLITE_DB" < "$1"
}

run_postgres() {
    "${DC[@]}" exec -T pg psql \
        -X \
        -q \
        -v ON_ERROR_STOP=1 < "$1"
}

run_mysql() {
    # Do not use --force. We need MySQL to return a failure status when
    # a constraint rejects an INSERT.
    "${DC[@]}" exec -T mysql mysql \
        --protocol=TCP \
        -Dexample \
        -pexample < "$1"
}

run_database_sql() {
    local database="$1"
    local sql_file="$2"

    case "$database" in
        SQLite)
            run_sqlite "$sql_file"
            ;;
        PostgreSQL)
            run_postgres "$sql_file"
            ;;
        MySQL)
            run_mysql "$sql_file"
            ;;
        *)
            return 1
            ;;
    esac
}

# ----------------------------------------------------------------------
# Constraint test helper
#
# The first statement is committed.
# The second statement is then tested against the committed first row.
# Finally, cleanup statements remove the test data.
# ----------------------------------------------------------------------

check_constraint() {
    local database="$1"
    local first_statement="$2"
    local second_statement="$3"
    local cleanup_statements="$4"
    local first_status
    local second_status

    printf '%s\n' "$first_statement" > "$TEST_SQL"

    run_database_sql "$database" "$TEST_SQL" \
        >/dev/null 2>&1

    first_status=$?

    if [[ "$first_status" -ne 0 ]]; then
        printf "No"
        return
    fi

    printf '%s\n' "$second_statement" > "$TEST_SQL"

    run_database_sql "$database" "$TEST_SQL" \
        >/dev/null 2>&1

    second_status=$?

    # Always clean up the test records.
    printf '%s\n' "$cleanup_statements" > "$TEST_SQL"
    run_database_sql "$database" "$TEST_SQL" \
        >/dev/null 2>&1 || true

    if [[ "$first_status" -eq 0 &&
          "$second_status" -ne 0 ]]
    then
        printf "Yes"
    else
        printf "No"
    fi
}

# ----------------------------------------------------------------------
# Consistency checks
# ----------------------------------------------------------------------

echo
echo "== Consistency checks =="

printf "%-18s %-10s %-12s %-10s\n" \
    "Constraint" "SQLite" "PostgreSQL" "MySQL"

printf "%-18s %-10s %-12s %-10s\n" \
    "------------------" "--------" "----------" "--------"

sqlite_numeric="$(
    sqlite3 "$SQLITE_DB" \
        "SELECT COALESCE(SUM(balance), 0) FROM balances;"
)"

pg_numeric="$(
    "${DC[@]}" exec -T pg psql -Atc \
        "SELECT COALESCE(SUM(balance), 0) FROM balances;"
)"

mysql_numeric="$(
    "${DC[@]}" exec -T mysql mysql \
        --protocol=TCP \
        -Dexample \
        -pexample \
        -N -B \
        -e "SELECT COALESCE(SUM(balance), 0) FROM balances;"
)"

printf "%-18s %-10s %-12s %-10s\n" \
    "NUMERIC(10,2)" \
    "$(awk -v value="$sqlite_numeric" \
        'BEGIN { print (value == 0 ? "Yes" : "No") }')" \
    "$(awk -v value="$pg_numeric" \
        'BEGIN { print (value == 0 ? "Yes" : "No") }')" \
    "$(awk -v value="$mysql_numeric" \
        'BEGIN { print (value == 0 ? "Yes" : "No") }')"

printf "%-18s %-10s %-12s %-10s\n" \
    "NULL" \
    "$(check_constraint SQLite \
        "INSERT INTO accounts VALUES (100, 'test');" \
        "INSERT INTO accounts VALUES (101, NULL);" \
        "DELETE FROM accounts WHERE account_id IN (100, 101);")" \
    "$(check_constraint PostgreSQL \
        "INSERT INTO accounts VALUES (100, 'test');" \
        "INSERT INTO accounts VALUES (101, NULL);" \
        "DELETE FROM accounts WHERE account_id IN (100, 101);")" \
    "$(check_constraint MySQL \
        "INSERT INTO accounts VALUES (100, 'test');" \
        "INSERT INTO accounts VALUES (101, NULL);" \
        "DELETE FROM accounts WHERE account_id IN (100, 101);")"

printf "%-18s %-10s %-12s %-10s\n" \
    "CHECK" \
    "$(check_constraint SQLite \
        "INSERT INTO transactions VALUES (100, 1, 2, 10.0);" \
        "INSERT INTO transactions VALUES (101, 1, 2, -10.0);" \
        "DELETE FROM transactions WHERE transaction_id IN (100, 101);")" \
    "$(check_constraint PostgreSQL \
        "INSERT INTO transactions VALUES (100, 1, 2, 10.0);" \
        "INSERT INTO transactions VALUES (101, 1, 2, -10.0);" \
        "DELETE FROM transactions WHERE transaction_id IN (100, 101);")" \
    "$(check_constraint MySQL \
        "INSERT INTO transactions VALUES (100, 1, 2, 10.0);" \
        "INSERT INTO transactions VALUES (101, 1, 2, -10.0);" \
        "DELETE FROM transactions WHERE transaction_id IN (100, 101);")"

printf "%-18s %-10s %-12s %-10s\n" \
    "UNIQUE" \
    "$(check_constraint SQLite \
        "INSERT INTO accounts VALUES (200, 'Frank');" \
        "INSERT INTO accounts VALUES (200, 'Glenda');" \
        "DELETE FROM accounts WHERE account_id = 200;")" \
    "$(check_constraint PostgreSQL \
        "INSERT INTO accounts VALUES (200, 'Frank');" \
        "INSERT INTO accounts VALUES (200, 'Glenda');" \
        "DELETE FROM accounts WHERE account_id = 200;")" \
    "$(check_constraint MySQL \
        "INSERT INTO accounts VALUES (200, 'Frank');" \
        "INSERT INTO accounts VALUES (200, 'Glenda');" \
        "DELETE FROM accounts WHERE account_id = 200;")"

printf "%-18s %-10s %-12s %-10s\n" \
    "REFERENCES" \
    "$(check_constraint SQLite \
        "INSERT INTO transactions VALUES (300, 1, 2, 50.0);" \
        "INSERT INTO transactions VALUES (301, 1000, 1001, 50.0);" \
        "DELETE FROM transactions WHERE transaction_id IN (300, 301);")" \
    "$(check_constraint PostgreSQL \
        "INSERT INTO transactions VALUES (300, 1, 2, 50.0);" \
        "INSERT INTO transactions VALUES (301, 1000, 1001, 50.0);" \
        "DELETE FROM transactions WHERE transaction_id IN (300, 301);")" \
    "$(check_constraint MySQL \
        "INSERT INTO transactions VALUES (300, 1, 2, 50.0);" \
        "INSERT INTO transactions VALUES (301, 1000, 1001, 50.0);" \
        "DELETE FROM transactions WHERE transaction_id IN (300, 301);")"

echo
echo "Completed."

