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

ActiveRecord::Schema[8.0].define(version: 2026_07_30_165329) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "cvs", force: :cascade do |t|
    t.text "summary"
    t.jsonb "skills", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "educations", force: :cascade do |t|
    t.bigint "cv_id", null: false
    t.string "school", null: false
    t.string "degree"
    t.string "field_of_study"
    t.date "starts_on"
    t.date "ends_on"
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cv_id"], name: "index_educations_on_cv_id"
  end

  create_table "experiences", force: :cascade do |t|
    t.bigint "cv_id", null: false
    t.string "company", null: false
    t.string "title", null: false
    t.string "location"
    t.date "starts_on"
    t.date "ends_on"
    t.jsonb "bullets", default: [], null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cv_id"], name: "index_experiences_on_cv_id"
  end

  add_foreign_key "educations", "cvs"
  add_foreign_key "experiences", "cvs"
end
