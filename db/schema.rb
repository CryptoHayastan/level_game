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

ActiveRecord::Schema[8.0].define(version: 2025_05_10_131720) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "cities", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "city_shops", force: :cascade do |t|
    t.bigint "city_id", null: false
    t.bigint "shop_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["city_id"], name: "index_city_shops_on_city_id"
    t.index ["shop_id"], name: "index_city_shops_on_shop_id"
  end

  create_table "daily_bonus", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "bonus_day", default: 0
    t.datetime "last_collected_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_daily_bonus_on_user_id"
  end

  create_table "shops", force: :cascade do |t|
    t.bigint "user_id"
    t.string "name"
    t.string "link"
    t.boolean "online"
    t.datetime "online_since"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_shops_on_user_id"
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
    t.boolean "parent_access", default: true
    t.string "ancestry"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "city_shops", "cities"
  add_foreign_key "city_shops", "shops"
  add_foreign_key "daily_bonus", "users"
  add_foreign_key "shops", "users"
end
