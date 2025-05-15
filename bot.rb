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

def steps(user, update, bot)
  message = update
  case user.step
  when 'awaiting_username_for_shop'
    username = message.text.delete_prefix('@').strip
    target_user = User.find_by(username: username)

    if target_user
      # Создаём магазин сразу без запроса названия
      shop = Shop.create!(
        name: safe_telegram_name(target_user),
        link: target_user.username,
        user_id: target_user.id,
        online: false
      )
      target_user.update!(role: 'shop')

      bot.api.send_message(
        chat_id: user.telegram_id,
        text: "✅ Магазин «#{shop.name}» создан и привязан к @#{target_user.username}"
      )
    else
      bot.api.send_message(chat_id: user.telegram_id, text: "❌ Пользователь с username @#{username} не найден.")
    end

    user.update(step: nil)
   when 'awaiting_new_city_name'
    city_name = message.text.strip
    if city_name.empty?
      bot.api.send_message(chat_id: user.telegram_id, text: "❌ Название города не может быть пустым. Пожалуйста, введите корректное название.")
      return
    end

    city = City.find_or_create_by(name: city_name)
    user.update(step: nil)

    bot.api.send_message(chat_id: user.telegram_id, text: "✅ Город *#{city.name}* успешно добавлен в общий список.", parse_mode: 'Markdown')
  end
end

def generate_promo_code
  random_part = SecureRandom.alphanumeric(8).upcase
  "#{id}_#{random_part}"
