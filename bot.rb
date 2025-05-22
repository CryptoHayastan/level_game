require 'telegram/bot'
require_relative 'config/environment'
require 'rufus-scheduler'

TOKEN = ENV['TELEGRAM_BOT_TOKEN']
CHANNEL = '@PlanHubTM'
CHANNEL_LINK = 'https://t.me/PlanHubTM'
CHAT_ID = -1002484385346
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
  user.referral_link ||= "https://t.me/PLANhuBot?start=#{user.telegram_id}"
  user.balance ||= 0
  user.score ||= 0
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

def collect_daily_bonus(user, bot, telegram_id, callback_query)
  return unless user && user.telegram_id == telegram_id

  daily_bonus = user.daily_bonus || user.create_daily_bonus(bonus_day: 0)
  now = Time.current

  if daily_bonus.last_collected_at&.to_date == now.to_date
    bot.api.answer_callback_query(
      callback_query_id: callback_query.id,
      text: "📅 Դուք արդեն ստացել եք բոնուսը այսօր։ Վերադարձեք վաղը։"
    )
    return
  end

  if daily_bonus.last_collected_at && daily_bonus.last_collected_at.to_date < now.to_date - 1
    daily_bonus.bonus_day = 0
  end

  daily_bonus.bonus_day += 1
  daily_bonus.last_collected_at = now
  reward = daily_bonus.bonus_day * 100

  user.balance += reward
  user.score += reward
  daily_bonus.save!
  user.save!

  bot.api.answer_callback_query(
    callback_query_id: callback_query.id,
    text: "✅ Բոնուսը ստացվեց՝ +#{reward} միավոր"
  )

  # 🔁 Թարմացնել պրոֆիլը
  bonus_day = daily_bonus.bonus_day > 10 ? 1 : daily_bonus.bonus_day
  progress = ("🟩" * bonus_day) + ("⬜" * (10 - bonus_day))
  referrals_count = user.children.count
  purchases_count = user.promo_usages.count

  user_info = <<~HTML
    Անուն: #{safe_telegram_name(callback_query.from)}
    Բալանս: #{user.balance} LOM
    🔗 Ձեր հրավիրելու հղումը <code>https://t.me/PLANhuBot?start=#{user.telegram_id}</code>
    👥 Ռեֆերալներ: #{referrals_count}
    🛒 Գնումներ: #{purchases_count}

    📅 Բոնուս: Օր #{bonus_day} - 10-ից
    #{progress}
  HTML

  buttons = [
    [Telegram::Bot::Types::InlineKeyboardButton.new(
      text: "Ստանալ օրական բոնուսը", callback_data: "daily_bonus_#{user.telegram_id}"
    )]
  ]

  bot.api.edit_message_text(
    chat_id: callback_query.message.chat.id,
    message_id: callback_query.message.message_id,
    text: user_info,
    parse_mode: "HTML",
    reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
  )
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
   when 'awaiting_yerevan_name'
    name = message.text.strip

    if name.present?
      City.create!(name: name, sub: true)
      bot.api.send_message(
        chat_id: user.telegram_id,
        text: "✅ Տարածքը ավելացվել է: #{name}"
      )
    else
      bot.api.send_message(
        chat_id: user.telegram_id,
        text: "⚠️ Անունը չի կարող լինել դատարկ։ Փորձիր նորից։"
      )
    end

    user.update(step: nil)

    shop = user.shop
    yerevan_places = City.where(sub: true)
    attached_ids = shop.city_ids

    buttons = yerevan_places.map do |city|
      attached = attached_ids.include?(city.id)
      emoji = attached ? '✅' : '➕'
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "#{emoji} #{city.name}",
        callback_data: "toggle_city_#{shop.id}_#{city.id}"
      )
    end.each_slice(2).to_a

    add_yerevan_place_button = Telegram::Bot::Types::InlineKeyboardButton.new(
      text: "➕ Ավելացնել վայր Երևանում",
      callback_data: "add_yerevan_place"
    )

    back_button = Telegram::Bot::Types::InlineKeyboardButton.new(
      text: "🔙 Վերադառնալ",
      callback_data: "edit_cities_#{shop.id}"
    )

    keyboard = [[add_yerevan_place_button]] + buttons + [[back_button]]

    bot.api.send_message(
      chat_id: user.telegram_id,
      text: "📍 Ընտրիր Երևանի տարածքները:",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: keyboard
      )
    )

   when 'awaiting_new_city_name'
    city_name = message.text.strip
    if city_name.empty?
      bot.api.send_message(chat_id: user.telegram_id, text: "❌ Название города не может быть пустым. Пожалуйста, введите корректное название.")
      return
    end

    city = City.find_or_create_by(name: city_name)
    user.update(step: nil)

    bot.api.send_message(chat_id: user.telegram_id, text: "✅ Город *#{city.name}* успешно добавлен в общий список.", parse_mode: 'Markdown')

    shop = user.shop
    all_cities = City.where(sub: [false, nil])
    attached_ids = shop.city_ids

    buttons = all_cities.map do |city|
      attached = attached_ids.include?(city.id)
      emoji = attached ? '✅' : '➕'
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: "#{emoji} #{city.name}",
        callback_data: "toggle_city_#{shop.id}_#{city.id}"
      )
    end.each_slice(2).to_a

    add_general_city_button = Telegram::Bot::Types::InlineKeyboardButton.new(
      text: "➕ Добавить новый город (общий)",
      callback_data: "add_city"
    )

    yerevan_button = Telegram::Bot::Types::InlineKeyboardButton.new(
      text: "🏙️ Երևան",
      callback_data: "show_yerevan_subs"
    )

    bot.api.send_message(
      chat_id: user.telegram_id,
      text: "Выберите города для магазина:",
      reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [[add_general_city_button], [yerevan_button]] + buttons
      )
    )
  when 'waiting_for_promo_code'
    if update && update.text
      promo_code_text = update.text.strip
      promo = PromoCode.find_by(code: promo_code_text)

      if promo.nil?
        bot.api.send_message(chat_id: user.telegram_id, text: "Պրոմոկոդը չի գտնվել։ Փորձեք նորից")
        user.update(step: nil)
      elsif promo.expired?
        bot.api.send_message(chat_id: user.telegram_id, text: "Պրոմոկոդի վավերականությունը սպառվել է։")
        user.update(step: nil)
      elsif PromoUsage.exists?(user_id: user.id, promo_code_id: promo.id)
        bot.api.send_message(chat_id: user.telegram_id, text: "Դուք արդեն օգտագործել եք այս պրոմոկոդը։")
        user.update(step: nil)
      else
        balance_to_add = promo.product_type == 1 ? 3000 : 6000
        user.balance ||= 0
        user.balance += balance_to_add
        user.score += balance_to_add
        user.step = nil
        user.save!

        PromoUsage.create!(user_id: user.id, promo_code_id: promo.id)

        bot.api.send_message(chat_id: user.telegram_id, text: "Պրոմոկոդը հաջողությամբ ընդունվել է։ Դուք ստացաք #{balance_to_add} LOM։ Ներկայիս բալանս՝ #{user.balance} LOM։")
      end
    else
      # Пользователь нажал кнопку или отправил 10 текст
      bot.api.send_message(chat_id: user.telegram_id, text: "Խնդրում ենք ուղարկել տեքստ՝ որպես պրոմոկոդ։")
    end
  end
