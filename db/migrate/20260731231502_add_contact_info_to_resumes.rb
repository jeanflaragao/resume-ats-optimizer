class AddContactInfoToResumes < ActiveRecord::Migration[8.1]
  def change
    add_column :resumes, :name, :string
    add_column :resumes, :email, :string
    add_column :resumes, :phone, :string
  end
end
