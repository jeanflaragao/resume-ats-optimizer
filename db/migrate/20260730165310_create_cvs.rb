class CreateCvs < ActiveRecord::Migration[8.0]
  def change
    create_table :cvs do |t|
      t.text :summary
      t.jsonb :skills, null: false, default: []

      t.timestamps
    end
  end
end
