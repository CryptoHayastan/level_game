-- schema.sql
DROP TABLE IF EXISTS promo_usages CASCADE;
DROP TABLE IF EXISTS promo_codes CASCADE;
DROP TABLE IF EXISTS message_counts CASCADE;
DROP TABLE IF EXISTS daily_bonus CASCADE;
DROP TABLE IF EXISTS city_shops CASCADE;
DROP TABLE IF EXISTS shops CASCADE;
DROP TABLE IF EXISTS cities CASCADE;
DROP TABLE IF EXISTS boosts CASCADE;
DROP TABLE IF EXISTS users CASCADE;

BEGIN;

CREATE EXTENSION IF NOT EXISTS plpgsql;

CREATE TABLE "boosts" (
  "id" bigserial PRIMARY KEY,
  "user_id" bigint NOT NULL,
  "activated_at" timestamp,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE TABLE "cities" (
  "id" bigserial PRIMARY KEY,
  "name" varchar,
  "sub" boolean,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE TABLE "city_shops" (
  "id" bigserial PRIMARY KEY,
  "city_id" bigint NOT NULL,
  "shop_id" bigint NOT NULL,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE TABLE "daily_bonus" (
  "id" bigserial PRIMARY KEY,
  "user_id" bigint NOT NULL,
  "bonus_day" integer DEFAULT 0,
  "last_collected_at" timestamp,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE TABLE "message_counts" (
  "id" bigserial PRIMARY KEY,
  "user_id" bigint NOT NULL,
  "count" integer,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE TABLE "promo_codes" (
  "id" bigserial PRIMARY KEY,
  "code" varchar,
  "shop_id" bigint NOT NULL,
  "product_type" integer,
  "expires_at" timestamp,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE UNIQUE INDEX "index_promo_codes_on_code" ON "promo_codes" ("code");

CREATE TABLE "promo_usages" (
  "id" bigserial PRIMARY KEY,
  "promo_code_id" bigint NOT NULL,
  "user_id" bigint NOT NULL,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE UNIQUE INDEX "index_promo_usages_on_promo_code_id_and_user_id" ON "promo_usages" ("promo_code_id", "user_id");

CREATE TABLE "shops" (
  "id" bigserial PRIMARY KEY,
  "user_id" bigint,
  "name" varchar,
  "link" varchar,
  "online" boolean,
  "online_since" timestamp,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

CREATE TABLE "users" (
  "id" bigserial PRIMARY KEY,
  "telegram_id" bigint,
  "username" varchar,
  "first_name" varchar,
  "last_name" varchar,
  "role" varchar,
  "step" varchar,
  "ban" boolean,
  "balance" integer,
  "score" integer,
  "referral_link" varchar,
  "pending_referrer_id" integer,
  "parent_access" boolean DEFAULT true,
  "ancestry" varchar,
  "created_at" timestamp NOT NULL,
  "updated_at" timestamp NOT NULL
);

ALTER TABLE "boosts" ADD FOREIGN KEY ("user_id") REFERENCES "users";
ALTER TABLE "city_shops" ADD FOREIGN KEY ("city_id") REFERENCES "cities";
ALTER TABLE "city_shops" ADD FOREIGN KEY ("shop_id") REFERENCES "shops";
ALTER TABLE "daily_bonus" ADD FOREIGN KEY ("user_id") REFERENCES "users";
ALTER TABLE "message_counts" ADD FOREIGN KEY ("user_id") REFERENCES "users";
ALTER TABLE "promo_codes" ADD FOREIGN KEY ("shop_id") REFERENCES "shops";
ALTER TABLE "promo_usages" ADD FOREIGN KEY ("promo_code_id") REFERENCES "promo_codes";
ALTER TABLE "promo_usages" ADD FOREIGN KEY ("user_id") REFERENCES "users";
ALTER TABLE "shops" ADD FOREIGN KEY ("user_id") REFERENCES "users";

COMMIT;