-- GFM Designer - update 1.2 -> 1.3 (NUMBER and DATE storage columns)
-- Run as the schema owner (e.g. DEMO), in this order. No ORDS change.
@08_typed_columns.sql
@00_gfm_builder.pkb
show errors package body gfm_builder
@02_gfm_api.pkb
show errors package body gfm_api
