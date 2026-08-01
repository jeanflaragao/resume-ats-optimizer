class AddOwnerTokenToResumes < ActiveRecord::Migration[8.1]
  def change
    add_column :resumes, :owner_token, :string
    add_index :resumes, :owner_token
  end
end
