-- GFM Designer - update 1.0 -> 1.1 (components and list values screen)
-- Run as the schema owner (e.g. DEMO), in this order.
-- 03 recreates the module: 04 is run again to re-attach the privilege
-- (existing role and OAuth clients are kept).
@06_lov_order.sql
@00_gfm_builder.pkb
@01_gfm_api.pks
@02_gfm_api.pkb
show errors package body gfm_api
@03_ords_module.sql
@04_ords_security.sql
