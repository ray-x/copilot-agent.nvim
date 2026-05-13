-- Test override: no-op markdown ftplugin to avoid treesitter runtime calls during headless tests.
-- This file intentionally shadows the runtime ftplugin/markdown.lua when tests set
-- runtimepath to prefer the plugin under test.

-- No-op: keep minimal footprint and avoid invoking treesitter.
