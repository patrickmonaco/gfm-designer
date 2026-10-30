-- GFM Designer - installation (SQLcl / SQL*Plus, UTF-8 client)
--   sql demo/<password>@<db> @install.sql
-- gfm_builder (v2.1) is included: skip the first two lines if already installed.
whenever sqlerror exit failure rollback
@00_gfm_builder.pks
@00_gfm_builder.pkb
@01_gfm_api.pks
@02_gfm_api.pkb
show errors package body gfm_api
@03_ords_module.sql
@04_ords_security.sql
