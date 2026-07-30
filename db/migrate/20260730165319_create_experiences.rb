class CreateExperiences < ActiveRecord::Migration[8.0]
  def change
    create_table :experiences do |t|
      t.references :cv, null: false, foreign_key: true
      t.string :company, null: false
      t.string :title, null: false
      t.string :location
      t.date :starts_on
      t.date :ends_on
      t.jsonb :bullets, null: false, default: []
      t.integer :position

      t.timestamps
    end
  end
end
