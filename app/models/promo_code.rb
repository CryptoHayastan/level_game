class PromoCode < ApplicationRecord
  belongs_to :shop
  has_many :promo_usages

  PRODUCT_TYPES = {
    1 => 'product1',
    2 => 'product2'
  }.freeze

  def product_type_str
    PRODUCT_TYPES[product_type]
  end

  def product_type_str=(str)
    self.product_type = PRODUCT_TYPES.key(str)
  end

  def expired?
    Time.current > expires_at
  end
end
