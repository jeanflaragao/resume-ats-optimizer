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

ActiveRecord::Schema[8.1].define(version: 2026_08_07_194612) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "educations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "degree"
    t.date "ends_on"
    t.string "field_of_study"
    t.jsonb "pending_items", default: [], null: false
    t.integer "position"
    t.bigint "resume_id", null: false
    t.string "school", null: false
    t.date "starts_on"
    t.datetime "updated_at", null: false
    t.index ["resume_id"], name: "index_educations_on_resume_id"
  end

  create_table "experiences", force: :cascade do |t|
    t.jsonb "bullets", default: [], null: false
    t.string "company", null: false
    t.datetime "created_at", null: false
    t.date "ends_on"
    t.string "location"
    t.jsonb "pending_items", default: [], null: false
    t.integer "position"
    t.bigint "resume_id", null: false
    t.date "starts_on"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["resume_id"], name: "index_experiences_on_resume_id"
  end

  create_table "identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "payment_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "credits"
    t.string "stripe_checkout_session_id", null: false
    t.string "stripe_event_id", null: false
    t.string "stripe_price_id", null: false
    t.integer "unlimited_days"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["stripe_checkout_session_id"], name: "index_payment_grants_on_stripe_checkout_session_id", unique: true
    t.index ["stripe_event_id"], name: "index_payment_grants_on_stripe_event_id", unique: true
    t.index ["user_id"], name: "index_payment_grants_on_user_id"
  end

  create_table "resume_pdf_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "download_id", null: false
    t.bigint "resume_id", null: false
    t.text "text", null: false
    t.index ["created_at"], name: "index_resume_pdf_requests_on_created_at"
    t.index ["download_id"], name: "index_resume_pdf_requests_on_download_id", unique: true
    t.index ["resume_id"], name: "index_resume_pdf_requests_on_resume_id"
  end

  create_table "resumes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "last_accessed_at"
    t.string "name"
    t.jsonb "pending_items", default: [], null: false
    t.string "phone"
    t.jsonb "skills", default: [], null: false
    t.string "source"
    t.text "summary"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["last_accessed_at"], name: "index_resumes_on_last_accessed_at"
    t.index ["user_id"], name: "index_resumes_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "usage_counters", force: :cascade do |t|
    t.string "action_type", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "period", null: false
    t.date "period_start", null: false
    t.string "subject_token", null: false
    t.datetime "updated_at", null: false
    t.index ["period_start"], name: "index_usage_counters_on_period_start"
    t.index ["subject_token", "action_type", "period", "period_start"], name: "index_usage_counters_on_subject_action_period", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.integer "credits", default: 2, null: false
    t.string "email", null: false
    t.string "name"
    t.string "stripe_customer_id"
    t.datetime "unlimited_until"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["stripe_customer_id"], name: "index_users_on_stripe_customer_id", unique: true
  end

  add_foreign_key "educations", "resumes"
  add_foreign_key "experiences", "resumes"
  add_foreign_key "identities", "users"
  add_foreign_key "payment_grants", "users"
  add_foreign_key "resume_pdf_requests", "resumes", on_delete: :cascade
  add_foreign_key "resumes", "users"
  add_foreign_key "sessions", "users"
end
