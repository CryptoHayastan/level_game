class Boost < ApplicationRecord
  belongs_to :user

  def active?
    activated_at.present? && activated_at > 2.hours.ago
  end

  def today_used?
    activated_at.present? && activated_at.to_date == Time.current.to_date
  end
end