end

def create_promo_code(bot, user, shop_id, product_type_str)
  # ОБЯЗАТЕЛЬНО передаём аргумент (например, 8)
  promo_code = "#{shop_id}:#{product_type_str}:#{SecureRandom.hex(8)}"
  begin
    # Твой код, например:
    expires_at = 2.hours.from_now
    promo = PromoCode.create!(
      code: promo_code,
      shop_id: shop_id,
      product_type: product_type_str == 1 ? 1 : 2,
      expires_at: expires_at
    )
  rescue => e
    puts "🔥 Ошибка: #{e.message}"
    puts e.backtrace.join("\n")
  end

  if promo.persisted?
    product_name = product_type_str == 1 ? "0,5" : "1"

    message = <<~TEXT
      🔤 Կոդ՝ `#{promo_code}`
      ⏳ Վավեր է՝ 2 ժամ
      🎯 Տեսակ՝ #{product_name}

      📥 Ինչպես օգտագործել․
      1. Բացիր բոտը 👉 [@PLANhuBot](https://t.me/PLANhuBot)
      2. Սեղմիր **«Start»** կամ ուղարկիր հրամանը `/start`
      3. Մուտքագրիր քո կոդը՝ `#{promo_code}`
      4. Ստացիր բոնուսներ կամ հատուկ առաջարկներ 🎁

      ⏰ Ուշադրություն․ Կոդը հասանելի է միայն 2 ժամ։ Մի ուշացիր օգտագործել։
    TEXT

    bot.api.send_message(
      chat_id: user.telegram_id,
      text: "#{message}",
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

  scheduler.every '30m' do
    Shop.where(online: true).find_each do |shop|
      if shop.online_since && shop.online_since < 30.minutes.ago
        shop.update(online: false)

        # Уведомим владельца
        if shop.user&.telegram_id
          bot.api.send_message(
            chat_id: shop.user.telegram_id,
            text: "🔴 Ваш магазин «#{shop.name}» был автоматически отключён через 30 минут."
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

          if user.role == 'shop'
            bot.api.send_message(chat_id: user.telegram_id, text: "👤 Դուք Հաճախորդ չեք։ Խնդրում ենք ուղարկել /my_shop հրամանը")
          else
            full_name = [user.first_name, user.last_name].compact.join(' ')
            balance = user.balance || 0

            info_text = <<~TEXT
              👤 Անուն: #{full_name}
              💰 Բալանս: #{balance} LOM

              Ընտրեք գործողություն 👇
            TEXT

            kb = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🔤 Մուտքագրել պրոմոկոդ', callback_data: 'enter_promo')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🎁 Բոնուսներ', callback_data: 'bonus')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🚀 Բուստ x2՝ 2 ժամով', callback_data: 'activate_boost')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '💬 Մուտք գործել չաթ', url: 'https://t.me/+H3V09Qh9t701YzVh')]
            ])

            bot.api.send_message(chat_id: user.telegram_id, text: info_text.strip, reply_markup: kb)
          end

        when /^\/start (\d+)$/
          referrer_telegram_id = $1.to_i
          referrer = User.find_by(telegram_id: referrer_telegram_id)

            if referrer && referrer.telegram_id != user.telegram_id
            unless user.persisted? && (user.ancestry.present? || user.ban?)
              user.update(pending_referrer_id: referrer.id)
              bot.api.send_message(chat_id: user.telegram_id, text: "📩 Շարունակելու համար խնդրում ենք ուղարկել միանալու հայտը չաթին՝")
              bot.api.send_message(chat_id: user.telegram_id, text: "👉 https://t.me/+H3V09Qh9t701YzVh")
            else
              bot.api.send_message(chat_id: user.telegram_id, text: "⚠️ Դուք արդեն եղել եք չաթի մասնակից և չեք կարող կրկին դառնալ ռեֆերալ։")
              bot.api.send_message(chat_id: user.telegram_id, text: "👉 https://t.me/+H3V09Qh9t701YzVh")
            end
            else
            bot.api.send_message(chat_id: user.telegram_id, text: "⚠️ Անթույլատրելի ռեֆերալ հղում։")
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
            👤 Անուն: #{safe_telegram_name(update.from)}
            💰 Բալանս: #{user.balance} LOM
            🔗 Ձեր հրավիրելու հղումը <code>https://t.me/PLANhuBot?start=#{user.telegram_id}</code>
            👥 Ռեֆերալներ: #{referrals_count}
            🛒 Գնումներ: #{purchases_count}

            📅 Բոնուս: Օր #{bonus_day} - 10-ից
            #{progress}
          HTML

          buttons = [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "🎁 Ստանալ օրական բոնուսը", callback_data: "daily_bonus_#{user.telegram_id}")]
          ]

          bot.api.send_message(
            chat_id: update.chat.id,
            reply_to_message_id: update.message_id,
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
          shops_online = Shop.where(online: true)
          shops_offline = Shop.where(online: false)

          text = "<b>🛍 Հարթակում վստահված Խանութների հղումները՝</b>\n\n"

          if shops_online.any?
            text += "🟢 Կապ (օնլայն):\n"
            shops_online.each do |shop|
              text += "• @#{shop.link}\n"
            end
            text += "\n"
          end

          if shops_offline.any?
            text += "🔴 Կապ չկա (օֆլայն):\n"
            shops_offline.each do |shop|
              text += "• @#{shop.link}\n"
            end
          end

          bot.api.send_message(
            chat_id: update.chat.id,
            text: text,
            parse_mode: 'HTML'
          )
        when '/map'
          general_cities = City.where(sub: [false, nil])
          yerevan_button = Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "🏙 Երևան",
            callback_data: "yerevan_map"
          )

          city_buttons = general_cities.map do |city|
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: city.name,
              callback_data: "city_#{city.id}"
            )
          end

          # группируем по 2 в ряд
          keyboard = [[yerevan_button]] + city_buttons.each_slice(2).to_a

          markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)

          bot.api.send_message(
            chat_id: update.chat.id,
            text: "🏙 Ընտրեք քաղաքը 👇",
            reply_markup: markup
          )

        when '/top'
          top_users = User.order(score: :desc).limit(10)

            message = "🏆 Թոփ 10 օգտատերեր միավորներով՝\n\n"
          top_users.each_with_index do |u, i|
            name = u.username.present? ? "@#{u.username}" : "#{u.first_name} #{u.last_name}"
            message += "#{i + 1}. #{name} — #{u.score} LOM\n"
          end

          bot.api.send_message(chat_id: CHAT_ID, text: message)

        when '/admin'
          if user.role == 'superadmin'
            kb = [
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '📋 Все магазины', callback_data: 'list_shops')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавить магазин', callback_data: 'add_shop')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🧨 Обнулить очки пользователей', callback_data: 'confirm_reset_scores')]
            ]

            markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
            bot.api.send_message(chat_id: user.telegram_id, text: "🔧 Панель администратора", reply_markup: markup)
          end

        when '/cancel'
          user.update(step: nil)
          bot.api.send_message(chat_id: user.telegram_id, text: "🚫 Действие отменено.")
        when '/ban'
          if update.reply_to_message
            chat_id = update.chat.id

            if user&.role == 'superadmin'
              target_id = update.reply_to_message.from.id
              begin
                bot.api.banChatMember(chat_id: chat_id, user_id: target_id)
                bot.api.send_message(chat_id: chat_id, text: "🚫 Օգտատերը արգելափակված է։")
              rescue => e
                bot.api.send_message(chat_id: chat_id, text: "❌ Օգտատիրոջը արգելափակել չհաջողվեց: #{e.update}")
              end
            else
                bot.api.send_message(chat_id: chat_id, text: "❌ Դուք չունեք դրա համար իրավունքներ։")
            end
          else
            bot.api.send_message(chat_id: update.chat.id, text: "⛔ Օգտագործեք այս հրամանը՝ ի պատասխան այն օգտատիրոջ հաղորդագրությանը, որին ցանկանում եք արգելափակել։")
          end
        else
          if update.text.present? && !update.sticker && !update.animation && !update.photo && update.chat.id == CHAT_ID
            user.add_message_point!
            points = user.active_boost ? 2 : 1
            user.increment!(:score, points)
          end
        end
  
      when Telegram::Bot::Types::CallbackQuery
        data = update.data
  
        case data
        when /^daily_bonus_/
          telegram_id = data.split('_').last.to_i
          collect_daily_bonus(user, bot, telegram_id, update)

        when /^city_/
          bot.api.answer_callback_query(callback_query_id: update.id)

          city_id = update.data.split('_').last.to_i
          city = City.find_by(id: city_id)

          if city.nil?
            bot.api.answer_callback_query(callback_query_id: update.id, text: "Քաղաքը չի գտնվել։", show_alert: true)
            return
          end

          shops = city.shops

          shop_list = if shops.any?
                        shops.map do |shop|
                          status = shop.online ? "🟢" : "🔴"
                          "• @#{shop.link} #{status}"
                        end.join("\n")
                      else
                        "❌ Այս քաղաքում խանութներ չկան։"
                      end

          buttons = [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: "🔙 Վերադառնալ քաղաքներ", callback_data: "map")]
          ]

          bot.api.edit_message_text(
            chat_id: CHAT_ID,
            message_id: update.message.message_id,
            text: "🏙 <b>Քաղաք՝</b> #{city.name}\n\n#{shop_list}",
            parse_mode: 'HTML',
            reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
          )

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
              bot.api.send_message(chat_id: user.telegram_id, text: "🟢 Магазин включён. Автоотключение через 30 минут.")
            end
          else
            bot.api.send_message(chat_id: user.telegram_id, text: "❌ Магазин не найден.")
          end

        when /^edit_cities_(\d+)$/
          shop = Shop.find_by(id: $1)

          if shop && shop.user_id == user.id
            all_cities = City.where(sub: [false, nil])
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

             yerevan_button = Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "🏙️ Երևան",
              callback_data: "show_yerevan_subs"
            )

            bot.api.edit_message_text(
              chat_id: user.telegram_id,
              message_id: update.message.message_id,
              text: "Выберите города для магазина:",
              reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                inline_keyboard: [[add_general_city_button],[yerevan_button]] + buttons
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

            attached_ids = shop.city_ids

            if city.sub # 🟡 Обновляем только ереванские места
              yerevan_places = City.where(sub: true)
              buttons = yerevan_places.map do |place|
                attached = attached_ids.include?(place.id)
                emoji = attached ? '✅' : '➕'
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "#{emoji} #{place.name}",
                  callback_data: "toggle_city_#{shop.id}_#{place.id}"
                )
              end.each_slice(2).to_a

              add_yerevan_place_button = Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "➕ Ավելացնել վայր Երևանում",
                callback_data: "add_yerevan_place"
              )

              back_button = Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "🔙 Վերադառնալ",
                callback_data: "edit_cities_#{shop.id}"
              )

              keyboard = [[add_yerevan_place_button]] + buttons + [[back_button]]

              bot.api.edit_message_reply_markup(
                chat_id: user.telegram_id,
                message_id: update.message.message_id,
                reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                  inline_keyboard: keyboard
                )
              )
            else # 🔵 Обычные города
              all_cities = City.where(sub: [false, nil])
              buttons = all_cities.map do |c|
                attached = attached_ids.include?(c.id)
                emoji = attached ? '✅' : '➕'
                Telegram::Bot::Types::InlineKeyboardButton.new(
                  text: "#{emoji} #{c.name}",
                  callback_data: "toggle_city_#{shop.id}_#{c.id}"
                )
              end.each_slice(2).to_a

              add_general_city_button = Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "➕ Добавить новый город (общий)",
                callback_data: "add_city"
              )

              yerevan_button = Telegram::Bot::Types::InlineKeyboardButton.new(
                text: "🏙️ Երևան",
                callback_data: "show_yerevan_subs"
              )

              keyboard = [[add_general_city_button], [yerevan_button]] + buttons

              bot.api.edit_message_reply_markup(
                chat_id: user.telegram_id,
                message_id: update.message.message_id,
                reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                  inline_keyboard: keyboard
                )
              )
            end
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
                    Telegram::Bot::Types::InlineKeyboardButton.new(text: "0,5", callback_data: "product1_#{shop.id}"),
                    Telegram::Bot::Types::InlineKeyboardButton.new(text: "1", callback_data: "product2_#{shop.id}")
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
            50 => 35_000,
            20 => 10_000,
            5  => 50_000,
            1 => 100_000
          }

          price = bonus_prices[discount]
            if user.balance.to_i < price
            bot.api.send_message(
              chat_id: user.telegram_id,
              text: "Ձեր միավորները բավարար չեն #{discount}% զեղչի բոնուսը ստանալու համար։ Անհրաժեշտ է #{price}, ձեր բալանսը՝ #{user.balance}։"
            )
            next
            end

            # Սահմանում ենք միավորները
            user.balance -= price
            user.step = 'waiting_admin_contact' # արգելափակում ենք անունը փոխելը
            user.save!

            # Հաղորդագրություն օգտատիրոջը
            user_message = <<~HTML
            Շնորհակալություն բոնուս ընտրելու համար՝ #{discount}% զեղչ! 🎉

            Ձեր բալանսից հանվել է #{price} LOM։

            Խնդրում ենք սպասել, մինչ ադմինիստրատորը կապ կհաստատի ձեզ հետ։
            Մինչ այդ մի փոխեք ձեր օգտանունը։
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
            bot.api.send_message(chat_id: user.telegram_id, text: 'Մուտքագրեք ձեր պրոմոկոդը:')
          bot.api.answer_callback_query(callback_query_id: update.id) # убираем часики у кнопки

        when 'add_city'
          user.update(step: 'awaiting_new_city_name')
          bot.api.send_message(chat_id: user.telegram_id, text: "Введите название нового города для общего списка:")

        when 'add_shop'
          user.update(step: 'awaiting_username_for_shop')
          bot.api.send_message(chat_id: user.telegram_id, text: "👤 Введите username пользователя для нового магазина: \\n Или напишите /cancel чтобы отменить")
          
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
        
        when 'yerevan_map'
          yerevan_places = City.where(sub: true)

          if yerevan_places.any?
            place_buttons = yerevan_places.map do |place|
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: place.name,
                callback_data: "city_#{place.id}"
              )
            end.each_slice(2).to_a

            back_button = Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "🔙 Վերադառնալ",
              callback_data: "map"
            )

            keyboard = place_buttons + [[back_button]]

            bot.api.edit_message_text(
              chat_id: CHAT_ID,
              message_id: update.message.message_id,
              text: "📍 Ընտրիր Երևանի տարածքը:",
              reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
            )
          else
            bot.api.edit_message_text(
              chat_id: CHAT_ID,
              message_id: update.message.message_id,
              text: "❌ Երևանում տարածքներ չկան։"
            )
          end
        
        when 'map'
          general_cities = City.where(sub: [false, nil])
          yerevan_button = Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "🏙 Երևան",
            callback_data: "yerevan_map"
          )

          city_buttons = general_cities.map do |city|
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: city.name,
              callback_data: "city_#{city.id}"
            )
          end

          # группируем по 2 в ряд
          keyboard = [[yerevan_button]] + city_buttons.each_slice(2).to_a

          markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)

          bot.api.edit_message_text(
            chat_id: CHAT_ID,
            message_id: update.message.message_id,
            text: "🏙 Ընտրեք քաղաքը 👇",
            reply_markup: markup
          )

        when 'show_yerevan_subs'
          shop = user.shop
          next unless shop

          yerevan_places = City.where(sub: true)
          attached_ids = shop.city_ids

          buttons = yerevan_places.map do |city|
            attached = attached_ids.include?(city.id)
            emoji = attached ? '✅' : '➕'
            Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "#{emoji} #{city.name}",
              callback_data: "toggle_city_#{shop.id}_#{city.id}"
            )
          end.each_slice(2).to_a

          # Кнопка "Добавить место в Ереване"
          add_yerevan_place_button = Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "➕ Ավելացնել վայր Երևանում",
            callback_data: "add_yerevan_place"
          )

          # Кнопка "Назад"
          back_button = Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "🔙 Վերադառնալ",
            callback_data: "edit_cities_#{shop.id}"
          )

          keyboard = [[add_yerevan_place_button]] + buttons + [[back_button]]

          bot.api.edit_message_text(
            chat_id: user.telegram_id,
            message_id: update.message.message_id,
            text: "📍 Ընտրիր Երևանի տարածքները:",
            reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
              inline_keyboard: keyboard
            )
          )

        when 'add_yerevan_place'
          user.update(step: 'awaiting_yerevan_name')

          bot.api.send_message(
            chat_id: user.telegram_id,
            text: "✍️ Մուտքագրիր Երևանի տարածքի անունը, որ ուզում ես ավելացնել։"
          )

        when 'bonus'
          user.update(step: 'bonus')

          buttons = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '20% զեղչ', callback_data: 'bonus_20'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '50% զեղչ', callback_data: 'bonus_50'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '0,5',  callback_data: 'bonus_5'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '1', callback_data: 'bonus_1')
              ]
            ]
          )

            bot.api.send_message(
            chat_id: update.from.id,
            text: "Ընտրեք բոնուսի տեսակը՝\n\n🟢 50% զեղչ — 35.000 LOM\n🟡 20% զեղչ — 10.000 LOM\n💎 0.5 — 50.000 LOM\n💎 1 — 100.000 LOM",
            reply_markup: buttons
            )
        when 'activate_boost'
          if user.boost_today?
            bot.api.answer_callback_query(
              callback_query_id: update.id,
              text: "❗️Вы уже использовали буст сегодня. Попробуйте завтра."
            )
          else
            user.boosts.create!(activated_at: Time.current)
            bot.api.answer_callback_query(
              callback_query_id: update.id,
              text: "🚀 Буст x2 активирован на 2 часа!"
            )

            bot.api.send_message(
              chat_id: user.telegram_id,
              text: "Ваш буст активен! В течение 2 часов ваши сообщения будут считаться x2!"
            )
          end
        
        when 'check_subscription'
          user_id = user.telegram_id
          begin
            chat_member = bot.api.get_chat_member(chat_id: CHANNEL, user_id: user_id)
            status = chat_member.status rescue nil

            if %w[member administrator creator].include?(status)
              bot.api.approve_chat_join_request(chat_id: CHAT_ID, user_id: user_id)
              user.update(step: 'approved')

              # Удаляем кнопки после проверки
              if update.message
                bot.api.edit_message_reply_markup(
                  chat_id: update.message.chat.id,
                  message_id: update.message.message_id,
                  reply_markup: nil
                )
              end

              bot.api.send_message(chat_id: user_id, text: "✅ Բարի գալուստ չատ!")

              # Отображаем имя
              name = user&.username.present? ? "@#{user.username}" : "#{[user&.first_name, user&.last_name].compact.join(' ')}"
              bot.api.send_message(chat_id: CHAT_ID, text: "✅ Բարի գալուստ չատ! #{name}")

              # === НАЧИСЛЕНИЕ ОЧКОВ ===
              if user.pending_referrer_id.present? && user.ancestry.blank?
                referrer = User.find_by(id: user.pending_referrer_id)

                if referrer && !user.ban? && user.step == 'approved'
                  user.update(ancestry: referrer.id, pending_referrer_id: nil)
                  referrer.increment!(:balance, 2000)
                  referrer.increment!(:score, 2000)

                    bot.api.send_message(chat_id: referrer.telegram_id, text: "🎉 Նոր օգտատեր միացավ ձեր հղումով։ Դուք ստացել եք 2.000 LOM։")
                end
              end
              # =========================

            else
              bot.api.answer_callback_query(
                callback_query_id: update.id,
                text: "❗️Դուք դեռ բաժանորդագրված չեք։",
                show_alert: true
              )
            end
          rescue => e
            puts "Ошибка при проверке подписки: #{e.message}"
            bot.api.answer_callback_query(
              callback_query_id: update.id,
              text: "❌ Սխալ առաջացավ։",
              show_alert: true
            )
          end
        when 'confirm_reset_scores'
          if user.role == 'superadmin'
            kb = [
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Да, обнулить', callback_data: 'reset_scores')],
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '❌ Отмена', callback_data: 'cancel_reset')]
            ]

            markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: kb)
            bot.api.send_message(chat_id: user.telegram_id, text: "⚠️ Вы уверены, что хотите обнулить все очки пользователей?", reply_markup: markup)
          end
        when 'cancel_reset'
          if user.role == 'superadmin'
            bot.api.send_message(chat_id: user.telegram_id, text: "❌ Обнуление отменено.")
          end
        when 'reset_scores'
          if user.role == 'superadmin'
            User.update_all(score: 0)
            bot.api.send_message(chat_id: user.telegram_id, text: "✅ Очки всех пользователей обнулены.")
          else
            bot.api.send_message(chat_id: user.telegram_id, text: "❌ У вас нет доступа.")
          end
        end
      
      when Telegram::Bot::Types::ChatJoinRequest
        user_id = update.from.id
        chat_id = update.chat.id

        next if user.nil?

        if user.ban
          bot.api.send_message(chat_id: user.telegram_id, text: "❌ Դուք նախկինում լքել եք չատը և չեք կարող կրկին միանալ։")
        else
          markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Շարունակել', callback_data: 'check_subscription')]
            ]
          )

          rules_text = "Բարև և բարի գալուստ PlanHub! \n🎉 Մենք ուրախ ենք ձեզ տեսնել մեր հարթակում։\n👉 Անդամակցելով մեր համայնքին, դուք ընդունում եք մեր կանոնները։\n❗️ Պարտադիր է հետևել մեր [Կանալին]( @PlanHubTM ), որպեսզի կարողանաք շարունակել:\n\nՀիշեցում\n📄 Հարթակում կարող են հայտնվել տվյալներ, որոնք նախատեսված են 18+ տարիքի օգտատերերի համար։\n🔐 Անհրաժեշտ է լինել զգոն ու պատասխանատու՝ օգտագործելով համացանցի բոլոր ռեսուրսները։\n\n✨ Կառուցել ենք հարմարավետ միջավայր՝ բոլորի համար:\nՍեղմեք \"Շարունակել\"՝ անդամակցությունը հաստատելու համար։"

          user.update(step: 'pending')
          bot.api.send_message(chat_id: user.telegram_id, text: "Внимание 18+\nУ нас присутствует контент строго для 18+\nВсё это взято из открытого доступа в просторах интернета")
          bot.api.send_message(chat_id: user.telegram_id, text: rules_text, reply_markup: markup)
        end
      else
        puts "❔ Неизвестный тип update: #{update.class}"
      end
  
    rescue StandardError => e
      puts "🔥 Ошибка: #{e.message}"
    end
  end
end