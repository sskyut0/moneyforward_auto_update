#!/usr/bin/env ruby
# frozen_string_literal: true

require 'selenium-webdriver'
require 'dotenv/load'
require 'logger'
require 'fileutils'
require 'date'
require 'csv'

class MoneyForwardCsvDownloader
  MONEYFORWARD_URL = 'https://moneyforward.com'
  CF_URL = "#{MONEYFORWARD_URL}/cf"

  WAIT_TIME = 2
  ADDITIONAL_AUTH_TIMEOUT = 30

  CSV_HEADERS = ['計算対象', '日付', '内容', '金額（円）', '保有金融機関', '大項目', '中項目', 'メモ', '振替', 'ID'].freeze

  def initialize(email: nil, password: nil, headless: true, output_path: nil, year: nil)
    @email = email || ENV['MONEYFORWARD_EMAIL']
    @password = password || ENV['MONEYFORWARD_PASSWORD']
    @headless = headless
    @year = year || Date.today.year
    @output_path = output_path || "収入・支出詳細_#{@year}.csv"
    @logger = Logger.new($stdout)
    @logger.level = ENV['DEBUG'] == 'true' ? Logger::DEBUG : Logger::INFO

    validate_credentials!
  end

  def run
    setup_driver
    navigate_to_cf_page
    login unless on_cf_page?
    rows = scrape_all_months
    write_csv(rows)
  rescue StandardError => e
    @logger.error("Error: #{e.message}")
    @logger.error(e.backtrace.join("\n"))
    raise
  ensure
    teardown_driver
  end

  private

    def validate_credentials!
      raise ArgumentError, 'Email not configured. Set MONEYFORWARD_EMAIL.' if @email.nil? || @email.empty?
      raise ArgumentError, 'Password not configured. Set MONEYFORWARD_PASSWORD.' if @password.nil? || @password.empty?
    end

    def setup_driver
      @logger.info('Starting browser...')

      user_agent = ENV['USER_AGENT'] || 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
      user_data_dir = File.join(File.dirname(__FILE__), '.moneyforward_chrome_profile')
      FileUtils.mkdir_p(user_data_dir)

      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument('--headless=new') if @headless
      options.add_argument('--no-sandbox')
      options.add_argument('--disable-dev-shm-usage')
      options.add_argument('--disable-gpu')
      options.add_argument('--window-size=1920,1080')
      options.add_argument("--user-agent=#{user_agent}")
      options.add_argument("--user-data-dir=#{user_data_dir}")

      service = Selenium::WebDriver::Chrome::Service.new(path: ENV.fetch('CHROMEDRIVER_PATH', '/usr/bin/chromedriver'))
      @driver = Selenium::WebDriver.for(:chrome, options: options, service: service)
      @driver.manage.timeouts.implicit_wait = 10

      @logger.info('Browser started.')
    end

    def teardown_driver
      return unless @driver

      @logger.info('Closing browser...')
      @driver.quit
      @logger.info('Browser closed.')
    end

    def navigate_to_cf_page
      @driver.navigate.to(CF_URL)
      sleep WAIT_TIME
    end

    def current_displayed_year_month
      result = @driver.execute_script(<<~JS)
        for (const el of document.querySelectorAll('*')) {
          if (el.children.length === 0) {
            const m = el.textContent.match(/(\\d{4})\\/(\\d{2})\\/01 -/);
            if (m) return [parseInt(m[1]), parseInt(m[2])];
          }
        }
        return null;
      JS
      result ? [result[0], result[1]] : nil
    end

    def navigate_to_month(target_year, target_month)
      loop do
        cy, cm = current_displayed_year_month
        break if cy == target_year && cm == target_month
        break unless cy > target_year || (cy == target_year && cm > target_month)

        click_prev_month
      end
    end

    def click_prev_month
      @driver.find_element(:css, '.btn.fc-button.fc-button-prev').click
      sleep WAIT_TIME
    end

    def on_cf_page?
      @driver.current_url.include?('/cf')
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

    def login
      click_alternative_account_login if on_account_selector_page?

      @logger.info('Logging in...')
      sleep WAIT_TIME
      input_email_and_submit
      input_password_and_submit
      wait_additional_authentication if on_email_otp_page?
      @logger.info('Login complete.')

      verify_login_success
    end

    def click_alternative_account_login
      @logger.info('Account selector shown. Clicking alternative login link.')
      @driver.find_element(:xpath, "//a[contains(text(), '別のアカウントでログイン')]").click
      sleep WAIT_TIME
    end

    def verify_login_success
      navigate_to_cf_page
      raise 'Login failed. Additional authentication may not be complete.' if on_sign_in_page?
    end

    def input_email_and_submit
      email_field = @driver.find_element(:xpath, "//input[@type='email']")
      email_field.clear
      email_field.send_keys(@email)
      @driver.find_element(:id, 'submitto').click
      sleep WAIT_TIME
    end

    def input_password_and_submit
      @driver.find_element(:xpath, "//input[@type='password']").send_keys(@password)
      @driver.find_element(:id, 'submitto').click
      sleep WAIT_TIME
    end

    def wait_additional_authentication
      return unless on_email_otp_page?

      @logger.warn('Additional authentication required.')
      @logger.info("Waiting #{ADDITIONAL_AUTH_TIMEOUT} seconds. Please enter the authentication code.")

      ADDITIONAL_AUTH_TIMEOUT.times do
        unless on_email_otp_page?
          @logger.info('Additional authentication complete.')
          return
        end
        sleep 1
      end

      raise 'Additional authentication timed out.'
    end

    def scrape_all_months
      last_month = @year == Date.today.year ? Date.today.month : 12
      all_rows = []

      # Navigate to the last target month first, then step backwards to month 1
      navigate_to_month(@year, last_month)

      last_month.downto(1) do |month|
        @logger.info("Scraping #{@year}/#{month}...")
        navigate_to_month(@year, month)
        rows = scrape_month
        @logger.info("  #{rows.size} rows found.")
        all_rows.concat(rows)
      end

      all_rows.reverse
    end

    def scrape_month
      table = @driver.find_element(:id, 'cf-detail-table')
      rows = table.find_elements(:xpath, './/tbody/tr')
      rows.map { |row| scrape_row(row) }.compact
    rescue Selenium::WebDriver::Error::NoSuchElementError
      []
    end

    def scrape_row(row)
      cells = row.find_elements(:tag_name, 'td')
      return nil if cells.empty?

      is_target = row.find_element(:xpath, ".//input[@name='user_asset_act[is_target]']").attribute('value')
      id        = row.find_element(:xpath, ".//input[@name='user_asset_act[id]']").attribute('value')

      date_raw  = cells[1].attribute('data-table-sortable-value')
      date      = date_raw&.split('-')&.first

      content   = cells[2].text.strip
      amount    = cells[3].text.strip.gsub(',', '')
      account   = cells[4].text.strip
      category  = cells[5].text.strip
      subcategory = cells[6].text.strip
      memo      = cells[7].text.strip

      transfer_link = cells[8].find_element(:xpath, './/i[contains(@data-link, "transfer")]').attribute('data-link') rescue nil
      transfer = transfer_link&.include?('disable_transfer') ? 1 : 0

      [is_target, date, content, amount, account, category, subcategory, memo, transfer, id]
    rescue StandardError => e
      @logger.warn("Failed to parse row: #{e.message}")
      nil
    end

    def write_csv(rows)
      CSV.open(@output_path, 'w', encoding: 'UTF-8') do |csv|
        csv << CSV_HEADERS
        rows.each { |row| csv << row }
      end
      @logger.info("Saved #{rows.size} rows to: #{@output_path}")
    end
end

if __FILE__ == $PROGRAM_NAME
  begin
    headless = ENV['HEADLESS'] != 'false'
    year = ENV['YEAR'] ? ENV['YEAR'].to_i : nil
    output_path = ENV['OUTPUT_PATH'] || ARGV[0]

    downloader = MoneyForwardCsvDownloader.new(
      headless: headless,
      output_path: output_path,
      year: year
    )
    downloader.run
  rescue ArgumentError => e
    puts "Error: #{e.message}"
    puts "\nUsage:"
    puts "  ruby moneyforward_csv_downloader.rb [output_path]"
    puts "\nOr set environment variables:"
    puts "  MONEYFORWARD_EMAIL=your@email.com"
    puts "  MONEYFORWARD_PASSWORD=yourpassword"
    puts "  YEAR=2026          # default: current year"
    puts "  OUTPUT_PATH=path/to/output.csv"
    exit 1
  rescue StandardError => e
    puts "Unexpected error: #{e.message}"
    exit 1
  end
end
