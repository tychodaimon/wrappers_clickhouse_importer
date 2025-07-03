-- ====================================================================================
-- Procedure: public.refresh_foreign_tables
-- Description: Creates PostgreSQL foreign tables based on ClickHouse schema using
--              clickhouse_fdw. Automatically introspects structure and maps types.
--
-- Author: github.com/tychodaimon
-- License: MIT
-- Source: https://fdw.dev/catalog/clickhouse/
-- ====================================================================================

CREATE OR REPLACE PROCEDURE public.refresh_foreign_tables(
    ch_server_name TEXT, -- ClickHouse FDW server name
    ch_schema_name TEXT, -- ClickHouse database name
    pg_schema_name TEXT  -- PostgreSQL schema to create foreign tables in
)
LANGUAGE plpgsql
STRICT
AS $BODY$
DECLARE
    create_sql_var TEXT;
    drop_sql_var TEXT;
    tablename_var TEXT;
    column_list TEXT;
    column_rec RECORD;
BEGIN
    -- Drop and recreate target PostgreSQL schema
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE;', pg_schema_name);
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I;', pg_schema_name);
    RAISE NOTICE ' ';

    -- Create foreign tables for ClickHouse system.tables and system.columns
    create_sql_var := format(
        'CREATE FOREIGN TABLE %I.system_tables (
            name text,
            database text,
            engine text,
            metadata_modification_time timestamp,
            uuid text,
            create_table_query text,
            engine_full text,
            is_temporary boolean
        ) SERVER %I OPTIONS (table ''system.tables'');',
        pg_schema_name, ch_server_name
    );
    EXECUTE create_sql_var;

    create_sql_var := format(
        'CREATE FOREIGN TABLE %I.system_columns (
            name text,
            type text,
            "table" text,
            database text,
            position int
        ) SERVER %I OPTIONS (table ''system.columns'');',
        pg_schema_name, ch_server_name
    );
    EXECUTE create_sql_var;

    -- Create temporary table with ClickHouse table names
    DROP TABLE IF EXISTS tmp_ch_tables;
    EXECUTE format(
        'CREATE TEMP TABLE tmp_ch_tables AS
         SELECT name AS table_name
         FROM %I.system_tables
         WHERE database = %L
           AND name NOT LIKE ''.inner_id%%''
           AND name NOT LIKE ''%%migration%%''
           AND name NOT LIKE ''%%mview%%'';',
        pg_schema_name, ch_schema_name
    );

    FOR tablename_var IN SELECT table_name FROM tmp_ch_tables LOOP
        DROP TABLE IF EXISTS tmp_ch_columns;

        -- Create temporary table with column metadata
        EXECUTE format(
            'CREATE TEMP TABLE tmp_ch_columns AS
             SELECT name::text AS ch_name, type::text AS ch_type, position::int
             FROM %I.system_columns
             WHERE database = %L AND "table" = %L
               AND name IS NOT NULL AND type IS NOT NULL
             ORDER BY position;',
            pg_schema_name, ch_schema_name, tablename_var
        );

        column_list := '';

        FOR column_rec IN
            SELECT ch_name, ch_type, CASE
                WHEN ch_type = 'String' THEN 'text'
                WHEN ch_type = 'UUID' THEN 'uuid'
                WHEN ch_type = 'Date' THEN 'date'
                WHEN ch_type = 'DateTime' THEN 'timestamp'
                WHEN ch_type = 'Int8' THEN 'smallint'
                WHEN ch_type = 'Int32' THEN 'integer'
                WHEN ch_type = 'Int64' THEN 'bigint'
                WHEN ch_type = 'UInt8' THEN 'smallint'
                WHEN ch_type = 'UInt32' THEN 'bigint'
                WHEN ch_type = 'UInt64' THEN 'bigint'
                WHEN ch_type = 'Nullable(String)' THEN 'text'
                WHEN ch_type = 'Nullable(UInt32)' THEN 'bigint'
                WHEN ch_type = 'Nullable(Date)' THEN 'date'

                -- Universal handlers:
                WHEN ch_type ILIKE 'Int%' THEN 'bigint'
                WHEN ch_type ILIKE 'UInt%' THEN 'bigint'
                WHEN ch_type ILIKE 'Float%' THEN 'double precision'
                WHEN ch_type ILIKE 'LowCardinality(String)' THEN 'text'
                WHEN ch_type ILIKE 'LowCardinality(UUID)' THEN 'uuid'
                WHEN ch_type ILIKE 'LowCardinality%' THEN 'text'
                WHEN ch_type ILIKE 'Nullable(UInt%)' THEN 'bigint'
                WHEN ch_type ILIKE 'Nullable(Int%)' THEN 'bigint'
                WHEN ch_type ILIKE 'Nullable%' THEN 'text'
                WHEN ch_type ILIKE 'Date%' THEN 'timestamp'
                WHEN ch_type ILIKE 'Array%' THEN 'jsonb'
                ELSE 'text'
            END AS pg_type
            FROM tmp_ch_columns
            ORDER BY position
        LOOP
            IF column_rec.ch_type ~* '^(AggregateFunction|JSON|Tuple|Object|Map|IPv4|IPv6|Geo|Point)' THEN
                RAISE NOTICE '⏭ Skipped column: %.% (%: %)', ch_schema_name, tablename_var, column_rec.ch_name, column_rec.ch_type;
                CONTINUE;
            END IF;

            column_list := column_list || format('%I %s, ', column_rec.ch_name, column_rec.pg_type);
        END LOOP;

        IF column_list IS NULL OR length(column_list) = 0 THEN
            RAISE NOTICE '❌ Skipped table % — no supported columns found', tablename_var;
            CONTINUE;
        END IF;

        column_list := left(column_list, length(column_list) - 2);

        create_sql_var := format(
            'CREATE FOREIGN TABLE %I.%I (%s) SERVER %I OPTIONS (table %L);',
            pg_schema_name,
            tablename_var,
            column_list,
            ch_server_name,
            ch_schema_name || '.' || tablename_var
        );

        RAISE NOTICE E'📄\n%\n\n', create_sql_var;

        BEGIN
            EXECUTE create_sql_var;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '⚠️ Error creating table %: %', tablename_var, SQLERRM;
        END;
    END LOOP;

    -- Cleanup temporary objects
    DROP TABLE IF EXISTS tmp_ch_columns;
    DROP TABLE IF EXISTS tmp_ch_tables;
    
    EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.system_columns;', pg_schema_name);
    EXECUTE format('DROP FOREIGN TABLE IF EXISTS %I.system_tables;', pg_schema_name);
END;
$BODY$;
