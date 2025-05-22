class User < ApplicationRecord
  has_ancestry
  has_one :daily_bonus, dependent: :destroy
  has_one :shop, dependent: :destroy
  has_one :message_count, dependent: :destroy
  has_many :promo_usages, dependent: :destroy
  has_many :boosts, dependent: :destroy
  
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

    points = active_boost ? 2 : 1
    increment!(:balance, points)
  end

  def active_boost
    boosts.order(activated_at: :desc).find { |b| b.active? }
  end

  def boost_today?
    boosts.any? { |b| b.today_used? }
  end
end
