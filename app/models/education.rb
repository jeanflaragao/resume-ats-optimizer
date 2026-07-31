class Education < ApplicationRecord
  belongs_to :resume

  validates :school, presence: true
end
