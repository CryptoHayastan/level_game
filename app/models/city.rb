class City < ApplicationRecord
  has_many :city_shops, dependent: :destroy
  has_many :shops, through: :city_shops
end
