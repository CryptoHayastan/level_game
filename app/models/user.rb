class User < ApplicationRecord
  has_ancestry
  has_one :daily_bonus, dependent: :destroy
  has_one :shop, dependent: :destroy
  has_one :message_count, dependent: :destroy
  has_many :promo_usages, dependent: :destroy
  
  after_create :create_message_count

  validate :cannot_be_own_ancestor

  def cannot_be_own_ancestor
    if ancestry.present? && id.present? && ancestry.to_s.split('/').include?(id.to_s)
      errors.add(:ancestry, "User cannot be a descendant of itself")
    end
  end

  def add_message_point!
    mc = message_count || create_message_count
    mc.increment!(:count)
    increment!(:balance)
  end
end
