class CreateEducations < ActiveRecord::Migration[8.0]
  def change
    create_table :educations do |t|
      t.references :cv, null: false, foreign_key: true
      t.string :school, null: false
      t.string :degree
      t.string :field_of_study
      t.date :starts_on
      t.date :ends_on
      t.integer :position

      t.timestamps
    end
  end
end
