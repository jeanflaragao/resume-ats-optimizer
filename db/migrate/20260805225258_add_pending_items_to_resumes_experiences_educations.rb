class AddPendingItemsToResumesExperiencesEducations < ActiveRecord::Migration[8.1]
  def change
    add_column :resumes, :pending_items, :jsonb, null: false, default: []
    add_column :experiences, :pending_items, :jsonb, null: false, default: []
    add_column :educations, :pending_items, :jsonb, null: false, default: []
  end
end
