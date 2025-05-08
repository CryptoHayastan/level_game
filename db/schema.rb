# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_05_07_143128) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "daily_bonus", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "bonus_day", default: 0
    t.datetime "last_collected_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_daily_bonus_on_user_id"
  end

  create_table "referrals", force: :cascade do |t|
    t.bigint "referrer_id", null: false
    t.bigint "referral_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["referral_id"], name: "index_referrals_on_referral_id"
    t.index ["referrer_id"], name: "index_referrals_on_referrer_id"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "telegram_id"
    t.string "username"
    t.string "first_name"
    t.string "last_name"
    t.string "role"
    t.string "step"
    t.boolean "ban"
    t.integer "balance"
    t.string "referral_link"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "daily_bonus", "users"
  add_foreign_key "referrals", "users", column: "referral_id"
  add_foreign_key "referrals", "users", column: "referrer_id"
end
