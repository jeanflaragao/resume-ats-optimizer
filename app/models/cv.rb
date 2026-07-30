class Cv < ApplicationRecord
  has_many :experiences, -> { order(:position) }, dependent: :destroy
  has_many :educations, -> { order(:position) }, dependent: :destroy
end
