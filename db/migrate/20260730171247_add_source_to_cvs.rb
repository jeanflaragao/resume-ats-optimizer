class AddSourceToCvs < ActiveRecord::Migration[8.0]
  def change
    add_column :cvs, :source, :string
  end
end
