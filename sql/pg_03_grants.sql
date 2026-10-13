-- Least privilege for the GeoLens app service principal: secure.* views and app.* tables only, never geo.* base tables.
-- Scope enforcement stays in Postgres (security_barrier views + RLS policies), so a bug in the app cannot widen access.
GRANT CONNECT ON DATABASE databricks_postgres TO "${app_sp_client_id}";
GRANT USAGE ON SCHEMA secure, app TO "${app_sp_client_id}";
GRANT SELECT ON ALL TABLES IN SCHEMA secure TO "${app_sp_client_id}";
GRANT SELECT, INSERT, UPDATE, DELETE ON app.saved_maps, app.plot_shortlist, app.live_incidents, app.live_technicians
  TO "${app_sp_client_id}";
GRANT SELECT ON app.layer_catalog, app.dataset_version, app.data_version TO "${app_sp_client_id}";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO "${app_sp_client_id}";
-- bump_dataset is called by the leader's sync watcher
GRANT UPDATE ON app.dataset_version TO "${app_sp_client_id}";
REVOKE ALL ON SCHEMA geo FROM "${app_sp_client_id}";
