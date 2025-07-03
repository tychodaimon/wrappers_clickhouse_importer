# 🔁 ClickHouse → PostgreSQL Foreign Tables Sync

This repository provides a **PL/pgSQL stored procedure** for **PostgreSQL** that acts as a complete, schema-aware replacement for the missing `IMPORT FOREIGN SCHEMA` command in [clickhouse_fdw by Supabase Wrappers](https://fdw.dev/catalog/clickhouse/).

The script introspects your ClickHouse database via FDW by querying `system.tables` and `system.columns`, maps ClickHouse types to PostgreSQL equivalents, and generates fully functional `FOREIGN TABLE` definitions inside a specified PostgreSQL schema — automatically and safely.

> 🛠️ **DROP-IN replacement** for `IMPORT FOREIGN SCHEMA` (not supported in `clickhouse_fdw`)  
> ⚙️ Uses native ClickHouse metadata for introspection  
> 🧠 Supports most commonly used ClickHouse data types  
> 🚫 Skips unsupported or unsafe types like `Tuple`, `Map`, `AggregateFunction`, etc.  
> 📡 Ideal for data warehousing, reporting, analytics, and federated access to ClickHouse

---

## ✅ Why use this?

The Supabase-maintained [`clickhouse_fdw`](https://fdw.dev/catalog/clickhouse/) extension enables querying ClickHouse directly from PostgreSQL using SQL.  
However, it **does not implement `IMPORT FOREIGN SCHEMA`**, forcing you to manually define each table using `CREATE FOREIGN TABLE`.

This script fills that gap by fully automating the foreign table creation process.

It works similarly to how `IMPORT FOREIGN SCHEMA` works for other FDWs like `postgres_fdw`, but built entirely in PL/pgSQL and compatible with `clickhouse_fdw`.

---

## 📦 Requirements

- PostgreSQL 13 or later
- [clickhouse_fdw](https://fdw.dev/catalog/clickhouse/) installed and configured
- A working `SERVER` definition for ClickHouse
- User mapping with appropriate credentials
- Access to `system.tables` and `system.columns` on the ClickHouse side

---

## 📐 Overview: What it does

When called, the procedure:

1. Connects to a ClickHouse database via FDW
2. Reads all table names from `system.tables`
3. Reads and filters each column from `system.columns`
4. Maps ClickHouse types (e.g., `String`, `UUID`, `DateTime`, `Nullable(UInt64)`) to PostgreSQL types
5. Skips unsupported or unsafe types like `Map`, `Tuple`, `AggregateFunction`
6. Generates a `CREATE FOREIGN TABLE` statement per table
7. Optionally drops and recreates the target PostgreSQL schema

---

## ⚙️ Installation

### 1. Install and configure `clickhouse_fdw`

Follow [fdw.dev instructions](https://fdw.dev/catalog/clickhouse/) or build from source. Then, in your PostgreSQL database:

Prepaire:

```sql
CREATE EXTENSION wrappers;

CREATE FOREIGN DATA WRAPPER clickhouse_wrapper
  handler click_house_fdw_handler
  validator click_house_fdw_validator;
```

Also create a server:

```sql
CREATE SERVER ch_server
  FOREIGN DATA WRAPPER clickhouse_wrapper
  OPTIONS (conn_string 'tcp://admin:XXXXXXX@clickhouse-ext.clickhouse-stage:9000/default');
```

---

### 2. Create the stored procedure

Apply the [`refresh_foreign_tables.sql`](./refresh_foreign_tables.sql) file:

```bash
psql -d your_database -f refresh_foreign_tables.sql
```

or simply paste and run in your psql client

This creates the `public.refresh_foreign_tables` procedure.

---

### 3. Use it like `IMPORT FOREIGN SCHEMA`

```sql
CALL public.refresh_foreign_tables(
    'ch_server',               -- ClickHouse FDW server name
    'your_clickhouse_schema',  -- ClickHouse schema/database name
    'your_postgres_schema'     -- PostgreSQL schema to create foreign tables in
);
```

✅ That’s it — PostgreSQL now has a local schema of foreign tables directly mapped from your ClickHouse database.

---

## 🔎 Type Mapping

This procedure includes built-in mapping logic between ClickHouse and PostgreSQL types.

| ClickHouse Type                      | PostgreSQL Type       |
|-------------------------------------|------------------------|
| `String`, `LowCardinality(String)`  | `text`                |
| `UUID`, `LowCardinality(UUID)`      | `uuid`                |
| `Int8`, `UInt8`                     | `smallint`            |
| `Int32`                             | `integer`             |
| `Int64`, `UInt32`, `UInt64`         | `bigint`              |
| `Float32`, `Float64`                | `double precision`    |
| `Date`, `DateTime`, `DateTime64`    | `date` / `timestamp`  |
| `Nullable(T)`                       | mapped `T` or `text`  |
| `Array(T)`                          | `jsonb`               |

❗ Unsupported types are **skipped** with a log message:
- `AggregateFunction`
- `Map`
- `Tuple`
- `Object`
- `JSON`
- `Geo`, `Point`
- `IPv4`, `IPv6`

---

## 🧾 Output Examples

Output will include `NOTICE` logs for each table and skipped column:

```
📄
CREATE FOREIGN TABLE clickhouse_imported.events (
    id uuid,
    created_at timestamp,
    payload jsonb
) SERVER clickhouse_srv OPTIONS (table 'vc_sharded.events');

⏭ Skipped column: vc_sharded.logs (details: extra_info Tuple(UInt32, String))
❌ Skipped table raw_events — no supported columns found
```

---

## 🧼 Cleanup and Schema Handling

- The target PostgreSQL schema (`pg_schema_name`) is **dropped and recreated** on each run.
- Temporary introspection tables (`tmp_ch_tables`, `tmp_ch_columns`) are cleaned up automatically.
- Foreign tables `system.tables` and `system.columns` are also dropped at the end.

---

## 🛡 Limitations

- This script does not support creating indexes or primary keys.
- Read-only access only — depends on what `clickhouse_fdw` supports.
- Arrays are converted to `jsonb`, not proper typed arrays.
- Only flat tables are supported (no nested or complex types).

---

## 💬 Tips

- To debug, enable `client_min_messages = notice` in your `psql` session
- Run this procedure as part of a CI/CD job to keep schemas in sync
- You can easily fork this and extend type mappings or filtering rules

---

## 📚 Resources

- [clickhouse_fdw by Supabase](https://fdw.dev/catalog/clickhouse/)
- [ClickHouse System Tables Reference](https://clickhouse.com/docs/en/operations/system-tables/)
- [PostgreSQL Foreign Data Wrapper docs](https://www.postgresql.org/docs/current/ddl-foreign-data.html)

---

## 📜 License

This project is licensed under the MIT License. See [`LICENSE`](./LICENSE) for details.

---

## 🌟 Support

If you find this project helpful, please consider [starring ★ the repository](https://github.com/tychodaimon/wrappers_clickhouse_importer) — it’s the easiest way to say **thank you** and helps others discover it too!
