-- GFM Designer - update 1.1 -> 1.2 (interactive report page per form)
-- Run as the schema owner (e.g. DEMO), in this order. No ORDS change.
@07_report_page.sql
@00_gfm_builder.pks
@00_gfm_builder.pkb
show errors package body gfm_builder
@02_gfm_api.pkb
show errors package body gfm_api
