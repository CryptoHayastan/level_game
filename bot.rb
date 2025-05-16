require 'telegram/bot'
require_relative 'config/environment'
require 'rufus-scheduler'

TOKEN = ENV['TELEGRAM_BOT_TOKEN']
CHANNEL = '@KukuruznikTM'
CHAT_ID = -1002291429008
SUPERADMINS = User.where(role: 'superadmin')

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
  when 'waiting_for_promo_code'
    promo_code_text = message.text.strip
    promo = PromoCode.find_by(code: promo_code_text)

    if promo.nil?
      bot.api.send_message(chat_id: user.telegram_id, text: "Промокод не найден. Попробуйте ещё раз или отправьте /start для выхода.")
    elsif promo.expired?
      bot.api.send_message(chat_id: user.telegram_id, text: "Промокод истёк.")
    elsif PromoUsage.exists?(user_id: user.id, promo_code_id: promo.id)
      bot.api.send_message(chat_id: user.telegram_id, text: "Вы уже использовали этот промокод.")
    else
      balance_to_add = promo.product_type == 1 ? 5000 : 12000
      user.balance ||= 0
      user.balance += balance_to_add
      user.step = nil
      user.save!

      PromoUsage.create!(user_id: user.id, promo_code_id: promo.id)

      bot.api.send_message(chat_id: user.telegram_id, text: "Промокод принят! Вам начислено #{balance_to_add} очков. Текущий баланс: #{user.balance}.")
    end
  end
end

