require 'telegram/bot'
require_relative 'config/environment'
require 'rufus-scheduler'

TOKEN = ENV['TELEGRAM_BOT_TOKEN']
CHANNEL = '@KukuruznikTM'
CHAT_ID = -1002291429008

def find_or_update_user(update)
  return unless update.respond_to?(:from) && update.from

  user_id = update.from.id
  username = update.from.username || ''
  first_name = update.from.first_name || ''
  last_name = update.from.last_name || ''

  chat_id =
    if update.respond_to?(:chat) && update.chat&.title && update.chat&.id
      update.chat.id
    elsif update.respond_to?(:message) && update.message&.chat&.id
      update.message.chat.id
    end

  user = User.find_or_initialize_by(telegram_id: user_id)
  user.username = username
  user.first_name = first_name
  user.last_name = last_name
  user.role ||= 'user'
  user.step ||= 'start'
  user.ban ||= false
  user.parent_access ||= true # по умолчанию сам по себе
  user.referral_link ||= "https://t.me/Kukuruznik_profile_bot?start=#{user.telegram_id}"
  user.balance ||= 0
  user.save!

  user
end

def admin_user?(bot, chat_id, user_id)
  begin
    admins = bot.api.getChatAdministrators(chat_id: chat_id)

    is_admin = admins.any? { |admin| admin.user.id.to_i == user_id.to_i }

    if is_admin
      user = User.find_by(telegram_id: user_id)
      if user && user.role != 'admin'
        if user.role != 'superadmin'
          user.update(role: 'admin')
        end
      end
    end

    is_admin
  rescue => e
    puts "Ошибка при проверке админа: #{e.message}"
    false
  end
end

def safe_telegram_name(u)
  if u.first_name.present? || u.last_name.present?
    [
      u.first_name&.gsub('_', '\\_'),
      u.last_name&.gsub('_', '\\_')
    ].compact.join(' ')
  elsif u.username.present?
    "@#{u.username.gsub('_', '\\_')}"
  else
    "Без имени"
  end
end

def collect_daily_bonus(user, bot, telegram_id)
  if user.telegram_id == telegram_id
    daily_bonus = user.daily_bonus || user.create_daily_bonus(bonus_day: 0)

    now = Time.current

    if daily_bonus.last_collected_at&.to_date == now.to_date
      bot.api.send_message(chat_id: CHAT_ID, text: "📅 Вы уже собрали бонус сегодня. Возвращайтесь завтра!")
      return
    end

    if daily_bonus.last_collected_at && daily_bonus.last_collected_at.to_date < now.to_date - 1
      daily_bonus.bonus_day = 0 # сброс если день пропущен
    end

    daily_bonus.bonus_day += 1
    daily_bonus.last_collected_at = now

    reward = daily_bonus.bonus_day * 10
    user.balance += reward

    daily_bonus.save!
    user.save!

    if daily_bonus.bonus_day > 10
      daily_bonus.bonus_day = 1
    else
      bot.api.send_message(chat_id: CHAT_ID, text: "✅ День #{daily_bonus.bonus_day} — вы получили #{reward} очков!")
    end
  end
end

Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "Бот запущен..."


  bot.listen do |update|
    begin
      user = find_or_update_user(update)
  
      case update
      when Telegram::Bot::Types::Message
        text = update.text
  
        case text
        when '/start'
          # Отправляем приветственное сообщение пользователю
          bot.api.send_message(chat_id: user.telegram_id, text: "Բարև #{safe_telegram_name(user)}! Բարի գալուստ բոտ։")
        when /^\/start (\d+)$/
          referrer_telegram_id = $1.to_i
          puts "Реферал ID: #{referrer_telegram_id}"
        
          referrer = User.find_by(telegram_id: referrer_telegram_id)
        
          # Проверка: пользователь не сам себе и ещё не был привязан
          if user.telegram_id != referrer_telegram_id && user.ancestry.nil?
            if referrer.present?
              user.update(ancestry: referrer.id)
              referrer.increment!(:balance, 1000)
              puts "✅ Успешно назначен #{referrer.id} как родитель для #{user.id}"
            else
              puts "❌ Реферер не найден"
            end
          else
            puts "⚠️ Пользователь не может быть сам себе или уже был привязан"
          end

        when '/profile'
          bonus_day = user.daily_bonus&.bonus_day.to_i
          bonus_day = 0 if bonus_day > 10
          days_left = 10 - bonus_day
  
          link = user.referral_link
          progress = "Прогресс: " + ("🟩" * bonus_day) + ("⬜" * (10 - bonus_day))
  
          referrals_count = user.children.count

          user_info = <<~TEXT
            Имя: #{safe_telegram_name(update.from)}
            Баланс: #{user.balance}$
            Роль: #{user.role}
            🔗 Ваша ссылка для приглашений: #{user.referral_link}
            👥 Рефералов: #{referrals_count}
            
            📅 Бонус: День #{bonus_day} из 10
            #{progress}
          TEXT
  
          buttons = [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "Пополнить баланс", callback_data: "deposit")],
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "Получить ежедневный бонус", callback_data: "daily_bonus_#{user.telegram_id}")]
          ]
  
          bot.api.send_message(
            chat_id: CHAT_ID,
            text: user_info,
            reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
          )
        end
  
      when Telegram::Bot::Types::CallbackQuery
        data = update.data
  
        case data
        when /^daily_bonus_/
          telegram_id = data.split('_').last.to_i
          collect_daily_bonus(user, bot, telegram_id)
        end
      else
        puts "❔ Неизвестный тип update: #{update.class}"
      end
  
    rescue StandardError => e
      puts "🔥 Ошибка: #{e.message}"
    end
  end
end