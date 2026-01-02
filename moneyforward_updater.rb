#!/usr/bin/env ruby
# frozen_string_literal: true

require 'selenium-webdriver'
require 'dotenv/load'
require 'logger'
require 'fileutils'

class MoneyForwardUpdater
  MONEYFORWARD_URL = 'https://moneyforward.com'
  LOGIN_URL = "#{MONEYFORWARD_URL}/users/sign_in"
  ACCOUNTS_URL = "#{MONEYFORWARD_URL}/accounts"

  # 待機時間の定数
  WAIT_TIME = 2
  ADDITIONAL_AUTH_TIMEOUT = 30

  def initialize(email: nil, password: nil, headless: true)
    @email = email || ENV['MONEYFORWARD_EMAIL']
    @password = password || ENV['MONEYFORWARD_PASSWORD']
    @headless = headless
    @logger = Logger.new($stdout)
    @logger.level = ENV['DEBUG'] == 'true' ? Logger::DEBUG : Logger::INFO

    validate_credentials!
  end

  def run
    setup_driver
    navigate_to_accounts_page
    login unless on_accounts_page?
    update_accounts
  rescue StandardError => e
    @logger.error("エラーが発生しました: #{e.message}")
    @logger.error(e.backtrace.join("\n"))
    raise
  ensure
    teardown_driver
  end

  private

    def validate_credentials!
      if @email.nil? || @email.empty?
        raise ArgumentError, 'メールアドレスが設定されていません。環境変数 MONEYFORWARD_EMAIL を設定してください。'
      end

      if @password.nil? || @password.empty?
        raise ArgumentError, 'パスワードが設定されていません。環境変数 MONEYFORWARD_PASSWORD を設定してください。'
      end
    end

    def setup_driver
      @logger.info('ブラウザを起動しています...')

      # User-Agentを固定することで、同じデバイスとして認識させる
      user_agent = ENV['USER_AGENT'] || 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

      # ユーザーデータディレクトリを指定することで、ブラウザの状態を永続化
      user_data_dir = File.join(File.dirname(__FILE__), '.moneyforward_chrome_profile')
      FileUtils.mkdir_p(user_data_dir) unless Dir.exist?(user_data_dir)

      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument('--headless=new') if @headless
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-dev-shm-usage')
      options.add_argument('--disable-gpu')
      options.add_argument('--window-size=1920,1080')
      options.add_argument("--user-agent=#{user_agent}")
      options.add_argument("--user-data-dir=#{user_data_dir}")

      @driver = Selenium::WebDriver.for(:chrome, options: options)
      @driver.manage.timeouts.implicit_wait = 10
      @logger.info('ブラウザの起動が完了しました')
    end

    def teardown_driver
      return unless @driver

      @logger.info('ブラウザを終了しています...')
      @driver.quit
      @logger.info('ブラウザを終了しました')
    end

    def login
      click_alternative_account_login if on_account_selector_page?

      @logger.info('メールアドレスとパスワードでログインしています...')
      sleep WAIT_TIME
      input_email_and_submit
      input_password_and_submit
      wait_additional_authentication if on_email_otp_page?
      @logger.info('ログインが完了しました')

      verify_login_success
    end

    def navigate_to_accounts_page
      @driver.navigate.to(ACCOUNTS_URL)
      sleep WAIT_TIME
    end

    def on_accounts_page?
      @driver.current_url.include?('/accounts')
    end

    def on_account_selector_page?
      @driver.current_url.include?('/account_selector')
    end

    def on_sign_in_page?
      @driver.current_url.include?('/sign_in')
    end

    def on_email_otp_page?
      @driver.current_url.include?('/email_otp')
    end

    def click_alternative_account_login
      @logger.info('アカウント選択画面が表示されました。「別のアカウントでログイン」をクリックします')
      alternative_login_link = @driver.find_element(:xpath, "//a[contains(text(), '別のアカウントでログイン')]")
      alternative_login_link.click
      sleep WAIT_TIME
    end

    def verify_login_success
      navigate_to_accounts_page

      raise 'ログインに失敗しました。追加認証が完了していない可能性があります' if on_sign_in_page?
    end

    def input_email_and_submit
      email_field = @driver.find_element(:xpath, "//input[@type='email']")
      email_field.clear
      email_field.send_keys(@email)

      email_submit_button = @driver.find_element(:id, 'submitto')
      email_submit_button.click
      sleep WAIT_TIME
    end

    def input_password_and_submit
      password_field = @driver.find_element(:xpath, "//input[@type='password']")
      password_field.send_keys(@password)

      login_button = @driver.find_element(:id, 'submitto')
      login_button.click
      sleep WAIT_TIME
    end

    def wait_additional_authentication
      return unless on_email_otp_page?

      @logger.warn('追加認証が求められています')
      @logger.info("#{ADDITIONAL_AUTH_TIMEOUT}秒間待機します。認証コードを入力してください")

      ADDITIONAL_AUTH_TIMEOUT.times do
        unless on_email_otp_page?
          @logger.info('追加認証が完了しました')
          return
        end
        sleep 1
      end

      raise '追加認証が完了しませんでした。認証コードが入力されていないか、誤っている可能性があります'
    end

    def update_accounts
      @logger.info('口座一覧ページに移動しています...')
      @driver.navigate.to(ACCOUNTS_URL)
      sleep WAIT_TIME

      # 更新可能な口座のIDを取得
      account_ids = @driver.find_elements(:xpath, "//tr[.//input[@value='更新' and not(@disabled)]]")
                           .map { |row| row['id'] }
                           .compact

      if account_ids.empty?
        @logger.warn('更新可能な口座が見つかりませんでした。')
        return
      end

      @logger.info("#{account_ids.size}件の金融機関を更新します")

      account_ids.each_with_index do |account_id, index|
        update_account(account_id, index + 1, account_ids.size)
      end

      @logger.info('すべての更新リクエストが完了しました。')
    end

    def update_account(account_id, current, total)
      row = @driver.find_element(:id, account_id)
      account_name = row.find_element(:xpath, './/td[@class="service"]//a[1]').text.strip rescue '不明な口座'
      progress = "[#{current}/#{total}]"

      @logger.info("#{progress} #{account_name}を更新しています...")
      row.find_element(:xpath, ".//input[@value='更新']").click
      sleep WAIT_TIME
      @logger.info("#{progress} #{account_name}の更新をリクエストしました")
    rescue StandardError => e
      @logger.error("#{progress} 更新中にエラーが発生しました: #{e.message}")
    end
end

if __FILE__ == $PROGRAM_NAME
  begin
    email = ARGV[0]
    password = ARGV[1]
    headless = ENV['HEADLESS'] != 'false'

    updater = MoneyForwardUpdater.new(
      email: email,
      password: password,
      headless: headless
    )
    updater.run
  rescue ArgumentError => e
    puts "エラー: #{e.message}"
    puts "\n使用方法:"
    puts "  ruby moneyforward_updater.rb [email] [password]"
    puts "\nまたは環境変数を設定してください:"
    puts "  MONEYFORWARD_EMAIL=your@email.com"
    puts "  MONEYFORWARD_PASSWORD=yourpassword"
    puts "  ruby moneyforward_updater.rb"
    exit 1
  rescue StandardError => e
    puts "予期しないエラーが発生しました: #{e.message}"
    exit 1
  end
end