def create_promo_code(bot, user, shop_id, product_type_str)
  puts "DEBUG: create_promo_code called with bot=#{bot}, user=#{user}, shop_id=#{shop_id}, product_type=#{product_type_str}"

  # ОБЯЗАТЕЛЬНО передаём аргумент (например, 8)
  promo_code = "#{shop_id}:#{product_type_str}:#{SecureRandom.hex(8)}"
  begin
    # Твой код, например:
    expires_at = 2.hours.from_now
    promo = PromoCode.create!(
      code: promo_code,
      shop_id: shop_id,
      product_type: :product1,
      expires_at: expires_at
    )
  rescue => e
    puts "🔥 Ошибка: #{e.message}"
    puts e.backtrace.join("\n")
  end

  if promo.persisted?
    product_name = product_type_str == 1 ? "Продукт 1 (5000 очков)" : "Продукт 2 (12000 очков)"

    bot.api.send_message(
      chat_id: user.telegram_id,
      text: "✅ Промокод создан:\n\n🔤 Код: `#{promo_code}`\n⏳ Действителен 2 часа.\n🎯 Тип: #{product_name}",
      parse_mode: 'Markdown'
    )
  else
    bot.api.send_message(
      chat_id: user.telegram_id,
      text: "❌ Ошибка при создании промокода."
    )
  end
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
          user.update(step: nil)
          kb = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: 'Ввести промокод', callback_data: 'enter_promo')],
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: 'Бонуси', callback_data: 'bonus')]
          ])
          bot.api.send_message(chat_id: user.telegram_id, text: 'Привет! Нажмите кнопку, чтобы ввести промокод.', reply_markup: kb)

        when /^\/start (\d+)$/
          referrer_telegram_id = $1.to_i
          puts "Реферал ID: #{referrer_telegram_id}"

          referrer = User.find_by(telegram_id: referrer_telegram_id)

          if referrer.nil?
            bot.api.send_message(chat_id: user.telegram_id, text: "❌ Реферал с таким ID не найден.")
          elsif referrer.id == user.id
            bot.api.send_message(chat_id: user.telegram_id, text: "⚠️ Вы не можете пригласить сами себя!")
          elsif user.ancestry.present?
            bot.api.send_message(chat_id: user.telegram_id, text: "⚠️ Вы уже были привязаны к другому пользователю.")
          else
            user.ancestry = referrer.id
            if user.save
              referrer.increment!(:balance, 1000)
              bot.api.send_message(chat_id: user.telegram_id, text: "🎉 Реферал успешно засчитан!.")
            else
              # Тут сработала валидация модели, например "User cannot be a descendant of itself"
              error_msg = user.errors.full_messages.join(", ")
              puts "❌ Ошибка при сохранении: #{error_msg}"
              bot.api.send_message(chat_id: user.telegram_id, text: "❌ Не удалось сохранить реферала: #{error_msg}")
            end
          end

        when '/profile'
          bonus_day = user.daily_bonus&.bonus_day.to_i
          bonus_day = 0 if bonus_day > 10
          days_left = 10 - bonus_day
  
          link = user.referral_link
          progress = ("🟩" * bonus_day) + ("⬜" * (10 - bonus_day))
  
          referrals_count = user.children.count
          purchases_count = user.promo_usages.count

          user_info = <<~HTML
            Имя: #{safe_telegram_name(update.from)}
            Баланс: #{user.balance} LOM
            🔗 Ваша ссылка для приглашений <code>https://t.me/Kukuruznik_profile_bot?start=#{user.telegram_id}</code>
            👥 Рефералов: #{referrals_count}
            🛒 Покупок: #{purchases_count}

            📅 Бонус: День #{bonus_day} из 10
            #{progress}
          HTML
  
          buttons = [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "Получить ежедневный бонус", callback_data: "daily_bonus_#{user.telegram_id}")]
          ]
  
          bot.api.send_message(
            chat_id: CHAT_ID,
            text: user_info,
            parse_mode: "HTML",
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
                    [Telegram::Bot::Types::InlineKeyboardButton.new(text: '📍 Управлять городами', callback_data: "edit_cities_#{shop.id}")],
                    [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🎟 Создать промокод', callback_data: "create_promo_#{shop.id}")]
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
        else
          if update.text.present? && !update.sticker && !update.animation && !update.photo && update.chat.id == CHAT_ID
            user.add_message_point!
          end
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
        when /^create_promo_(\d+)$/
          shop = Shop.find_by(id: $1)
          if shop && shop.user_id == user.id
            bot.api.send_message(
              chat_id: user.telegram_id,
              text: "🛍 Какой продукт?\nВыберите тип:",
              reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                inline_keyboard: [
                  [
                    Telegram::Bot::Types::InlineKeyboardButton.new(text: "📦 Продукт 1 (5000 очков)", callback_data: "product1_#{shop.id}"),
                    Telegram::Bot::Types::InlineKeyboardButton.new(text: "🎁 Продукт 2 (12000 очков)", callback_data: "product2_#{shop.id}")
                  ]
                ]
              )
            )
          end

        when /^product1_\d+$/
          shop_id = data.split('_').last.to_i
          create_promo_code(bot, user, shop_id, 1)

        when /^product2_\d+$/
          shop_id = data.split('_').last.to_i
          create_promo_code(bot, user, shop_id, 2)
        when /^bonus_(\d+)$/
          discount = $1.to_i  # 50, 20 или 5

          # Цены бонусов в очках
          bonus_prices = {
            50 => 200_000,
            20 => 100_000,
            5  => 500_000,
            1 => 1_000_000
          }

          price = bonus_prices[discount]

          if user.balance.to_i < price
            bot.api.send_message(
              chat_id: user.telegram_id,
              text: "У вас недостаточно очков для покупки бонуса #{discount}% скидка. Нужно #{price}, у вас #{user.balance}."
            )
            next
          end

          # Списываем очки
          user.balance -= price
          user.step = 'waiting_admin_contact' # блокируем смену имени
          user.save!

          # Сообщение пользователю
          user_message = <<~HTML
            Спасибо за выбор бонуса: #{discount}% скидка! 🎉

            С вашего баланса списано #{price} очков.

            Пожалуйста, подождите, пока с вами свяжется администратор.
            Не меняйте своё имя пользователя до этого момента.
          HTML

          bot.api.send_message(
            chat_id: user.telegram_id,
            text: user_message,
            parse_mode: 'HTML'
          )

          # Собираем данные для суперадминов

          referrals_count = user.children.count

          purchases_info = PromoUsage.joins(:promo_code)
                            .where(user_id: user.id)
                            .group('promo_codes.shop_id')
                            .count

          shops_info = purchases_info.map do |shop_id, count|
            shop = Shop.find_by(id: shop_id)
            "#{shop&.name || 'Неизвестный магазин'}: #{count} покупок"
          end.join("\n")

          username_display = user.username ? "@#{user.username}" : nil
          full_name_display = "#{user.first_name} #{user.last_name}".strip
          display_name = username_display || full_name_display

          admin_message = <<~TEXT
            Пользователь выбрал бонус #{discount}% скидка (#{price} очков):

            Имя пользователя: #{display_name}
            Telegram ID: #{user.telegram_id}
            Роль: #{user.role}
            Баланс: #{user.balance}
            Рефералов: #{referrals_count}
            Покупки:
            #{shops_info.presence || 'Покупок нет'}

            Статус пользователя: #{user.step}
          TEXT

          buttons = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(text: "Посмотреть рефералов", callback_data: "referrals_#{user.id}")
              ]
            ]
          )

          SUPERADMINS.find_each do |admin|
            bot.api.send_message(
              chat_id: admin.telegram_id,
              text: admin_message,
              reply_markup: buttons
            )
          end
        when /^referrals_(\d+)$/
          user_id = $1.to_i
          target_user = User.find_by(id: user_id)
          chat_id = update.callback_query.from.id

          if target_user
            referrals = target_user.children
            puts "Рефералы: #{referrals.map(&:id).join(', ')}"

            if referrals.any?
              keyboard = referrals.map do |ref|
                [
                  Telegram::Bot::Types::InlineKeyboardButton.new(
                    text: safe_telegram_name_html(ref),
                    callback_data: "referral_profile:#{ref.id}"
                  )
                ]
              end

              bot.api.send_message(
                chat_id: chat_id,
                text: "Рефералы пользователя #{safe_telegram_name_html(target_user)}:",
                reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard),
                parse_mode: 'HTML'
              )
            else
              bot.api.send_message(chat_id: chat_id, text: "У пользователя нет рефералов.")
            end
          else
            bot.api.send_message(chat_id: chat_id, text: "Пользователь не найден.")
          end

        when /^referral_profile:(\d+)$/
          ref_user = User.find_by(id: $1)
          if ref_user && superadmin?(from.id)
            referrals_count = User.where(ancestry: ref_user.telegram_id.to_s).count

            shops_info = Shop.joins(:promo_codes => :promo_usages)
                            .where(promo_usages: { user_id: ref_user.id })
                            .distinct
                            .map { |s| "- #{s.name}" }.join("\n")

            profile = <<~TEXT
              Имя пользователя: #{safe_telegram_name_html(ref_user)}
              Telegram ID: #{ref_user.telegram_id}
              Роль: #{ref_user.role}
              Баланс: #{ref_user.balance}
              Рефералов: #{referrals_count}
              Покупки:
              #{shops_info.presence || 'Покупок нет'}

              Статус пользователя: #{ref_user.step}
            TEXT

            bot.api.send_message(chat_id: chat_id, text: profile, parse_mode: 'HTML')
          else
            bot.api.send_message(chat_id: chat_id, text: "Пользователь не найден или нет доступа.")
          end

        when 'enter_promo'
          user.update(step: 'waiting_for_promo_code')
          bot.api.send_message(chat_id: user.telegram_id, text: 'Введите ваш промокод:')
          bot.api.answer_callback_query(callback_query_id: update.id) # убираем часики у кнопки

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
        when 'bonus'
          user.update(step: 'bonus')

          buttons = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '50% скидка', callback_data: 'bonus_50'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '20% скидка', callback_data: 'bonus_20'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '1', callback_data: 'bonus_1'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '0,5',  callback_data: 'bonus_5')
              ]
            ]
          )

          bot.api.send_message(
            chat_id: update.from.id,
            text: "Выберите тип бонуса:",
            reply_markup: buttons
          )
        end
      else
        puts "❔ Неизвестный тип update: #{update.class}"
      end
  
    rescue StandardError => e
      puts "🔥 Ошибка: #{e.message}"
    end
  end
end