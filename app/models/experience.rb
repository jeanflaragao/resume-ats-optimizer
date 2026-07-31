class Experience < ApplicationRecord
  belongs_to :resume

  validates :company, :title, presence: true
end
