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

ActiveRecord::Schema[8.1].define(version: 2026_08_15_050001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "loops_outbox_envelope_status", ["queued", "sent", "ignored_noop", "failed", "partially_sent"]
  create_enum "sync_source_deleted_reason", ["disappeared", "manual", "ignored_pattern"]

  create_table "authenticated_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.datetime "expires_at", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email_normalized"], name: "index_authenticated_sessions_on_email_normalized"
    t.index ["expires_at"], name: "index_authenticated_sessions_on_expires_at"
    t.index ["token"], name: "index_authenticated_sessions_on_token", unique: true
  end

  create_table "field_value_baselines", force: :cascade do |t|
    t.integer "checked_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "field_id", null: false
    t.datetime "first_seen_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "last_checked_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.jsonb "last_known_value"
    t.string "row_id", null: false
    t.bigint "sync_source_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "value_last_updated_at", null: false
    t.index ["last_checked_at"], name: "idx_field_value_baselines_last_checked_at"
    t.index ["sync_source_id", "row_id", "field_id"], name: "index_field_value_baselines_on_sync_source_row_field", unique: true
    t.index ["sync_source_id"], name: "index_field_value_baselines_on_sync_source_id"
    t.index ["value_last_updated_at"], name: "index_field_value_baselines_on_value_last_updated_at"
  end

  create_table "llm_caches", force: :cascade do |t|
    t.integer "bytes_size", null: false
    t.datetime "created_at", null: false
    t.datetime "last_used_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "prompt_hash", null: false
    t.jsonb "request_json", null: false
    t.jsonb "response_json", null: false
    t.datetime "updated_at", null: false
    t.index ["last_used_at"], name: "index_llm_caches_on_last_used_at"
    t.index ["prompt_hash"], name: "index_llm_caches_on_prompt_hash", unique: true
  end

  create_table "loops_contact_change_audits", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.string "field_name", null: false
    t.jsonb "former_loops_value"
    t.jsonb "former_sync_source_value"
    t.boolean "is_self_service", default: false, null: false
    t.jsonb "new_loops_value"
    t.jsonb "new_sync_source_value"
    t.datetime "occurred_at", null: false
    t.jsonb "provenance", default: {}
    t.string "request_id"
    t.string "strategy"
    t.string "sync_source_field_id"
    t.bigint "sync_source_id"
    t.string "sync_source_record_id"
    t.string "sync_source_table_id"
    t.datetime "updated_at", null: false
    t.index ["email_normalized", "occurred_at"], name: "idx_on_email_normalized_occurred_at_4255605731"
  end

  create_table "loops_email_activities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.datetime "last_occurred_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_normalized"], name: "idx_loops_email_activities_email_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["email_normalized"], name: "index_loops_email_activities_on_email_normalized", unique: true
    t.index ["last_occurred_at", "email_normalized"], name: "idx_loops_email_activities_recency", order: { last_occurred_at: :desc }
  end

  create_table "loops_field_baselines", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.datetime "expires_at"
    t.string "field_name", null: false
    t.datetime "last_sent_at"
    t.jsonb "last_sent_value"
    t.datetime "updated_at", null: false
    t.index ["email_normalized", "field_name"], name: "index_loops_field_baselines_on_email_normalized_and_field_name", unique: true
    t.index ["expires_at"], name: "index_loops_field_baselines_on_expires_at"
  end

  create_table "loops_list_subscriptions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.string "list_id", null: false
    t.datetime "subscribed_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "updated_at", null: false
    t.index ["email_normalized", "list_id"], name: "idx_unique_loops_list_subscriptions", unique: true
    t.index ["email_normalized"], name: "index_loops_list_subscriptions_on_email_normalized"
  end

  create_table "loops_lists", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "is_public"
    t.string "loops_list_id", null: false
    t.string "name"
    t.datetime "synced_at"
    t.datetime "updated_at", null: false
    t.index ["loops_list_id"], name: "index_loops_lists_on_loops_list_id", unique: true
  end

  create_table "loops_outbox_envelopes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.jsonb "error", default: {}
    t.jsonb "payload", null: false
    t.jsonb "provenance", default: {}, null: false
    t.enum "status", default: "queued", null: false, enum_type: "loops_outbox_envelope_status"
    t.bigint "sync_source_id"
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_loops_outbox_envelopes_on_created_at"
    t.index ["email_normalized", "status"], name: "index_loops_outbox_envelopes_on_email_normalized_and_status"
    t.index ["status"], name: "index_loops_outbox_envelopes_on_status"
    t.index ["sync_source_id"], name: "index_loops_outbox_envelopes_on_sync_source_id"
  end

  create_table "otp_verifications", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.string "code_hash", null: false
    t.datetime "created_at", null: false
    t.string "email_normalized", null: false
    t.datetime "expires_at", null: false
    t.string "salt", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["email_normalized", "expires_at"], name: "index_otp_verifications_on_email_normalized_and_expires_at"
    t.index ["expires_at"], name: "index_otp_verifications_on_expires_at"
  end

  create_table "sync_source_ignores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "reason"
    t.string "source", null: false
    t.string "source_id", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sync_sources", force: :cascade do |t|
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.jsonb "cursor"
    t.datetime "deleted_at"
    t.enum "deleted_reason", enum_type: "sync_source_deleted_reason"
    t.string "display_name"
    t.datetime "display_name_updated_at"
    t.jsonb "error_details", default: {}, null: false
    t.datetime "first_seen_at"
    t.datetime "last_poll_attempted_at"
    t.datetime "last_seen_at"
    t.datetime "last_successful_poll_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "next_poll_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.integer "poll_interval_seconds", default: 30, null: false
    t.float "poll_jitter", default: 0.1, null: false
    t.integer "seen_count", default: 0, null: false
    t.string "source", null: false
    t.string "source_id", null: false
    t.datetime "updated_at", null: false
    t.index ["next_poll_at"], name: "index_sync_sources_on_next_poll_at"
    t.index ["source", "source_id"], name: "index_sync_sources_active_unique", unique: true, where: "(deleted_at IS NULL)"
  end

  add_foreign_key "field_value_baselines", "sync_sources"
  add_foreign_key "loops_outbox_envelopes", "sync_sources"
end
