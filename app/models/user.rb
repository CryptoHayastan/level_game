class User < ApplicationRecord
  has_ancestry
  has_one :daily_bonus, dependent: :destroy
end
