class City < ApplicationRecord
  has_many :city_shops
  has_many :shops, through: :city_shops
end
