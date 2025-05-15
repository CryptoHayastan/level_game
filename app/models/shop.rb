class Shop < ApplicationRecord
  belongs_to :user
  
  has_many :city_shops, dependent: :destroy
  has_many :cities, through: :city_shops
end
