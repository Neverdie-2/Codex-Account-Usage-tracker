-- Builds a tiny state.vscdb-shaped SQLite fixture for the Cursor tests.
-- Run from this Fixtures directory with the sqlite3 CLI:
--   sqlite3 sample.vscdb < make_sample_vscdb.sql
-- (The unit tests instead build an equivalent DB in setUp via the SQLite3 C API,
--  reading the .sample.json values through Bundle.module, so no binary is checked in.)
--
-- Real-DB shape (verified 2026-06-20): the authoritative conversation list lives in
-- cursorDiskKV 'composerData:<composerId>' rows (composer.composerHeaders only exposes
-- a recent subset, used here for display enrichment). Bubbles key off the COLON-
-- separated form 'bubbleId:<composerId>:<bubbleUuid>'.
CREATE TABLE ItemTable(key TEXT, value TEXT);
CREATE TABLE cursorDiskKV(key TEXT, value TEXT);
INSERT INTO ItemTable VALUES('composer.composerHeaders', readfile('composerHeaders.sample.json'));
INSERT INTO ItemTable VALUES('cursor/lastSingleModelPreference', '{"composer":"gemini-3-flash"}');
INSERT INTO ItemTable VALUES('cursorAuth/cachedEmail', 'angeldanielov9@gmail.com');
INSERT INTO ItemTable VALUES('cursorAuth/stripeMembershipType', 'free');
INSERT INTO ItemTable VALUES('cursorAuth/stripeSubscriptionStatus', 'canceled');
-- accessToken: a synthetic 3-segment JWT (alg "none"). Middle segment base64url-decodes to
-- {"sub":"google-oauth2|user_01ABCDEF","aud":"https://cursor.com","exp":4102444800} (valid through year 2100).
INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJnb29nbGUtb2F1dGgyfHVzZXJfMDFBQkNERUYiLCJhdWQiOiJodHRwczovL2N1cnNvci5jb20iLCJleHAiOjQxMDI0NDQ4MDB9.sig');
-- Conversations (composerData:<composerId>).
INSERT INTO cursorDiskKV VALUES('composerData:11111111-2222-3333-4444-555555555555','{"composerId":"11111111-2222-3333-4444-555555555555","createdAt":1750405404081,"unifiedMode":"agent","forceMode":"agent","totalLinesAdded":128,"totalLinesRemoved":17}');
INSERT INTO cursorDiskKV VALUES('composerData:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee','{"composerId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","createdAt":1749000000000,"unifiedMode":"chat","totalLinesAdded":0,"totalLinesRemoved":0}');
-- Bubbles (bubbleId:<composerId>:<bubbleUuid>). modelInfo.modelName appears on user and
-- assistant bubbles; type-2 with null modelInfo is skipped.
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555:b1','{"type":1,"text":"refactor this","modelInfo":{"modelName":"composer-2.5"},"createdAt":"2026-06-20T07:43:24.081Z"}');
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555:b2','{"type":2,"text":"done","modelInfo":null,"createdAt":"2026-06-20T07:43:30.000Z"}');
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555:b3','{"type":1,"text":"now tests","modelInfo":{"modelName":"claude-4.5-opus-high-thinking"},"createdAt":"2026-06-20T08:10:00.000Z"}');
-- decoy: a prefix-colliding orphan composerId (no composerData/header) must NOT join composer 1111… nor fabricate a row.
INSERT INTO cursorDiskKV VALUES('bubbleId:11111111-2222-3333-4444-555555555555X:WRONG','{"type":1,"text":"decoy","modelInfo":{"modelName":"decoy-model"},"createdAt":"2026-06-20T09:00:00.000Z"}');
