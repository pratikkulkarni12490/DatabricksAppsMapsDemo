-- RLS performance: evaluate the caller's scope once per query (InitPlan) instead of once per row.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['live_incidents', 'live_technicians'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON app.%I', t || '_scope', t);
    EXECUTE format($p$CREATE POLICY %I ON app.%I FOR ALL
      USING ((SELECT app.scope_national()) OR region = ANY ((SELECT app.scope_regions())::text[]) OR metro_code = ANY ((SELECT app.scope_metros())::text[]))
      WITH CHECK ((SELECT app.scope_national()) OR region = ANY ((SELECT app.scope_regions())::text[]) OR metro_code = ANY ((SELECT app.scope_metros())::text[]))$p$,
      t || '_scope', t);
  END LOOP;
END $$;
DROP POLICY IF EXISTS plot_shortlist_scope ON app.plot_shortlist;
CREATE POLICY plot_shortlist_scope ON app.plot_shortlist FOR ALL
  USING ((SELECT app.scope_national()) OR region = ANY ((SELECT app.scope_regions())::text[]) OR metro_code = ANY ((SELECT app.scope_metros())::text[]))
  WITH CHECK (((SELECT app.scope_national()) OR region = ANY ((SELECT app.scope_regions())::text[]) OR metro_code = ANY ((SELECT app.scope_metros())::text[]))
              AND principal = app.effective_principal());
CREATE INDEX IF NOT EXISTS live_technicians_metro_status_idx ON app.live_technicians (metro_code, status);
CREATE INDEX IF NOT EXISTS live_incidents_status_idx ON app.live_incidents (status, metro_code);
ANALYZE app.live_technicians;
ANALYZE app.live_incidents;