end

Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "Бот запущен..."

  scheduler = Rufus::Scheduler.new

  scheduler.every '60m' do
    Shop.where(online: true).find_each do |shop|
      if shop.online_since && shop.online_since < 60.minutes.ago
        shop.update(online: false)

        # Уведомим владельца
        if shop.user&.telegram_id
          bot.api.send_message(
            chat_id: shop.user.telegram_id,
            text: "🔴 Ваш магазин «#{shop.name}» был автоматически отключён через 60 минут."
          )
        end
      end
    end
  end


  bot.listen do |update|
    begin
      user = find_or_update_user(update)

      if user&.role == 'superadmin' || user&.role == 'shop'
        steps(user, update, bot)
      end
  
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

        when '/my_shop'
          if user.role == 'shop'
            shop = Shop.find_by(user_id: user.id)

            if shop
              shop_info = <<~TEXT
                Магазин: #{shop.name}
                Link: #{shop.link}
                Статус: #{shop.online ? '🟢 Онлайн' : '🔴 Оффлайн'}
                Города: #{shop.cities.map(&:name).join(', ')}
              TEXT

              toggle_button = Telegram::Bot::Types::InlineKeyboardButton.new(
                text: shop.online ? '🔴 Отключить онлайн' : '🟢 Включить онлайн',
                callback_data: "toggle_online_#{shop.id}"
              )

              bot.api.send_message(
                chat_id: user.telegram_id,
                text: shop_info,
                reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                  inline_keyboard: [
                    [toggle_button],
                    [Telegram::Bot::Types::InlineKeyboardButton.new(text: '📍 Управлять городами', callback_data: "edit_cities_#{shop.id}")]
                  ]
                )
              )
            end
          end

        when '/kap'
          cities = City.all

          city_buttons = cities.map do |city|

            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: city.name,
              callback_data: "city_#{city.id}"
            )
          end
          city_buttons = city_buttons.each_slice(2).to_a
          city_buttons << [Telegram::Bot::Types::InlineKeyboardButton.new(text: "Назад", callback_data: "back_to_main_menu")]
          
          bot.api.send_message(
            chat_id: CHAT_ID,
            text: "Выберите город:",
            reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: city_buttons)
          )

        when '/admin'
          if user.role == 'superadmin'
            kb = [
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '📋 Все магазины', callback_data: 'list_shops')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавить магазин', callback_data: 'add_shop')]
            ]

            markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
            bot.api.send_message(chat_id: user.telegram_id, text: "🔧 Панель администратора", reply_markup: markup)
          end

        when '/cancel'
          user.update(step: nil)
          bot.api.send_message(chat_id: user.telegram_id, text: "🚫 Действие отменено.")

        end
  
      when Telegram::Bot::Types::CallbackQuery
        data = update.data
  
        case data
        when /^daily_bonus_/
          telegram_id = data.split('_').last.to_i
          collect_daily_bonus(user, bot, telegram_id)

        when /^city_/
          city_id = data.split('_').last.to_i
          city = City.find_by(id: city_id)

        when /^delete_shop_(\d+)$/
          shop_id = $1.to_i
          shop = Shop.find_by(id: shop_id)

          if shop
            User.find(shop.user_id).update(role: 'user')
            shop.destroy
            bot.api.send_message(chat_id: update.from.id, text: "🗑 Магазин успешно удалён.")
          else
            bot.api.send_message(chat_id: update.from.id, text: "❌ Магазин не найден.")
          end

        when /^toggle_online_(\d+)$/
          shop = Shop.find_by(id: $1.to_i)

          if shop && shop.user_id == user.id
            if shop.online
              shop.update(online: false)
              bot.api.send_message(chat_id: user.telegram_id, text: "🔴 Магазин отключён.")
            else
              shop.update(online: true, online_since: Time.current)  # online_since — новая колонка
              bot.api.send_message(chat_id: user.telegram_id, text: "🟢 Магазин включён. Автоотключение через 60 минут.")
            end
          else
            bot.api.send_message(chat_id: user.telegram_id, text: "❌ Магазин не найден.")
          end

        when /^edit_cities_(\d+)$/
          shop = Shop.find_by(id: $1)

          if shop && shop.user_id == user.id
            all_cities = City.all
            attached_ids = shop.city_ids

            buttons = all_cities.map do |city|
              attached = attached_ids.include?(city.id)
              emoji = attached ? '✅' : '➕'
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "#{emoji} #{city.name}",
                callback_data: "toggle_city_#{shop.id}_#{city.id}"
              )
            end.each_slice(2).to_a

            # ➕ Кнопка сверху
            add_general_city_button = Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "➕ Добавить новый город (общий)",
              callback_data: "add_city"
            )

            bot.api.edit_message_text(
              chat_id: user.telegram_id,
              message_id: update.message.message_id,
              text: "Выберите города для магазина:",
              reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                inline_keyboard: [[add_general_city_button]] + buttons
              )
            )
          end

        when /^toggle_city_(\d+)_(\d+)$/
          shop = Shop.find_by(id: $1)
          city = City.find_by(id: $2)

          if shop && city && shop.user_id == user.id
            if shop.cities.exists?(city.id)
              shop.cities.delete(city)
            else
              shop.cities << city
            end

            # Обновляем кнопки
            all_cities = City.all
            attached_ids = shop.city_ids

            buttons = all_cities.map do |c|
              attached = attached_ids.include?(c.id)
              emoji = attached ? '✅' : '➕'
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "#{emoji} #{c.name}",
                callback_data: "toggle_city_#{shop.id}_#{c.id}"
              )
            end.each_slice(2).to_a

            bot.api.edit_message_reply_markup(
              chat_id: user.telegram_id,
              message_id: update.message.message_id,
              reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                inline_keyboard: buttons
              )
            )
          end
        when 'add_city'
          user.update(step: 'awaiting_new_city_name')
          bot.api.send_message(chat_id: user.telegram_id, text: "Введите название нового города для общего списка:")

        when 'add_shop'
          user.update(step: 'awaiting_username_for_shop')
          bot.api.send_message(chat_id: user.telegram_id, text: "👤 Введите username пользователя для нового магазина:\\n Или напишите /cancel чтобы отменить")
          
        when 'list_shops'
          shops = Shop.all
          if shops.any?
            shops.each do |shop|
              shop_text = "🏪 Магазин: *#{shop.name}*\n👤 Владелец: @#{User.find(shop.user_id)&.username || 'не найден'}"

              kb = [
                [
                  Telegram::Bot::Types::InlineKeyboardButton.new(text: '🗑 Удалить', callback_data: "delete_shop_#{shop.id}")
                ]
              ]
              markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)

              bot.api.send_message(
                chat_id: update.from.id,
                text: shop_text,
                reply_markup: markup,
                parse_mode: 'Markdown'
              )
            end
          else
            bot.api.send_message(chat_id: update.from.id, text: "❌ Магазины не найдены.")
          end

        end
      else
        puts "❔ Неизвестный тип update: #{update.class}"
      end
  
    rescue StandardError => e
      puts "🔥 Ошибка: #{e.message}"
    end
  end
end