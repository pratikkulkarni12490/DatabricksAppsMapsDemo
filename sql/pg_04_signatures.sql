-- Reliable "a sync landed" signal from inside Postgres: a snapshot/triggered refresh rewrites the partition's storage,
-- so relfilenode + on-disk size change. Exposed via SECURITY DEFINER so the app role needs no catalog privileges on geo.
CREATE OR REPLACE FUNCTION app.synced_table_signatures() RETURNS TABLE (table_name text, signature text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT p.relname::text,
         string_agg(c.oid::text || ':' || c.relfilenode::text || ':' || pg_relation_size(c.oid)::text, ',' ORDER BY c.oid)
  FROM pg_class p
  JOIN pg_namespace n ON n.oid = p.relnamespace
  LEFT JOIN pg_inherits i ON i.inhparent = p.oid
  LEFT JOIN pg_class c ON c.oid = coalesce(i.inhrelid, p.oid)
  WHERE n.nspname = 'geo' AND p.relkind IN ('p', 'r') AND NOT p.relispartition
  GROUP BY p.relname
$$;
GRANT EXECUTE ON FUNCTION app.synced_table_signatures() TO "${app_sp_client_id}";
