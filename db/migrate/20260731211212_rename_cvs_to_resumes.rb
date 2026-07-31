class RenameCvsToResumes < ActiveRecord::Migration[8.1]
  def change
    rename_table :cvs, :resumes
    rename_column :experiences, :cv_id, :resume_id
    rename_column :educations, :cv_id, :resume_id
  end
end
