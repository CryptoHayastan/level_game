class User < ApplicationRecord
  has_one :daily_bonus, dependent: :destroy

  has_many :referrals_given, class_name: 'Referral', foreign_key: 'referrer_id'
  has_many :referrals_received, class_name: 'Referral', foreign_key: 'referral_id'
end
