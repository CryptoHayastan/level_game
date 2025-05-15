class PromoUsage < ApplicationRecord
  belongs_to :promo_code
  belongs_to :user
end
